package acquire

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

var (
	// ErrNotFound means the id is not a download we know about.
	ErrNotFound = errors.New("acquire: download not found")
	// ErrNotRunning means the download exists but nothing is moving its bytes
	// and there is no finished file to fall back on.
	ErrNotRunning = errors.New("acquire: download is not running")
	// ErrNotReady means the backend has not learned yet what it is
	// downloading. For a magnet link that is the wait for metadata.
	ErrNotReady = errors.New("acquire: file is not known yet")
	// ErrNothingToFetch means a pause or resume was asked of a download that
	// has nothing left to fetch: a finished one, or a file on this machine.
	ErrNothingToFetch = errors.New("acquire: download has nothing to fetch")
)

// filePollInterval is how often we look for the metadata to have arrived.
// Cheap enough at this rate, and the alternative — a notification through the
// Backend interface — buys milliseconds for a wait that lasts seconds.
const filePollInterval = 100 * time.Millisecond

const (
	// stallAfter is how long an active download may get nothing before it
	// counts as waiting: long enough for the gaps of a slow peer between
	// blocks, short enough that a dead swarm says so.
	stallAfter = 10 * time.Second
	// rateSample is the shortest interval a rate is measured over. Two polls
	// a millisecond apart would read one block as megabytes a second.
	rateSample = time.Second
	// rateSmoothing is the time constant of the rate an ETA is made from:
	// a swarm's rate swings by the second, and an ETA that jumps with it
	// says nothing.
	rateSmoothing = 20 * time.Second
)

// Manager owns the downloads: which exist, where their bytes live, and which
// backend is moving them. It is the only thing the API talks to.
type Manager struct {
	backends map[string]Backend
	store    Store
	log      *slog.Logger
	now      func() time.Time

	startMu sync.Mutex

	mu    sync.Mutex
	dir   string
	rows  map[string]Download
	tasks map[string]Task
	flows map[string]*flow
}

func NewManager(dir string, backends []Backend, store Store, log *slog.Logger) *Manager {
	m := &Manager{
		dir:      dir,
		backends: make(map[string]Backend, len(backends)),
		store:    store,
		log:      log,
		now:      time.Now,
		rows:     make(map[string]Download),
		tasks:    make(map[string]Task),
		flows:    make(map[string]*flow),
	}
	for _, b := range backends {
		m.backends[b.Scheme()] = b
	}
	return m
}

// Dir is where new downloads go, and the filesystem storage reports.
func (m *Manager) Dir() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.dir
}

// SetDir moves where downloads started from now on go. Those already made
// stay where they are, the episodes of a pack already begun included: its
// torrent writes in one directory.
func (m *Manager) SetDir(dir string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dir = dir
}

// Resume restarts at boot what was running when the core stopped, and what
// failed to start before: a failure here is the backend refusing to begin
// (a drive not mounted yet, a directory gone), which a later boot may not
// meet. A download that fails again is kept as a failed row rather than
// dropped: the user asked for it, and silently forgetting is worse.
func (m *Manager) Resume(ctx context.Context) error {
	rows, err := m.store.Downloads(ctx)
	if err != nil {
		return err
	}
	for _, row := range rows {
		m.mu.Lock()
		m.rows[row.ID] = row
		m.mu.Unlock()
		if row.State != StateActive && row.State != StateFailed {
			// A finished file deleted while the core was down stops being
			// "done" here, before anything lists it as on disk.
			m.snapshot(ctx, row)
			continue
		}
		if err := m.restart(ctx, row); err != nil {
			m.log.Warn("resume failed", "download", row.ID, "err", err)
		}
	}
	return nil
}

// ErrLocalNotOpened means a request named a file on this machine that the
// core was never asked to open.
var ErrLocalNotOpened = errors.New("acquire: a local file is added by opening it, not by naming it")

// Start acquires the source, or returns the download already doing so. A file
// on this machine is started only if it is already a download: the path in a
// request is whatever the caller wrote, and OpenLocal is the one way in for
// a new one.
func (m *Manager) Start(ctx context.Context, req Request) (Download, error) {
	return m.start(ctx, req, false)
}

// OpenLocal is Start for a file on this machine the user opened with the app.
func (m *Manager) OpenLocal(ctx context.Context, req Request) (Download, error) {
	if req.Source.Locator.Scheme != "file" {
		return Download{}, fmt.Errorf("acquire: %q is not a local file", req.Source.Locator.Scheme)
	}
	return m.start(ctx, req, true)
}

func (m *Manager) start(ctx context.Context, req Request, local bool) (Download, error) {
	if req.Source.Locator.Scheme == "" {
		return Download{}, errors.New("acquire: source has no locator")
	}
	if _, ok := m.backends[req.Source.Locator.Scheme]; !ok {
		return Download{}, fmt.Errorf("acquire: no backend for %q sources", req.Source.Locator.Scheme)
	}
	// One Start at a time: two presses of Play on the same copy must not
	// create two rows, or run two tasks over one.
	m.startMu.Lock()
	defer m.startMu.Unlock()
	if existing, ok := m.findByLocator(req.Source.Locator); ok {
		existing = m.snapshot(ctx, existing)
		if existing.State == StateDone {
			return existing, nil
		}
		if m.running(existing.ID) {
			if !stalled(existing, m.now()) {
				return existing, nil
			}
			// Play on a transfer that gets nothing asks for a fresh one: the
			// swarm it found may be unreachable now (the network changed
			// under it: a VPN, another Wi-Fi), and only a new torrent
			// announces and connects again.
			m.stopTask(existing.ID)
		}
		// Known but nothing running, and no whole file: pressing Play is
		// asking for it again.
		if err := m.restart(ctx, existing); err != nil {
			return Download{}, err
		}
		return m.snapshot(ctx, m.row(existing.ID)), nil
	}

	if req.Source.Locator.Scheme == "file" && !local {
		return Download{}, ErrLocalNotOpened
	}
	now := m.now()
	row := Download{
		ID:        newID(),
		ItemID:    req.ItemID,
		Season:    req.Season,
		Episode:   req.Episode,
		Name:      req.Source.RawName,
		Locator:   req.Source.Locator,
		Size:      req.Source.Size,
		State:     StateActive,
		CreatedAt: now,
		UpdatedAt: now,
	}
	// A local file belongs to the user, not the download manager.
	if row.Locator.Scheme != "file" {
		// The backend runs one torrent per infohash and writes it where its
		// first download started, so the episodes of a pack share that
		// directory rather than each owning one.
		row.Dir = m.torrentDir(row.Locator)
		if row.Dir == "" {
			row.Dir = filepath.Join(m.Dir(), row.ID)
		}
		// 0700: what someone watches is nobody else's business, least of all
		// another account on a shared machine.
		if err := os.MkdirAll(row.Dir, 0o700); err != nil {
			return Download{}, fmt.Errorf("acquire: create download dir: %w", err)
		}
	}
	// Persisted before it runs: a crash between these two leaves a row we can
	// resume, while the reverse leaves bytes on disk nobody owns.
	if err := m.store.SaveDownload(ctx, row); err != nil {
		return Download{}, err
	}
	m.mu.Lock()
	m.rows[row.ID] = row
	m.mu.Unlock()

	if err := m.startTask(ctx, row); err != nil {
		m.fail(ctx, row, err)
		return Download{}, err
	}
	return m.snapshot(ctx, row), nil
}

// restart runs a known download again, as active, or records why it could
// not. The directory and its completion record are kept, so whatever is
// still on disk is not fetched twice.
func (m *Manager) restart(ctx context.Context, row Download) error {
	if row.State != StateActive || row.PausedByUser {
		row.State, row.Error, row.PausedByUser, row.UpdatedAt = StateActive, "", false, m.now()
		if err := m.store.SaveDownload(ctx, row); err != nil {
			return err
		}
		m.mu.Lock()
		m.rows[row.ID] = row
		m.mu.Unlock()
	}
	if err := m.startTask(ctx, row); err != nil {
		m.fail(ctx, row, err)
		return err
	}
	return nil
}

// row is the stored row of a download known to exist.
func (m *Manager) row(id string) Download {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.rows[id]
}

func (m *Manager) startTask(ctx context.Context, row Download) error {
	backend, ok := m.backends[row.Locator.Scheme]
	if !ok {
		return fmt.Errorf("acquire: no backend for %q sources", row.Locator.Scheme)
	}
	task, err := backend.Start(ctx, row.Locator, row.Dir)
	if err != nil {
		return err
	}
	m.mu.Lock()
	m.tasks[row.ID] = task
	m.flows[row.ID] = &flow{arrived: m.now()}
	m.mu.Unlock()
	return nil
}

// SetPaused pauses a download or resumes it. A pause stops the transfer and
// keeps every byte; it lasts until it is resumed or played, restarts of the
// core included. Resuming a failed download retries it. A download of one
// episode of a pack pauses that episode: the torrent goes on for the others.
func (m *Manager) SetPaused(ctx context.Context, id string, paused bool) (Download, error) {
	// A Start in the meantime could restart what is being paused.
	m.startMu.Lock()
	defer m.startMu.Unlock()
	m.mu.Lock()
	row, ok := m.rows[id]
	m.mu.Unlock()
	if !ok {
		return Download{}, ErrNotFound
	}
	if row = m.snapshot(ctx, row); row.State == StateDone || row.Locator.Scheme == "file" {
		return Download{}, ErrNothingToFetch
	}
	if !paused {
		if row.State == StateActive && m.running(id) {
			return row, nil
		}
		if err := m.restart(ctx, row); err != nil {
			// Retried and failed again: that is the answer, not an error of
			// the request.
			if again := m.row(id); again.State == StateFailed {
				return again, nil
			}
			return Download{}, err
		}
		return m.snapshot(ctx, m.row(id)), nil
	}

	m.stopTask(id)
	// Only the fields a pause changes: Identify may have named the row since
	// the snapshot. The lock is held through the write, as in persist.
	m.mu.Lock()
	defer m.mu.Unlock()
	current := m.rows[id]
	// Nothing opens without the transfer, so it is not ready; how far it had
	// got stays, which is what a paused row shows.
	current.State, current.PausedByUser, current.Error, current.Ready = StatePaused, true, "", false
	current.Progress = Progress{Completed: row.Progress.Completed, Total: row.Progress.Total}
	current.UpdatedAt = m.now()
	if err := m.store.SaveDownload(ctx, current); err != nil {
		return Download{}, err
	}
	m.rows[id] = current
	return current, nil
}

func (m *Manager) List(ctx context.Context) []Download {
	m.mu.Lock()
	rows := make([]Download, 0, len(m.rows))
	for _, row := range m.rows {
		rows = append(rows, row)
	}
	m.mu.Unlock()

	out := make([]Download, 0, len(rows))
	for _, row := range rows {
		out = append(out, m.snapshot(ctx, row))
	}
	sortByCreated(out)
	return out
}

// Find is the download of this exact file, if there is one, as far as it has
// got: a download only becomes done when somebody looks.
func (m *Manager) Find(ctx context.Context, loc sources.Locator) (Download, bool) {
	row, ok := m.findByLocator(loc)
	if !ok {
		return Download{}, false
	}
	return m.snapshot(ctx, row), true
}

func (m *Manager) Get(ctx context.Context, id string) (Download, error) {
	m.mu.Lock()
	row, ok := m.rows[id]
	m.mu.Unlock()
	if !ok {
		return Download{}, ErrNotFound
	}
	return m.snapshot(ctx, row), nil
}

// File is the playable file of a download. This is what the streaming endpoint
// reads through. wait bounds how long to give a backend that has not learned
// yet what it is downloading; pass 0 to not wait at all.
func (m *Manager) File(ctx context.Context, id string, wait time.Duration) (File, error) {
	m.mu.Lock()
	task, running := m.tasks[id]
	row, known := m.rows[id]
	m.mu.Unlock()
	if !known {
		return nil, ErrNotFound
	}
	if row.Locator.Scheme == "file" {
		return m.localFile(ctx, row)
	}
	if !running {
		// A finished download is a file on disk. Needing a live torrent to
		// play something already downloaded would mean a restart takes the
		// library away with it.
		return finishedFile(row)
	}

	deadline := m.now().Add(wait)
	for {
		if f, ok := task.File(); ok {
			return f, nil
		}
		if !m.now().Before(deadline) {
			return nil, ErrNotReady
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(filePollInterval):
		}
	}
}

// localFile is a file the user opened, read through its backend every time
// rather than straight off the disk: that backend is what checks the path
// still holds a video, and a path is the user's to change between plays.
// Its tasks hold nothing, so one per read costs nothing.
func (m *Manager) localFile(ctx context.Context, row Download) (File, error) {
	if row = m.snapshot(ctx, row); row.State != StateDone {
		return nil, ErrNotRunning
	}
	backend, ok := m.backends[row.Locator.Scheme]
	if !ok {
		return nil, fmt.Errorf("acquire: no backend for %q sources", row.Locator.Scheme)
	}
	task, err := backend.Start(ctx, row.Locator, "")
	if err != nil {
		return nil, err
	}
	f, ok := task.File()
	if !ok {
		return nil, ErrNotReady
	}
	return f, nil
}

// settled is what a download nothing is running for can still say for itself.
//
// Ready and Progress are answered by the backend, and a download that finished
// before the core was last stopped has no backend behind it: the row comes back
// from the store saying "done" while everything a player needs in order to open
// it says "not yet". What finished is a file, so the file is what answers — and
// when the file is gone or no longer its full size, deleted or cut short outside
// the app, the download is not done any more: it goes back to paused, which
// stops it being offered as on disk and lets the next Play fetch it again.
func settled(row Download) Download {
	if row.State != StateDone {
		return row
	}
	info, err := os.Stat(row.FilePath)
	if row.FilePath == "" || err != nil || !info.Mode().IsRegular() || (row.Size > 0 && info.Size() != row.Size) {
		row.State = StatePaused
		row.Ready, row.Resolved = false, false
		return row
	}
	row.Ready, row.Resolved = true, true
	row.Size = info.Size()
	row.Progress = Progress{Completed: info.Size(), Total: info.Size()}
	return row
}

func finishedFile(row Download) (File, error) {
	if row = settled(row); row.State != StateDone {
		return nil, ErrNotRunning
	}
	return diskFile{path: row.FilePath, size: row.Size}, nil
}

// diskFile is a completed download, read straight from the filesystem.
type diskFile struct {
	path string
	size int64
}

func (f diskFile) Path() string { return f.path }
func (f diskFile) Size() int64  { return f.size }

// The whole file is on disk; there is nothing to wait for.
func (f diskFile) Head() int64 { return f.size }
func (f diskFile) Open(context.Context) (io.ReadSeekCloser, error) {
	return os.Open(f.path)
}

// Remove stops a download. The data survives unless deleteData says otherwise,
// because "stop wasting my bandwidth" and "throw away what I downloaded" are
// different intentions.
func (m *Manager) Remove(ctx context.Context, id string, deleteData bool) error {
	// A Start in the meantime could hand a directory being deleted to a new
	// episode of the same torrent.
	m.startMu.Lock()
	defer m.startMu.Unlock()
	m.mu.Lock()
	row, ok := m.rows[id]
	task := m.tasks[id]
	delete(m.rows, id)
	delete(m.tasks, id)
	delete(m.flows, id)
	rest := make([]Download, 0, len(m.rows))
	running := make(map[string]bool, len(m.tasks))
	for _, other := range m.rows {
		rest = append(rest, other)
		running[other.ID] = m.tasks[other.ID] != nil
	}
	m.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	if task != nil {
		if err := task.Close(); err != nil {
			m.log.Warn("stopping download failed", "download", id, "err", err)
		}
	}
	if err := m.store.DeleteDownload(ctx, id); err != nil {
		return err
	}
	if deleteData && row.Locator.Scheme != "file" {
		return m.removeData(row, rest, running)
	}
	return nil
}

// removeData deletes a download's file, and each of its directories that no
// other download still keeps bytes in.
func (m *Manager) removeData(row Download, rest []Download, running map[string]bool) error {
	if fileRoot(row) != "" {
		if err := os.Remove(row.FilePath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("acquire: remove data: %w", err)
		}
	}
	for _, dir := range m.Dirs(row) {
		if m.holds(dir, row, rest, running) {
			continue
		}
		if err := os.RemoveAll(dir); err != nil {
			return fmt.Errorf("acquire: remove data: %w", err)
		}
	}
	return nil
}

// holds says whether another download keeps bytes in dir: its directory or
// its file is there, or it is a running download of the same torrent, which
// writes wherever that torrent's first download started.
func (m *Manager) holds(dir string, row Download, rest []Download, running map[string]bool) bool {
	for _, other := range rest {
		if slices.Contains(m.Dirs(other), dir) || running[other.ID] && sameTorrent(row.Locator, other.Locator) {
			return true
		}
	}
	return false
}

// Dirs are the directories under the download root that hold a download's
// bytes: its own, and the one its file is in. They differ for an episode of a
// pack started before the episodes of one torrent shared a directory.
func (m *Manager) Dirs(row Download) []string {
	if row.Locator.Scheme == "file" {
		return nil
	}
	var dirs []string
	if row.Dir != "" {
		dirs = append(dirs, absolute(row.Dir))
	}
	if root := fileRoot(row); root != "" && !slices.Contains(dirs, root) {
		dirs = append(dirs, root)
	}
	return dirs
}

// fileRoot is the directory directly under the download's root that its file
// is in, or "" for a file outside it. The root is the one the download was
// started under, the directory its own is in: the setting that chose it may
// have moved on since.
func fileRoot(row Download) string {
	if row.FilePath == "" || row.Dir == "" {
		return ""
	}
	root := filepath.Dir(absolute(row.Dir))
	rel, err := filepath.Rel(root, absolute(row.FilePath))
	if err != nil || rel == "." || !filepath.IsLocal(rel) {
		return ""
	}
	return filepath.Join(root, strings.SplitN(filepath.ToSlash(rel), "/", 2)[0])
}

func absolute(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		return abs
	}
	return filepath.Clean(path)
}

// torrentDir is the directory of another download of the same torrent.
func (m *Manager) torrentDir(loc sources.Locator) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, row := range m.rows {
		if row.Dir != "" && sameTorrent(loc, row.Locator) {
			return row.Dir
		}
	}
	return ""
}

func sameTorrent(a, b sources.Locator) bool {
	return a.Scheme == "torrent" && b.Scheme == "torrent" && a.InfoHash != "" && a.InfoHash == b.InfoHash
}

// Close stops everything without touching the data, so the next boot resumes.
func (m *Manager) Close() error {
	m.mu.Lock()
	tasks := make([]Task, 0, len(m.tasks))
	for _, t := range m.tasks {
		tasks = append(tasks, t)
	}
	m.tasks = make(map[string]Task)
	m.flows = make(map[string]*flow)
	m.mu.Unlock()

	var err error
	for _, t := range tasks {
		err = errors.Join(err, t.Close())
	}
	for _, b := range m.backends {
		err = errors.Join(err, b.Close())
	}
	return err
}

// snapshot merges what the backend knows right now into the stored row, and
// persists only when something worth persisting changed.
func (m *Manager) snapshot(ctx context.Context, row Download) Download {
	row.Release = release.Parse(row.Name)
	m.mu.Lock()
	task := m.tasks[row.ID]
	m.mu.Unlock()
	if task == nil {
		updated := settled(row)
		if updated.State != row.State {
			m.persist(ctx, updated)
		}
		return updated
	}

	updated := row
	updated.Progress = task.Progress()
	if f, ok := task.File(); ok {
		updated.FilePath = f.Path()
		updated.Resolved = true
		// Which file it is, and whether any of it is here. Answering the first
		// alone is what sent the player at a stream whose every read blocked.
		updated.Ready = f.Head() > 0
		if size := f.Size(); size > 0 {
			updated.Size = size
		}
	}
	if updated.Progress.Total == 0 && updated.Size > 0 {
		updated.Progress.Total = updated.Size
	}
	if updated.Progress.Total > 0 && updated.Progress.Completed >= updated.Progress.Total ||
		updated.Locator.Scheme == "file" && updated.FilePath != "" {
		updated.State = StateDone
	}
	if updated.Locator.Scheme == "file" {
		updated = settled(updated)
		// A file gone from under its task: the next Start opens it afresh.
		// Only this task — a Start since may already have put a new one.
		if updated.State == StatePaused {
			m.mu.Lock()
			if m.tasks[row.ID] == task {
				delete(m.tasks, row.ID)
			}
			m.mu.Unlock()
		}
	}

	if updated.State != row.State ||
		updated.FilePath != row.FilePath ||
		updated.Size != row.Size {
		m.persist(ctx, updated)
	}

	// After persist: how the bytes are arriving is of this moment, and not
	// something a stored row should carry.
	m.mu.Lock()
	if f := m.flows[row.ID]; f != nil && m.tasks[row.ID] == task && updated.State == StateActive {
		now := m.now()
		f.sample(now, updated.Progress.Received)
		updated.WaitingSince, updated.Progress.ETA = f.report(now, updated)
	}
	m.mu.Unlock()
	return updated
}

// flow is how the bytes of one running download have been arriving.
type flow struct {
	primed   bool
	sampled  time.Time // when received was read
	received int64
	rate     float64   // bytes per second, smoothed
	arrived  time.Time // when bytes last arrived, or the transfer started
}

// sample folds in the count of bytes received so far. The first reading is
// only a baseline: a torrent another download already runs has counted
// bytes before this one started.
func (f *flow) sample(now time.Time, received int64) {
	if !f.primed {
		f.primed, f.sampled, f.received = true, now, received
		return
	}
	// Two snapshots racing can read the counter out of order.
	if received < f.received {
		return
	}
	if received > f.received {
		f.arrived = now
	}
	elapsed := now.Sub(f.sampled)
	if elapsed < rateSample {
		return
	}
	instant := float64(received-f.received) / elapsed.Seconds()
	if f.rate == 0 {
		f.rate = instant
	} else {
		// Weighted by the time the sample covers, so polling faster or
		// slower does not change how smooth the rate is.
		f.rate += (1 - math.Exp(-elapsed.Seconds()/rateSmoothing.Seconds())) * (instant - f.rate)
	}
	f.sampled, f.received = now, received
}

// report is when the download started waiting, if it is waiting, or else how
// many seconds are left at the smoothed rate. Never both: an ETA is given
// only while bytes arrive.
func (f *flow) report(now time.Time, d Download) (waiting time.Time, eta int64) {
	if !d.Resolved || d.Progress.Peers == 0 || now.Sub(f.arrived) >= stallAfter {
		return f.arrived, 0
	}
	left := d.Progress.Total - d.Progress.Completed
	if f.rate <= 0 || left <= 0 {
		return time.Time{}, 0
	}
	return time.Time{}, int64(math.Ceil(float64(left) / f.rate))
}

// persist stores what a snapshot learned from the backend. It holds the lock
// through the write so a snapshot taken before Remove cannot put the removed
// row back, and takes only those fields so one taken before Identify cannot
// take the title back off it.
func (m *Manager) persist(ctx context.Context, snap Download) {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[snap.ID]
	// Nor can one taken before a pause undo it: a paused row has no task,
	// so a snapshot that saw one is older than the pause.
	if !ok || row.PausedByUser {
		return
	}
	row.State, row.FilePath, row.Size = snap.State, snap.FilePath, snap.Size
	row.Progress, row.Ready, row.Resolved, row.UpdatedAt = snap.Progress, snap.Ready, snap.Resolved, m.now()
	m.rows[row.ID] = row
	if err := m.store.SaveDownload(ctx, row); err != nil {
		m.log.Warn("saving download failed", "download", row.ID, "err", err)
	}
}

// Identify gives a download the title it turned out to be: a file opened with
// the app is registered before it is identified, so that it plays at once.
func (m *Manager) Identify(ctx context.Context, id, itemID string, season, episode int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	row, ok := m.rows[id]
	if !ok {
		return ErrNotFound
	}
	row.ItemID, row.Season, row.Episode, row.UpdatedAt = itemID, season, episode, m.now()
	m.rows[id] = row
	return m.store.SaveDownload(ctx, row)
}

// stopTask ends a download's transfer and leaves its row as it is.
func (m *Manager) stopTask(id string) {
	m.mu.Lock()
	task := m.tasks[id]
	delete(m.tasks, id)
	delete(m.flows, id)
	m.mu.Unlock()
	if task != nil {
		if err := task.Close(); err != nil {
			m.log.Warn("stopping download failed", "download", id, "err", err)
		}
	}
}

// stalled says whether a running download has been getting nothing for
// longer than a gap between blocks.
func stalled(d Download, now time.Time) bool {
	return !d.WaitingSince.IsZero() && now.Sub(d.WaitingSince) >= stallAfter
}

func (m *Manager) running(id string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.tasks[id] != nil
}

func (m *Manager) fail(ctx context.Context, row Download, cause error) {
	row.State = StateFailed
	row.Error = cause.Error()
	row.UpdatedAt = m.now()
	m.mu.Lock()
	m.rows[row.ID] = row
	m.mu.Unlock()
	if err := m.store.SaveDownload(ctx, row); err != nil {
		m.log.Warn("saving failed download failed", "download", row.ID, "err", err)
	}
}

// findByLocator is what stops the same torrent being started twice when the
// user hits Play again on an episode that is already coming down.
func (m *Manager) findByLocator(loc sources.Locator) (Download, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, row := range m.rows {
		if row.Locator.Same(loc) {
			return row, true
		}
	}
	return Download{}, false
}

func sortByCreated(rows []Download) {
	sort.SliceStable(rows, func(i, j int) bool {
		return rows[i].CreatedAt.After(rows[j].CreatedAt)
	})
}
