package library

import (
	"context"
	"crypto/rand"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

type fakeDownloads struct {
	dir     string
	mu      sync.Mutex
	rows    []acquire.Download
	removed []string
}

func (f *fakeDownloads) List(context.Context) []acquire.Download {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.rows)
}

func (f *fakeDownloads) Remove(_ context.Context, id string, deleteData bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i, row := range f.rows {
		if row.ID == id {
			if deleteData {
				os.RemoveAll(row.Dir)
			}
			f.rows = slices.Delete(f.rows, i, i+1)
			f.removed = append(f.removed, id)
			return nil
		}
	}
	return acquire.ErrNotFound
}

func (f *fakeDownloads) Dirs(row acquire.Download) []string {
	if row.Dir == "" {
		return nil
	}
	return []string{row.Dir}
}

func (f *fakeDownloads) Dir() string { return f.dir }

type fakeProgress []progress.Entry

func (f fakeProgress) AllProgress(context.Context) ([]progress.Entry, error) { return f, nil }

type fakePrefs preferences.Preferences

func (f fakePrefs) Get(context.Context) (preferences.Preferences, error) {
	return preferences.Preferences(f), nil
}

const episodeBytes = 64 << 10

var now = time.Date(2026, 9, 23, 12, 0, 0, 0, time.UTC)

// library is five downloads of one series, each an episode of 64 KiB:
// e1 watched 40 days ago, e2 5 days ago, e3 an hour ago, e4 being rewatched,
// e5 never watched; plus a loose file nothing matched and a local file.
func library(t *testing.T, prefs preferences.Preferences) (*Service, *fakeDownloads) {
	t.Helper()
	root := t.TempDir()
	downloads := &fakeDownloads{dir: root}
	add := func(id, item string, episode int, scheme string) {
		dir := filepath.Join(root, id)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		// Random, so a compressing filesystem allocates what it is told.
		data := make([]byte, episodeBytes)
		rand.Read(data)
		path := filepath.Join(dir, "episode.mkv")
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		row := acquire.Download{ID: id, ItemID: item, Season: 1, Episode: episode, Locator: sources.Locator{Scheme: scheme}, Dir: dir, FilePath: path, State: acquire.StateDone}
		if scheme == "file" {
			row.Dir = ""
		}
		downloads.rows = append(downloads.rows, row)
	}
	for episode := 1; episode <= 5; episode++ {
		add("e"+string(rune('0'+episode)), "show", episode, "torrent")
	}
	add("loose", "", 0, "torrent")
	add("local", "show", 6, "file")
	watched := func(episode int, ago time.Duration, position float64) progress.Entry {
		return progress.Entry{ItemID: "show", Season: 1, Episode: episode, Position: position, Watched: true, UpdatedAt: now.Add(-ago)}
	}
	entries := fakeProgress{
		watched(1, 40*24*time.Hour, 0),
		watched(2, 5*24*time.Hour, 0),
		watched(3, time.Hour, 0),
		watched(4, 2*time.Hour, 300),
		watched(6, 3*time.Hour, 0),
		{ItemID: "show", Season: 1, Episode: 5, Position: 120, Duration: 1400, UpdatedAt: now},
	}
	s := New(downloads, entries, fakePrefs(prefs), slog.New(slog.NewTextHandler(io.Discard, nil)))
	s.now = func() time.Time { return now }
	return s, downloads
}

func clean(t *testing.T, s *Service, downloads *fakeDownloads) []string {
	t.Helper()
	if err := s.Clean(context.Background()); err != nil {
		t.Fatalf("clean: %v", err)
	}
	return downloads.removed
}

func TestForeverWithoutALimitFreesNothing(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever"})
	if removed := clean(t, s, downloads); len(removed) != 0 {
		t.Fatalf("freed %v", removed)
	}
}

// A rewatch under way, an unwatched episode, a loose download and the user's
// own file are never freed.
func TestUntilWatchedFreesWhatIsWatched(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "watched"})
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e1", "e2", "e3"}) {
		t.Fatalf("freed %v, want e1 e2 e3", removed)
	}
}

func TestDaysCountFromWatching(t *testing.T) {
	tests := []struct {
		days int
		want []string
	}{
		{days: 30, want: []string{"e1"}},
		{days: 5, want: []string{"e1", "e2"}},
		{days: 1, want: []string{"e1", "e2"}},
		{days: 365, want: nil},
	}
	for _, tt := range tests {
		s, downloads := library(t, preferences.Preferences{Keep: "days", KeepDays: tt.days})
		if removed := clean(t, s, downloads); !slices.Equal(removed, tt.want) {
			t.Fatalf("%d days: freed %v, want %v", tt.days, removed, tt.want)
		}
	}
}

// Over the ceiling, watched episodes go the longest watched first until the
// rest fits; unwatched ones stay even when that is not enough.
func TestCeilingFreesTheLongestWatchedFirst(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever", DiskLimit: 4*episodeBytes + episodeBytes/2})
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e1", "e2"}) {
		t.Fatalf("freed %v, want e1 e2", removed)
	}
	s, downloads = library(t, preferences.Preferences{Keep: "forever", DiskLimit: 1})
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e1", "e2", "e3"}) {
		t.Fatalf("freed %v, want every watched episode and nothing else", removed)
	}
}

func TestPlayingIsNotFreedUntilItSettles(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "watched"})
	done := s.Play("e3")
	if removed := clean(t, s, downloads); slices.Contains(removed, "e3") {
		t.Fatalf("freed a download while it plays: %v", removed)
	}
	done()
	if removed := clean(t, s, downloads); slices.Contains(removed, "e3") {
		t.Fatalf("freed a download a player may reconnect to: %v", removed)
	}
	now = now.Add(settle)
	defer func() { now = now.Add(-settle) }()
	if removed := clean(t, s, downloads); !slices.Contains(removed, "e3") {
		t.Fatalf("freed %v, want e3 once it settled", removed)
	}
}

// Play on a watched episode starts its download again before the player opens
// the stream, which waits for the file to be ready.
func TestStartedIsNotFreedBeforeItPlays(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "watched"})
	row := downloads.rows[2]
	if _, err := s.Start(func() (acquire.Download, error) { return row, nil }); err != nil {
		t.Fatal(err)
	}
	if removed := clean(t, s, downloads); slices.Contains(removed, "e3") {
		t.Fatalf("freed a download just started: %v", removed)
	}
}

// The three watched episodes are room, because over the limit they are what
// goes; the local file is the user's and counts for nothing.
func TestPrefetchFitsInsideTheLimitCountingWatchedAsRoom(t *testing.T) {
	ctx := context.Background()
	fits := func(limit, size int64) bool {
		t.Helper()
		s, _ := library(t, preferences.Preferences{Keep: "forever", DiskLimit: limit})
		ok, err := s.Fits(ctx, size)
		if err != nil {
			t.Fatalf("fits: %v", err)
		}
		return ok
	}
	// e4, e5 and loose stay whatever happens: three files of 64 KiB.
	if !fits(5*episodeBytes, episodeBytes) {
		t.Fatal("an episode did not fit beside three that stay, under five")
	}
	if fits(3*episodeBytes, episodeBytes) {
		t.Fatal("an episode fitted where the three that stay already fill the limit")
	}
	if !fits(0, episodeBytes) {
		t.Fatal("an episode did not fit with no limit")
	}
	if fits(0, 0) {
		t.Fatal("a copy of unknown size fitted")
	}
	if fits(0, 1<<62) {
		t.Fatal("a copy larger than the free disk fitted")
	}
}

// Seen in review: a download still arriving counted only what it had written,
// so a prefetch fitted into room a season half way through was about to fill.
func TestPrefetchLeavesRoomForWhatIsStillArriving(t *testing.T) {
	fits := func(limit int64) bool {
		t.Helper()
		s, downloads := library(t, preferences.Preferences{Keep: "forever", DiskLimit: limit})
		downloads.rows = append(downloads.rows,
			acquire.Download{ID: "e7", ItemID: "show", Season: 1, Episode: 7, Locator: sources.Locator{Scheme: "torrent"}, Size: 3 * episodeBytes, State: acquire.StateActive},
			acquire.Download{ID: "e8", ItemID: "show", Season: 1, Episode: 8, Locator: sources.Locator{Scheme: "torrent"}, Size: 50 * episodeBytes, State: acquire.StateFailed},
		)
		ok, err := s.Fits(context.Background(), episodeBytes)
		if err != nil {
			t.Fatalf("fits: %v", err)
		}
		return ok
	}
	// Three episodes that stay, three still to come for e7, and this one.
	if fits(6 * episodeBytes) {
		t.Fatal("a prefetch took the room a running download is filling")
	}
	if !fits(7 * episodeBytes) {
		t.Fatal("a prefetch did not fit beside a running download and three that stay")
	}
}
