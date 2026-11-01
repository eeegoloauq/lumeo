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
	stopped []string
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

func (f *fakeDownloads) SetPaused(_ context.Context, id string, paused bool) (acquire.Download, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i, row := range f.rows {
		if row.ID == id {
			f.rows[i].State, f.rows[i].PausedByUser = acquire.StateActive, false
			if paused {
				f.rows[i].State, f.rows[i].PausedByUser = acquire.StatePaused, true
			}
			return f.rows[i], nil
		}
	}
	return acquire.Download{}, acquire.ErrNotFound
}

func (f *fakeDownloads) StopSharing(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.rows {
		if f.rows[i].ID == id {
			f.rows[i].Seeding = false
			f.stopped = append(f.stopped, id)
			return nil
		}
	}
	return acquire.ErrNotFound
}

func (f *fakeDownloads) state(id string) acquire.State {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, row := range f.rows {
		if row.ID == id {
			return row.State
		}
	}
	return ""
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

func TestCleanStopsOnlyIdleFinishedSharing(t *testing.T) {
	for _, tc := range []struct {
		name   string
		play   bool
		settle bool
		want   bool
	}{
		{"idle", false, false, true},
		{"playing", true, false, false},
		{"settling", false, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, downloads := library(t, preferences.Preferences{Keep: "forever"})
			for i := range downloads.rows {
				if downloads.rows[i].ID == "e3" {
					downloads.rows[i].Seeding = true
				}
			}
			if tc.play {
				defer s.Play("e3")()
			}
			if tc.settle {
				s.stopped["e3"] = now.Add(-settle / 2)
			}
			clean(t, s, downloads)
			if got := slices.Contains(downloads.stopped, "e3"); got != tc.want {
				t.Fatalf("stopped = %v, want %v", got, tc.want)
			}
		})
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

// A device's hold lasts by its keep rules, capped by the owner's maximum: a
// watched one from the mark or a later play, the settle time at least; an
// unwatched one from the device's last start or play, or the download's
// finishing, and for as long as bytes arrive. A released hold lasts no more.
func TestAHoldLastsByItsDevicesKeepRules(t *testing.T) {
	ago := func(d time.Duration) time.Time { return now.Add(-d) }
	hold := func(watched, active time.Duration) acquire.Hold {
		h := acquire.Hold{KeepWatchedDays: 1, KeepUnwatchedDays: 7, ActiveAt: ago(active)}
		if watched >= 0 {
			h.WatchedAt = ago(watched)
		}
		return h
	}
	const unwatched = -1
	done := acquire.Download{State: acquire.StateDone, UpdatedAt: ago(30 * day)}
	for _, tc := range []struct {
		name    string
		hold    acquire.Hold
		row     acquire.Download
		maxDays int
		want    bool
	}{
		{"watched within its day", hold(20*time.Hour, 3*day), done, 30, true},
		{"watched past its day", hold(25*time.Hour, 3*day), done, 30, false},
		{"watched, played again since", hold(2*day, 2*time.Hour), done, 30, true},
		{"watched with no days, settling", func() acquire.Hold { h := hold(time.Minute, day); h.KeepWatchedDays = 0; return h }(), done, 30, true},
		{"watched with no days, settled", func() acquire.Hold { h := hold(settle, day); h.KeepWatchedDays = 0; return h }(), done, 30, false},
		{"unwatched, played six days ago", hold(unwatched, 6*day), done, 30, true},
		{"unwatched, played eight days ago", hold(unwatched, 8*day), done, 30, false},
		{"unwatched, finished since it was started", hold(unwatched, 8*day), acquire.Download{State: acquire.StateDone, UpdatedAt: ago(2 * day)}, 30, true},
		{"unwatched, still arriving", hold(unwatched, 30*day), acquire.Download{State: acquire.StateActive, UpdatedAt: ago(30 * day)}, 30, true},
		{"unwatched, stalled for weeks", hold(unwatched, 30*day), acquire.Download{State: acquire.StateActive, UpdatedAt: ago(30 * day), WaitingSince: ago(29 * day)}, 30, false},
		{"unwatched, paused for weeks", hold(unwatched, 30*day), acquire.Download{State: acquire.StatePaused, UpdatedAt: ago(30 * day)}, 30, false},
		{"a year asked, the owner's month given", func() acquire.Hold { h := hold(unwatched, 31*day); h.KeepUnwatchedDays = 365; return h }(), done, 30, false},
		{"a year asked, within the owner's month", func() acquire.Hold { h := hold(unwatched, 29*day); h.KeepUnwatchedDays = 365; return h }(), done, 30, true},
		{"released", func() acquire.Hold { h := hold(unwatched, time.Hour); h.ReleasedAt = ago(time.Minute); return h }(), done, 30, false},
	} {
		if got := Lasts(tc.hold, tc.row, now, tc.maxDays); got != tc.want {
			t.Errorf("%s: lasts = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// On a media server a download its devices hold goes once none of their
// holds lasts, watched or not and whatever Keep says, so nothing a device
// holds stays forever. One that a hold still keeps stays. The viewer here,
// when they have an entry, still has a say: their unfinished episode stays,
// and one they watched is theirs again, under Keep, once no hold lasts.
func TestAHeldDownloadGoesOnceNoHoldLasts(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever", DeviceMaxKeepDays: 30})
	lapsed := acquire.Hold{KeepWatchedDays: 1, KeepUnwatchedDays: 7, ActiveAt: now.Add(-8 * day)}
	lasting := acquire.Hold{KeepWatchedDays: 1, KeepUnwatchedDays: 7, ActiveAt: now.Add(-time.Hour)}
	released := lasting
	released.ReleasedAt = now.Add(-time.Minute)
	held := map[string][]acquire.Hold{
		"all-lapsed":     {lapsed, lapsed},
		"one-lasting":    {lapsed, lasting},
		"released":       {released},
		"released-other": {released, lasting},
	}
	for id, holds := range held {
		dir := filepath.Join(downloads.dir, id)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		downloads.rows = append(downloads.rows, acquire.Download{
			ID: id, ItemID: "film-" + id, Locator: sources.Locator{Scheme: "torrent"}, Dir: dir,
			State: acquire.StateDone, UpdatedAt: now.Add(-10 * day), Holds: holds,
		})
	}
	// e1 the viewer here watched, e5 they are part way.
	for i := range downloads.rows {
		if id := downloads.rows[i].ID; id == "e1" || id == "e5" {
			downloads.rows[i].Holds = []acquire.Hold{lapsed}
		}
	}
	removed := clean(t, s, downloads)
	for id, want := range map[string]bool{
		"all-lapsed": true, "released": true,
		"one-lasting": false, "released-other": false, "e1": false, "e5": false,
	} {
		if slices.Contains(removed, id) != want {
			t.Errorf("%s freed = %v, want %v (freed %v)", id, !want, want, removed)
		}
	}

	s, downloads = library(t, preferences.Preferences{Keep: "days", KeepDays: 30, DeviceMaxKeepDays: 30})
	for i := range downloads.rows {
		if id := downloads.rows[i].ID; id == "e1" || id == "e2" {
			downloads.rows[i].Holds = []acquire.Hold{lapsed}
		}
	}
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e1"}) {
		t.Fatalf("freed %v; want e1 alone, watched here 40 days ago", removed)
	}
}

// A device deleting a download frees it at once when no other hold on it
// lasts and the viewer here has no say, but never under an open stream, and
// leaves one another device still holds.
func TestADownloadEveryDeviceLetGoOfGoesAtOnce(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever", DeviceMaxKeepDays: 30})
	released := acquire.Hold{KeepWatchedDays: 1, KeepUnwatchedDays: 7, ActiveAt: now, ReleasedAt: now}
	lasting := acquire.Hold{KeepWatchedDays: 1, KeepUnwatchedDays: 7, ActiveAt: now}
	for _, tc := range []struct {
		id    string
		holds []acquire.Hold
	}{{"gone", []acquire.Hold{released}}, {"other", []acquire.Hold{released, lasting}}, {"playing", []acquire.Hold{released}}} {
		dir := filepath.Join(downloads.dir, tc.id)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		downloads.rows = append(downloads.rows, acquire.Download{
			ID: tc.id, ItemID: "film-" + tc.id, Locator: sources.Locator{Scheme: "torrent"}, Dir: dir,
			State: acquire.StateDone, UpdatedAt: now, Holds: tc.holds,
		})
	}
	// e5 the viewer here is part way through.
	for i := range downloads.rows {
		if downloads.rows[i].ID == "e5" {
			downloads.rows[i].Holds = []acquire.Hold{released}
		}
	}
	done := s.Play("playing")
	defer done()
	for id, want := range map[string]bool{"gone": true, "other": false, "playing": false, "e5": false} {
		freed, err := s.Released(context.Background(), id)
		if err != nil || freed != want {
			t.Errorf("%s: freed = %v, %v; want %v", id, freed, err, want)
		}
	}
	if !slices.Equal(downloads.removed, []string{"gone"}) {
		t.Fatalf("removed %v, want gone alone", downloads.removed)
	}
}

// Over the ceiling a held download goes like any other once everyone whose
// hold lasts has watched it, counted from the last of them; one a lasting
// hold has not watched stays.
func TestCeilingFreesAHeldDownloadEveryoneWatched(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever", DiskLimit: 1, DeviceMaxKeepDays: 30})
	watched := func(ago time.Duration) acquire.Hold {
		return acquire.Hold{WatchedAt: now.Add(-ago), KeepWatchedDays: 7, KeepUnwatchedDays: 7, ActiveAt: now.Add(-day)}
	}
	unwatched := acquire.Hold{KeepWatchedDays: 7, KeepUnwatchedDays: 7, ActiveAt: now.Add(-time.Hour)}
	for i := range downloads.rows {
		switch downloads.rows[i].ID {
		case "e1":
			downloads.rows[i].Holds = []acquire.Hold{watched(3 * time.Hour), watched(2 * time.Hour)}
		case "e2":
			downloads.rows[i].Holds = []acquire.Hold{watched(3 * time.Hour), unwatched}
		case "e3":
			downloads.rows[i].Holds = []acquire.Hold{watched(time.Minute)}
		}
	}
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e1"}) {
		t.Fatalf("freed %v; want e1 alone: e2 a lasting hold has not watched, e3 is settling", removed)
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

// A core started again knows no stream: the episode finished just before the
// app closed settles from its progress row.
func TestJustFinishedIsNotFreedAfterARestart(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "watched"})
	s.progress = fakeProgress{{ItemID: "show", Season: 1, Episode: 3, Watched: true, UpdatedAt: now.Add(-time.Minute)}}
	if removed := clean(t, s, downloads); len(removed) != 0 {
		t.Fatalf("freed %v a minute after it was finished", removed)
	}
	now = now.Add(settle)
	defer func() { now = now.Add(-settle) }()
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e3"}) {
		t.Fatalf("freed %v, want e3 once it settled", removed)
	}
}

// Episode five has a finished copy and two half ones. A request for the new
// half copy whose stream never opened chooses nothing; once one opens, the old
// half copy goes and the finished one stays. Waiting for the old one to settle
// is free's, tested above.
func TestPlayingAnotherCopyDropsTheUnfinishedOne(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever"})
	for _, id := range []string{"e5-old", "e5-new"} {
		downloads.rows = append(downloads.rows, acquire.Download{ID: id, ItemID: "show", Season: 1, Episode: 5, Locator: sources.Locator{Scheme: "torrent"}, State: acquire.StateActive})
	}
	start := now
	defer func() { now = start }()
	s.Play("e5-old")()
	s.Opened("e5-old")
	now = now.Add(settle)
	s.Play("e5-new")()
	if removed := clean(t, s, downloads); len(removed) != 0 {
		t.Fatalf("freed %v for a copy that never opened", removed)
	}
	s.Opened("e5-new")
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e5-old"}) {
		t.Fatalf("freed %v, want e5-old", removed)
	}
}

// The copy left behind stops at once, while it still waits out the settle
// before it goes: switching back within it resumes what it had.
func TestPlayingAnotherCopyPausesTheUnfinishedOneAtOnce(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever"})
	for _, id := range []string{"e5-old", "e5-new"} {
		downloads.rows = append(downloads.rows, acquire.Download{ID: id, ItemID: "show", Season: 1, Episode: 5, Locator: sources.Locator{Scheme: "torrent"}, State: acquire.StateActive})
	}
	start := now
	defer func() { now = start }()
	s.Opened("e5-old")
	s.Play("e5-old")()
	now = now.Add(time.Second)
	s.Opened("e5-new")
	if removed := clean(t, s, downloads); len(removed) != 0 {
		t.Fatalf("freed %v before it settled", removed)
	}
	if got := downloads.state("e5-old"); got != acquire.StatePaused {
		t.Fatalf("replaced copy is %q, want paused", got)
	}
	if got := downloads.state("e5-new"); got != acquire.StateActive {
		t.Fatalf("chosen copy is %q, want active", got)
	}
	now = now.Add(settle)
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e5-old"}) {
		t.Fatalf("freed %v, want e5-old", removed)
	}
}

// Play pressed on another copy chooses it before it has peers: the copy played
// before is the one paused, and it keeps its bytes until the new one opens.
func TestPickedCopyIsNotPausedWhileItWaits(t *testing.T) {
	s, downloads := library(t, preferences.Preferences{Keep: "forever"})
	for _, id := range []string{"e5-old", "e5-new"} {
		downloads.rows = append(downloads.rows, acquire.Download{ID: id, ItemID: "show", Season: 1, Episode: 5, Locator: sources.Locator{Scheme: "torrent"}, State: acquire.StateActive})
	}
	start := now
	defer func() { now = start }()
	s.Opened("e5-old")
	now = now.Add(settle)
	s.Picked("e5-new")
	if removed := clean(t, s, downloads); len(removed) != 0 {
		t.Fatalf("freed %v before the picked copy opened", removed)
	}
	if got := downloads.state("e5-new"); got != acquire.StateActive {
		t.Fatalf("picked copy is %q, want active", got)
	}
	if got := downloads.state("e5-old"); got != acquire.StatePaused {
		t.Fatalf("replaced copy is %q, want paused", got)
	}
	s.Opened("e5-new")
	if removed := clean(t, s, downloads); !slices.Equal(removed, []string{"e5-old"}) {
		t.Fatalf("freed %v, want e5-old", removed)
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

func TestDefaultLimitIsHalfTheRoomUpToFiftyGiB(t *testing.T) {
	for _, c := range []struct {
		free uint64
		used int64
		want int64
	}{
		{free: 12 << 30, want: 6 << 30},
		// What the downloads take is room too: filling the disk does not
		// lower the limit they are held to.
		{free: 4 << 30, used: 8 << 30, want: 6 << 30},
		{free: 13 << 30, want: 6 << 30},
		{free: 300 << 30, want: 50 << 30},
		// 0 would mean no limit at all.
		{free: 1 << 29, want: 1 << 30},
	} {
		if got := defaultLimit(c.free, c.used); got != c.want {
			t.Errorf("free %d, used %d: limit %d, want %d", c.free, c.used, got, c.want)
		}
	}
}

func TestDiskUsageOfADirectoryNotMadeYet(t *testing.T) {
	disk, err := DiskUsage(filepath.Join(t.TempDir(), "downloads", "lumeo"))
	if err != nil || disk.Total == 0 {
		t.Fatalf("disk %+v, err %v", disk, err)
	}
}
