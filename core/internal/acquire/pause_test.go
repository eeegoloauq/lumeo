package acquire

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// A pause stops the transfer, keeps how far it got and outlives a restart of
// the core; resuming runs it again in the same directory.
func TestPauseAndResume(t *testing.T) {
	ctx := context.Background()
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, st, _ := testManager(t, backend)
	d, err := m.Start(ctx, torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	backend.task.mu.Lock()
	backend.task.progress = Progress{Completed: 700, Total: 2000, Peers: 3, Rate: 50}
	backend.task.file = &fakeFile{path: filepath.Join(d.Dir, "x.mkv"), size: 2000, head: 700}
	backend.task.mu.Unlock()

	paused, err := m.SetPaused(ctx, d.ID, true)
	if err != nil {
		t.Fatalf("pause: %v", err)
	}
	if paused.State != StatePaused || !paused.PausedByUser || paused.Ready {
		t.Fatalf("paused = %+v, want paused by the user and not ready", paused)
	}
	if want := (Progress{Completed: 700, Total: 2000}); paused.Progress != want {
		t.Fatalf("progress = %+v, want %+v", paused.Progress, want)
	}
	if !backend.task.closed {
		t.Fatal("the transfer still runs")
	}
	if got, _ := m.Get(ctx, d.ID); got.State != StatePaused || !got.PausedByUser {
		t.Fatalf("read back = %+v", got)
	}
	if stored, _, _ := st.Download(ctx, d.ID); stored.State != StatePaused || !stored.PausedByUser {
		t.Fatalf("stored = %+v", stored)
	}

	// Paused twice is still paused.
	if again, err := m.SetPaused(ctx, d.ID, true); err != nil || again.State != StatePaused {
		t.Fatalf("pause again: %+v, %v", again, err)
	}

	// A restart of the core does not resume it.
	restarted := &fakeBackend{scheme: "torrent"}
	m2 := NewManager(t.TempDir(), []Backend{restarted}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := m2.Resume(ctx); err != nil {
		t.Fatalf("boot: %v", err)
	}
	if restarted.starts != 0 {
		t.Fatalf("a paused download started at boot")
	}

	resumed, err := m.SetPaused(ctx, d.ID, false)
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	if resumed.State != StateActive || resumed.PausedByUser {
		t.Fatalf("resumed = %+v, want active", resumed)
	}
	if backend.starts != 2 || backend.dirs[1] != d.Dir {
		t.Fatalf("starts %d in %v, want a second one in %s", backend.starts, backend.dirs, d.Dir)
	}
	if stored, _, _ := st.Download(ctx, d.ID); stored.State != StateActive || stored.PausedByUser {
		t.Fatalf("stored = %+v", stored)
	}
	// Resuming what runs changes nothing.
	if _, err := m.SetPaused(ctx, d.ID, false); err != nil || backend.starts != 2 {
		t.Fatalf("resume a running download: %v, starts %d", err, backend.starts)
	}
}

// Play on a paused download is asking for it again.
func TestStartResumesAPausedDownload(t *testing.T) {
	ctx := context.Background()
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, _ := testManager(t, backend)
	d, err := m.Start(ctx, torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if _, err := m.SetPaused(ctx, d.ID, true); err != nil {
		t.Fatalf("pause: %v", err)
	}
	got, err := m.Start(ctx, torrentRequest())
	if err != nil {
		t.Fatalf("play: %v", err)
	}
	if got.State != StateActive || got.PausedByUser || backend.starts != 2 {
		t.Fatalf("after play = %+v, starts %d", got, backend.starts)
	}
}

func TestResumeRetriesAFailedDownload(t *testing.T) {
	ctx := context.Background()
	backend := &fakeBackend{scheme: "torrent", err: errors.New("disk not mounted")}
	m, _, _ := testManager(t, backend)
	if _, err := m.Start(ctx, torrentRequest()); err == nil {
		t.Fatal("start did not fail")
	}
	failed := m.List(ctx)[0]

	// Failing again is the answer, not an error of the request.
	got, err := m.SetPaused(ctx, failed.ID, false)
	if err != nil || got.State != StateFailed || got.Error != "disk not mounted" {
		t.Fatalf("retry = %+v, %v; want failed again", got, err)
	}
	backend.err = nil
	if got, err = m.SetPaused(ctx, failed.ID, false); err != nil || got.State != StateActive || got.Error != "" {
		t.Fatalf("retry = %+v, %v; want active", got, err)
	}
	if backend.starts != 3 {
		t.Fatalf("starts %d, want 3", backend.starts)
	}
}

func TestPauseRefusesWhatHasNothingToFetch(t *testing.T) {
	ctx := context.Background()
	video := filepath.Join(t.TempDir(), "film.mkv")
	if err := os.WriteFile(video, make([]byte, 16), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, tt := range []struct {
		name string
		row  Download
		want error
	}{
		{name: "unknown", want: ErrNotFound},
		{name: "done", want: ErrNothingToFetch, row: Download{
			ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"}, State: StateDone, FilePath: video, Size: 16,
		}},
		{name: "local file", want: ErrNothingToFetch, row: Download{
			ID: "a", Locator: sources.Locator{Scheme: "file", Path: video}, State: StatePaused,
		}},
	} {
		for _, paused := range []bool{true, false} {
			st := newMemStore()
			if tt.row.ID != "" {
				if err := st.SaveDownload(ctx, tt.row); err != nil {
					t.Fatal(err)
				}
			}
			backend := &fakeBackend{scheme: tt.row.Locator.Scheme}
			m := NewManager(t.TempDir(), []Backend{backend}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
			if err := m.Resume(ctx); err != nil {
				t.Fatal(err)
			}
			if _, err := m.SetPaused(ctx, "a", paused); !errors.Is(err, tt.want) {
				t.Errorf("%s, paused %v: %v, want %v", tt.name, paused, err, tt.want)
			}
			if backend.starts != 0 {
				t.Errorf("%s, paused %v: started", tt.name, paused)
			}
		}
	}
}

// While nothing arrives a download says since when; while bytes arrive it
// says how long is left at the smoothed rate. Never both.
func TestWaitingSinceAndETA(t *testing.T) {
	ctx := context.Background()
	clock := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, _ := testManager(t, backend)
	m.now = func() time.Time { return clock }
	started := clock
	d, err := m.Start(ctx, torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	set := func(p Progress, resolved bool) {
		backend.task.mu.Lock()
		defer backend.task.mu.Unlock()
		backend.task.progress = p
		if resolved {
			backend.task.file = &fakeFile{path: filepath.Join(d.Dir, "x.mkv"), size: 2000}
		}
	}
	type want struct {
		waiting time.Time
		eta     int64
	}
	for _, step := range []struct {
		name     string
		after    time.Duration
		progress Progress
		resolved bool
		want     want
	}{
		{name: "metadata", progress: Progress{Peers: 2}, want: want{waiting: started}},
		{name: "no peers", after: 5 * time.Second, progress: Progress{}, resolved: true, want: want{waiting: started}},
		{name: "peers, nothing yet", after: 5 * time.Second, progress: Progress{Peers: 3, Total: 2000}, resolved: true, want: want{waiting: started}},
		// 100 bytes a second from here; the first second is the rate at once.
		{name: "bytes arrive", after: time.Second, progress: Progress{Peers: 3, Completed: 0, Total: 2000, Received: 100}, resolved: true, want: want{eta: 20}},
		{name: "rate measured", after: time.Second, progress: Progress{Peers: 3, Completed: 100, Total: 2000, Received: 200}, resolved: true, want: want{eta: 19}},
		// A poll a moment later measures nothing new: the ETA holds.
		{name: "quick poll", after: 10 * time.Millisecond, progress: Progress{Peers: 3, Completed: 100, Total: 2000, Received: 200}, resolved: true, want: want{eta: 19}},
		{name: "a gap", after: 9 * time.Second, progress: Progress{Peers: 3, Completed: 100, Total: 2000, Received: 200}, resolved: true, want: want{eta: 30}},
		{name: "stalled", after: time.Second, progress: Progress{Peers: 3, Completed: 100, Total: 2000, Received: 200}, resolved: true},
	} {
		clock = clock.Add(step.after)
		set(step.progress, step.resolved)
		got, err := m.Get(ctx, d.ID)
		if err != nil {
			t.Fatal(err)
		}
		if step.name == "stalled" {
			// Since the last bytes, not since the start.
			step.want = want{waiting: started.Add(12 * time.Second)}
		}
		if !got.WaitingSince.Equal(step.want.waiting) || got.Progress.ETA != step.want.eta {
			t.Fatalf("%s: waiting since %v, eta %d; want %v, %d", step.name, got.WaitingSince, got.Progress.ETA, step.want.waiting, step.want.eta)
		}
	}

	// Paused, it is neither.
	paused, err := m.SetPaused(ctx, d.ID, true)
	if err != nil {
		t.Fatal(err)
	}
	if !paused.WaitingSince.IsZero() || paused.Progress.ETA != 0 {
		t.Fatalf("paused = %+v", paused)
	}
}

// A new download directory takes the downloads started after it; one already
// made stays, and so does a pack already begun, and freeing either still
// finds its bytes.
func TestSetDirMovesOnlyNewDownloads(t *testing.T) {
	ctx := context.Background()
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, oldRoot := testManager(t, backend)
	first, err := m.Start(ctx, torrentRequest())
	if err != nil {
		t.Fatal(err)
	}
	newRoot := t.TempDir()
	m.SetDir(newRoot)
	if m.Dir() != newRoot {
		t.Fatalf("dir = %s, want %s", m.Dir(), newRoot)
	}

	episode := torrentRequest()
	two := 2
	episode.Source.Locator.FileIndex = &two
	sameTorrent, err := m.Start(ctx, episode)
	if err != nil {
		t.Fatal(err)
	}
	if sameTorrent.Dir != first.Dir {
		t.Fatalf("an episode of a running pack went to %s, want its pack's %s", sameTorrent.Dir, first.Dir)
	}
	film := torrentRequest()
	film.Source.Locator.InfoHash = "cafe"
	moved, err := m.Start(ctx, film)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(moved.Dir) != newRoot {
		t.Fatalf("a new download went to %s, want under %s", moved.Dir, newRoot)
	}

	// Freeing the old one deletes its file and directory under the old root.
	file := filepath.Join(first.Dir, "e1.mkv")
	if err := os.WriteFile(file, []byte("video"), 0o600); err != nil {
		t.Fatal(err)
	}
	backend.task.mu.Lock()
	backend.task.file = &fakeFile{path: file, size: 5}
	backend.task.mu.Unlock()
	if got, _ := m.Get(ctx, first.ID); len(m.Dirs(got)) != 1 || m.Dirs(got)[0] != first.Dir {
		t.Fatalf("dirs = %v, want %s", m.Dirs(got), first.Dir)
	}
	for _, id := range []string{first.ID, sameTorrent.ID} {
		if err := m.Remove(ctx, id, true); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(first.Dir); !os.IsNotExist(err) {
		t.Fatalf("%s outlived its downloads: %v", first.Dir, err)
	}
	if _, err := os.Stat(oldRoot); err != nil {
		t.Fatalf("the old root itself went: %v", err)
	}
}
