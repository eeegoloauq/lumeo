package acquire

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

type memStore struct {
	mu   sync.Mutex
	rows map[string]Download
}

func newMemStore() *memStore { return &memStore{rows: map[string]Download{}} }

func (m *memStore) SaveDownload(_ context.Context, d Download) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.rows[d.ID] = d
	return nil
}

func (m *memStore) Downloads(context.Context) ([]Download, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Download, 0, len(m.rows))
	for _, d := range m.rows {
		out = append(out, d)
	}
	return out, nil
}

func (m *memStore) Download(_ context.Context, id string) (Download, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.rows[id]
	return d, ok, nil
}

func (m *memStore) DeleteDownload(_ context.Context, id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.rows, id)
	return nil
}

type fakeFile struct {
	path string
	size int64
	head int64
}

func (f fakeFile) Path() string { return f.path }
func (f fakeFile) Size() int64  { return f.size }
func (f fakeFile) Head() int64  { return f.head }
func (f fakeFile) Open(context.Context) (io.ReadSeekCloser, error) {
	return nopReadSeekCloser{strings.NewReader("data")}, nil
}

type nopReadSeekCloser struct{ io.ReadSeeker }

func (nopReadSeekCloser) Close() error { return nil }

type fakeTask struct {
	mu       sync.Mutex
	progress Progress
	file     *fakeFile
	closed   bool
}

func (t *fakeTask) Progress() Progress {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.progress
}

func (t *fakeTask) File() (File, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.file == nil {
		return nil, false
	}
	return *t.file, true
}

func (t *fakeTask) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.closed = true
	return nil
}

type fakeBackend struct {
	scheme string
	starts int
	dirs   []string
	err    error
	task   *fakeTask
	closed bool
}

func (b *fakeBackend) Scheme() string { return b.scheme }

func (b *fakeBackend) Start(_ context.Context, _ sources.Locator, dir string) (Task, error) {
	b.starts++
	b.dirs = append(b.dirs, dir)
	if b.err != nil {
		return nil, b.err
	}
	if b.task == nil {
		b.task = &fakeTask{}
	}
	return b.task, nil
}

func (b *fakeBackend) Close() error {
	b.closed = true
	return nil
}

func testManager(t *testing.T, backend Backend) (*Manager, *memStore, string) {
	t.Helper()
	dir := t.TempDir()
	st := newMemStore()
	m := NewManager(dir, []Backend{backend}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	return m, st, dir
}

func torrentRequest() Request {
	return Request{
		ItemID: "abc123",
		Season: 2, Episode: 3,
		Source: sources.MediaSource{
			RawName: "Severance.S02E03.1080p",
			Size:    2000,
			Locator: sources.Locator{Scheme: "torrent", InfoHash: "deadbeef"},
		},
	}
}

func TestStartPersistsAndRuns(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent"}
	m, st, dir := testManager(t, backend)

	d, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if d.ID == "" || d.State != StateActive {
		t.Fatalf("download = %+v", d)
	}
	if d.Progress.Total != 2000 {
		t.Errorf("size from the source should seed Total, got %+v", d.Progress)
	}
	if _, err := os.Stat(filepath.Join(dir, d.ID)); err != nil {
		t.Errorf("download dir: %v", err)
	}
	if _, ok, _ := st.Download(context.Background(), d.ID); !ok {
		t.Error("download was not persisted")
	}
	if backend.starts != 1 {
		t.Errorf("backend started %d times", backend.starts)
	}
}

// A row says which copy it is the way the source list did, and what is stored
// stays the name alone, so a better parser relabels rows already on disk.
func TestDownloadCarriesItsRelease(t *testing.T) {
	m, st, _ := testManager(t, &fakeBackend{scheme: "torrent"})
	started, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	got, err := m.Get(context.Background(), started.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Release.Resolution != "1080p" {
		t.Errorf("get: release = %+v, want 1080p", got.Release)
	}
	if list := m.List(context.Background()); len(list) != 1 || list[0].Release.Resolution != "1080p" {
		t.Errorf("list: %+v", list)
	}
	if stored, _, _ := st.Download(context.Background(), started.ID); stored.Release.Resolution != "" {
		t.Errorf("stored row carries a parsed release: %+v", stored.Release)
	}
}

// Hitting Play twice on the same episode must not start the same torrent twice.
func TestStartIsIdempotentPerLocator(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent"}
	m, _, _ := testManager(t, backend)

	first, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	second, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start again: %v", err)
	}
	if first.ID != second.ID {
		t.Errorf("ids %q and %q, want the same download", first.ID, second.ID)
	}
	if backend.starts != 1 {
		t.Errorf("backend started %d times, want 1", backend.starts)
	}
}

// A second Play on a transfer that has been getting nothing starts it over:
// after a network change the old one never recovers by itself.
func TestStartRestartsAStalledTransfer(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent"}
	m, _, _ := testManager(t, backend)
	clock := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	m.now = func() time.Time { return clock }

	first, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	clock = clock.Add(stallAfter)
	second, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start again: %v", err)
	}
	if first.ID != second.ID || second.State != StateActive {
		t.Errorf("got %q %s, want %q active", second.ID, second.State, first.ID)
	}
	if backend.starts != 2 || !backend.task.closed {
		t.Errorf("backend started %d times, old task closed %v; want 2, true", backend.starts, backend.task.closed)
	}
}

func TestStartWithoutBackend(t *testing.T) {
	m, _, _ := testManager(t, &fakeBackend{scheme: "torrent"})
	req := torrentRequest()
	req.Source.Locator = sources.Locator{Scheme: "http", URL: "https://example.invalid/a.mkv"}
	if _, err := m.Start(context.Background(), req); err == nil {
		t.Error("expected an error for a scheme no backend handles")
	}
}

func TestProgressFlipsToDone(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, st, _ := testManager(t, backend)
	d, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	backend.task.mu.Lock()
	backend.task.progress = Progress{Completed: 2000, Total: 2000, Peers: 4}
	backend.task.file = &fakeFile{path: "/data/x.mkv", size: 2000, head: 2000}
	backend.task.mu.Unlock()

	got, err := m.Get(context.Background(), d.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !got.Ready {
		t.Error("a finished file is not ready")
	}
	if got.State != StateDone {
		t.Errorf("state %q, want done", got.State)
	}
	if got.FilePath != "/data/x.mkv" {
		t.Errorf("file path %q", got.FilePath)
	}
	stored, _, _ := st.Download(context.Background(), d.ID)
	if stored.State != StateDone {
		t.Errorf("stored state %q, want the finished state to survive a restart", stored.State)
	}
}

// Knowing the name of the file is not having any of it. A player told the
// download was ready opened a stream whose every read blocked on a swarm that
// had handed over nothing, ran out of patience and put "this copy has no
// picture" over a download that was perfectly fine.
func TestReadyWaitsForTheStartOfTheFile(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, _ := testManager(t, backend)
	d, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	backend.task.mu.Lock()
	backend.task.progress = Progress{Total: 2000, Peers: 2}
	backend.task.file = &fakeFile{path: "/data/x.mkv", size: 2000}
	backend.task.mu.Unlock()

	got, err := m.Get(context.Background(), d.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Ready {
		t.Error("ready with nothing at the front of the file")
	}
	if got.FilePath != "/data/x.mkv" {
		t.Errorf("file path %q, want the name to be known all the same", got.FilePath)
	}

	backend.task.mu.Lock()
	backend.task.file = &fakeFile{path: "/data/x.mkv", size: 2000, head: 256}
	backend.task.mu.Unlock()

	got, err = m.Get(context.Background(), d.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !got.Ready {
		t.Error("not ready with the start of the file on disk")
	}
}

// Stopping a download and throwing away what it downloaded are different
// intentions, so they are different calls.
func TestRemoveKeepsDataUnlessAsked(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, st, dir := testManager(t, backend)
	d, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := m.Remove(context.Background(), d.ID, false); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if !backend.task.closed {
		t.Error("task was not stopped")
	}
	if _, err := os.Stat(filepath.Join(dir, d.ID)); err != nil {
		t.Errorf("data should have survived: %v", err)
	}
	if _, ok, _ := st.Download(context.Background(), d.ID); ok {
		t.Error("row should be gone")
	}
	if err := m.Remove(context.Background(), d.ID, false); !errors.Is(err, ErrNotFound) {
		t.Errorf("second remove: %v, want ErrNotFound", err)
	}

	d2, _ := m.Start(context.Background(), torrentRequest())
	if err := m.Remove(context.Background(), d2.ID, true); err != nil {
		t.Fatalf("remove with data: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, d2.ID)); !os.IsNotExist(err) {
		t.Errorf("data should be gone, got %v", err)
	}
}

// The episodes of a pack are one torrent, written where its first download
// started: freeing one episode must leave the others' files where they are.
func TestRemoveFreesOneEpisodeOfAPack(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, _ := testManager(t, backend)
	first, second := torrentRequest(), torrentRequest()
	one, two := 0, 1
	first.Source.Locator.FileIndex, second.Source.Locator.FileIndex = &one, &two
	d1, err := m.Start(context.Background(), first)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	d2, err := m.Start(context.Background(), second)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if d2.Dir != d1.Dir {
		t.Fatalf("second episode dir = %s, want the pack's %s", d2.Dir, d1.Dir)
	}
	if err := m.Remove(context.Background(), d1.ID, true); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, err := os.Stat(d1.Dir); err != nil {
		t.Fatalf("the pack's directory went with one episode: %v", err)
	}
	if err := m.Remove(context.Background(), d2.ID, true); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, err := os.Stat(d1.Dir); !os.IsNotExist(err) {
		t.Fatalf("the pack's directory outlived its last episode: %v", err)
	}
}

// Before the episodes of a torrent shared a directory, the second one's
// bytes landed in the first one's while it ran.
func TestRemoveKeepsAnotherEpisodesFileInItsDirectory(t *testing.T) {
	m, st, dir := testManager(t, &fakeBackend{scheme: "torrent"})
	d1, d2 := filepath.Join(dir, "one"), filepath.Join(dir, "two")
	for _, d := range []string{d1, d2} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"e1.mkv", "e2.mkv"} {
		if err := os.WriteFile(filepath.Join(d1, name), []byte("video"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	loc := sources.Locator{Scheme: "torrent", InfoHash: "deadbeef"}
	st.rows["one"] = Download{ID: "one", Locator: loc, Dir: d1, FilePath: filepath.Join(d1, "e1.mkv"), State: StateDone, Size: 5}
	st.rows["two"] = Download{ID: "two", Locator: loc, Dir: d2, FilePath: filepath.Join(d1, "e2.mkv"), State: StateDone, Size: 5}
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if err := m.Remove(context.Background(), "one", true); err != nil {
		t.Fatalf("remove: %v", err)
	}
	if _, err := os.Stat(filepath.Join(d1, "e1.mkv")); !os.IsNotExist(err) {
		t.Fatalf("the freed episode's file is still there: %v", err)
	}
	if _, err := os.Stat(filepath.Join(d1, "e2.mkv")); err != nil {
		t.Fatalf("the other episode's file went too: %v", err)
	}
	if err := m.Remove(context.Background(), "two", true); err != nil {
		t.Fatalf("remove: %v", err)
	}
	for _, d := range []string{d1, d2} {
		if _, err := os.Stat(d); !os.IsNotExist(err) {
			t.Fatalf("%s outlived both episodes: %v", d, err)
		}
	}
}

func TestResumeRestartsActiveDownloads(t *testing.T) {
	st := newMemStore()
	now := time.Now()
	rows := []Download{
		{ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"}, State: StateActive, Dir: t.TempDir(), CreatedAt: now},
		{ID: "b", Locator: sources.Locator{Scheme: "torrent", InfoHash: "bb"}, State: StateDone, Dir: t.TempDir(), CreatedAt: now.Add(-time.Hour)},
	}
	for _, row := range rows {
		if err := st.SaveDownload(context.Background(), row); err != nil {
			t.Fatal(err)
		}
	}
	backend := &fakeBackend{scheme: "torrent"}
	m := NewManager(t.TempDir(), []Backend{backend}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))

	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if backend.starts != 1 {
		t.Errorf("backend started %d times, want only the active one", backend.starts)
	}
	list := m.List(context.Background())
	if len(list) != 2 {
		t.Fatalf("list has %d downloads", len(list))
	}
	if list[0].ID != "a" {
		t.Errorf("newest first, got %q", list[0].ID)
	}
}

// A download whose backend refuses to start is kept as a failed row: the user
// asked for it, and silently forgetting is worse than showing the failure.
func TestResumeMarksFailures(t *testing.T) {
	st := newMemStore()
	row := Download{ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"}, State: StateActive, Dir: t.TempDir()}
	if err := st.SaveDownload(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	backend := &fakeBackend{scheme: "torrent", err: errors.New("no such torrent")}
	m := NewManager(t.TempDir(), []Backend{backend}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	got, err := m.Get(context.Background(), "a")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.State != StateFailed || got.Error == "" {
		t.Errorf("download = %+v, want a failed row carrying the reason", got)
	}
}

// A download that failed to start is started again at the next boot: what
// stopped it (a drive not mounted yet) may be gone, and the user still wants
// it. Until then it stays failed; once running it is active again.
func TestResumeRetriesFailures(t *testing.T) {
	st := newMemStore()
	row := Download{ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"}, State: StateFailed, Error: "no such directory", Dir: t.TempDir()}
	if err := st.SaveDownload(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))

	refusing := &fakeBackend{scheme: "torrent", err: errors.New("still no directory")}
	m := NewManager(t.TempDir(), []Backend{refusing}, st, log)
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if refusing.starts != 1 {
		t.Fatalf("backend asked %d times, want once", refusing.starts)
	}
	if got := st.rows["a"]; got.State != StateFailed || got.Error != "still no directory" {
		t.Fatalf("stored = %+v, want failed with the new reason", got)
	}

	backend := &fakeBackend{scheme: "torrent"}
	m = NewManager(t.TempDir(), []Backend{backend}, st, log)
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if backend.starts != 1 {
		t.Fatalf("backend started %d times, want once", backend.starts)
	}
	got, err := m.Get(context.Background(), "a")
	if err != nil {
		t.Fatal(err)
	}
	if got.State != StateActive || got.Error != "" || st.rows["a"].State != StateActive {
		t.Fatalf("download = %+v, stored %+v, want active with no error", got, st.rows["a"])
	}
}

func TestFileNotReadyYet(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, _ := testManager(t, backend)
	d, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if _, err := m.File(context.Background(), d.ID, 0); !errors.Is(err, ErrNotReady) {
		t.Errorf("got %v, want ErrNotReady while the metadata has not arrived", err)
	}
	if got, _ := m.Get(context.Background(), d.ID); got.Resolved {
		t.Error("resolved before the metadata arrived")
	}
	backend.task.mu.Lock()
	backend.task.file = &fakeFile{path: "/data/x.mkv", size: 10}
	backend.task.mu.Unlock()
	if got, _ := m.Get(context.Background(), d.ID); !got.Resolved {
		t.Error("not resolved once the backend knows the file")
	}

	f, err := m.File(context.Background(), d.ID, 0)
	if err != nil {
		t.Fatalf("file: %v", err)
	}
	if f.Path() != "/data/x.mkv" {
		t.Errorf("path %q", f.Path())
	}
	if _, err := m.File(context.Background(), "nope", 0); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown id: %v", err)
	}
}

// The metadata of a magnet link arrives seconds after the download starts, so
// a player asking to stream right away is told to wait, not turned away.
func TestFileWaitsForMetadata(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, _ := testManager(t, backend)
	d, err := m.Start(context.Background(), torrentRequest())
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	go func() {
		time.Sleep(150 * time.Millisecond)
		backend.task.mu.Lock()
		backend.task.file = &fakeFile{path: "/data/late.mkv", size: 10}
		backend.task.mu.Unlock()
	}()
	f, err := m.File(context.Background(), d.ID, 5*time.Second)
	if err != nil {
		t.Fatalf("file: %v", err)
	}
	if f.Path() != "/data/late.mkv" {
		t.Errorf("path %q", f.Path())
	}
}

// A restart does not resume finished downloads, so the file they left behind
// has to be playable without a torrent behind it.
func TestFileOfFinishedDownloadComesFromDisk(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "movie.mkv")
	if err := os.WriteFile(path, []byte("finished"), 0o600); err != nil {
		t.Fatal(err)
	}
	st := newMemStore()
	row := Download{
		ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"},
		State: StateDone, Dir: dir, FilePath: path, Size: 8,
	}
	if err := st.SaveDownload(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	m := NewManager(t.TempDir(), []Backend{&fakeBackend{scheme: "torrent"}}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}

	f, err := m.File(context.Background(), "a", 0)
	if err != nil {
		t.Fatalf("file: %v", err)
	}
	if f.Size() != 8 {
		t.Errorf("size %d", f.Size())
	}
	r, err := f.Open(context.Background())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer r.Close()
	got, err := io.ReadAll(r)
	if err != nil || string(got) != "finished" {
		t.Errorf("read %q, %v", got, err)
	}
}

// The bug that made a finished episode unplayable after a restart: the row
// came back from the store as done, and every field a player reads to decide
// whether it can open — ready, and the progress — was answered by a backend
// that is no longer running. So the client sat on "Finding the file in the
// swarm…" over a complete file, with "Complete on disk" in the corner of the
// same screen.
func TestFinishedDownloadIsReadyAfterRestart(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "episode.mkv")
	if err := os.WriteFile(path, []byte("finished"), 0o600); err != nil {
		t.Fatal(err)
	}
	st := newMemStore()
	row := Download{
		ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"},
		State: StateDone, Dir: dir, FilePath: path, Size: 8,
	}
	if err := st.SaveDownload(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	m := NewManager(t.TempDir(), []Backend{&fakeBackend{scheme: "torrent"}}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}

	got, err := m.Get(context.Background(), "a")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !got.Ready {
		t.Error("a complete file on disk is not ready to play")
	}
	if got.Progress.Total != 8 || got.Progress.Completed != 8 {
		t.Errorf("progress %d/%d, want 8/8", got.Progress.Completed, got.Progress.Total)
	}
}

// A finished file deleted or cut short outside the app is not on disk any
// more, whatever the row says: the row goes back to paused, in the store too,
// and File refuses it rather than stream a file that is not there.
func TestFinishedDownloadWithoutItsWholeFileIsPaused(t *testing.T) {
	for name, write := range map[string]bool{"deleted": false, "truncated": true} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "episode.mkv")
			if write {
				if err := os.WriteFile(path, []byte("fini"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			st := newMemStore()
			row := Download{
				ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"},
				State: StateDone, Dir: dir, FilePath: path, Size: 8,
			}
			if err := st.SaveDownload(context.Background(), row); err != nil {
				t.Fatal(err)
			}
			m := NewManager(t.TempDir(), []Backend{&fakeBackend{scheme: "torrent"}}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
			if err := m.Resume(context.Background()); err != nil {
				t.Fatalf("resume: %v", err)
			}
			if stored, _, _ := st.Download(context.Background(), "a"); stored.State != StatePaused {
				t.Errorf("stored state %q, want paused", stored.State)
			}
			got, err := m.Get(context.Background(), "a")
			if err != nil {
				t.Fatalf("get: %v", err)
			}
			if got.Ready || got.State != StatePaused {
				t.Errorf("ready %v, state %q; want not ready and paused", got.Ready, got.State)
			}
			if _, err := m.File(context.Background(), "a", 0); !errors.Is(err, ErrNotRunning) {
				t.Errorf("file: got %v, want ErrNotRunning", err)
			}
		})
	}
}

// Play on a copy that is known but not running starts it again, in the same
// directory, so what is still on disk is kept.
func TestStartRestartsAStoppedDownload(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent"}
	m, st, _ := testManager(t, backend)
	req := torrentRequest()
	row := Download{
		ID: "a", Locator: req.Source.Locator, State: StatePaused,
		Dir: filepath.Join(t.TempDir(), "a"), Size: 2000,
	}
	if err := st.SaveDownload(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}

	got, err := m.Start(context.Background(), req)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if got.ID != "a" || got.State != StateActive {
		t.Errorf("got %s %q, want a active", got.ID, got.State)
	}
	if backend.starts != 1 || backend.dirs[0] != row.Dir {
		t.Errorf("starts %d in %v, want 1 in %s", backend.starts, backend.dirs, row.Dir)
	}
	if stored, _, _ := st.Download(context.Background(), "a"); stored.State != StateActive {
		t.Errorf("stored state %q, want active", stored.State)
	}
	if _, err := m.Start(context.Background(), req); err != nil || backend.starts != 1 {
		t.Errorf("second start: %v, starts %d; want the running task", err, backend.starts)
	}
}

// A download that was stopped has nothing to stream and says so.
func TestFileOfStoppedDownload(t *testing.T) {
	st := newMemStore()
	row := Download{ID: "a", Locator: sources.Locator{Scheme: "torrent", InfoHash: "aa"}, State: StatePaused}
	if err := st.SaveDownload(context.Background(), row); err != nil {
		t.Fatal(err)
	}
	m := NewManager(t.TempDir(), []Backend{&fakeBackend{scheme: "torrent"}}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := m.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	if _, err := m.File(context.Background(), "a", 0); !errors.Is(err, ErrNotRunning) {
		t.Errorf("got %v, want ErrNotRunning", err)
	}
}

func TestCloseStopsEverything(t *testing.T) {
	backend := &fakeBackend{scheme: "torrent", task: &fakeTask{}}
	m, _, _ := testManager(t, backend)
	if _, err := m.Start(context.Background(), torrentRequest()); err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := m.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if !backend.task.closed || !backend.closed {
		t.Errorf("task closed=%v, backend closed=%v", backend.task.closed, backend.closed)
	}
}

func TestLocalFileRemovalAndResume(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "film.mkv")
	if err := os.WriteFile(path, []byte("movie"), 0600); err != nil {
		t.Fatal(err)
	}
	backend := &fakeBackend{scheme: "file", task: &fakeTask{progress: Progress{Completed: 5, Total: 5}, file: &fakeFile{path: path, size: 5, head: 5}}}
	m, st, dir := testManager(t, backend)
	req := Request{Source: sources.MediaSource{RawName: "film.mkv", Size: 5, Locator: sources.Locator{Scheme: "file", Path: path}}}
	// A path in a request is not a file the user opened.
	if _, err := m.Start(ctx, req); !errors.Is(err, ErrLocalNotOpened) {
		t.Fatalf("a new local file started by name: %v", err)
	}
	d, err := m.OpenLocal(ctx, req)
	if err != nil {
		t.Fatal(err)
	}
	if d.Dir != "" || d.State != StateDone {
		t.Fatalf("download=%+v", d)
	}
	if _, err := os.Stat(filepath.Join(dir, d.ID)); !os.IsNotExist(err) {
		t.Fatalf("owned directory exists: %v", err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if got, err := m.Get(ctx, d.ID); err != nil || got.State != StatePaused {
		t.Fatalf("live missing=%+v err=%v", got, err)
	}
	if _, err := m.File(ctx, d.ID, 0); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("missing stream: %v", err)
	}
	if err := os.WriteFile(path, []byte("movie"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Start(ctx, req); err != nil {
		t.Fatalf("reopen: %v", err)
	}
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	resumed := NewManager(dir, []Backend{backend}, st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := resumed.Resume(ctx); err != nil {
		t.Fatal(err)
	}
	got, err := resumed.Get(ctx, d.ID)
	if err != nil || got.State != StateDone || !got.Ready {
		t.Fatalf("resumed=%+v err=%v", got, err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	got, err = resumed.Get(ctx, d.ID)
	if err != nil || got.State != StatePaused {
		t.Fatalf("missing=%+v err=%v", got, err)
	}
	if err := os.WriteFile(path, []byte("movie"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := resumed.Remove(ctx, d.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("user file removed: %v", err)
	}
}
