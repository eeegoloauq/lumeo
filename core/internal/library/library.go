// Package library keeps what is on disk to the keep policy: it frees what the
// viewer finished once the policy says so, and nothing they have not, except
// an unfinished copy of an episode they went on to play another copy of.
package library

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
)

type Downloads interface {
	List(context.Context) []acquire.Download
	Remove(context.Context, string, bool) error
	SetPaused(context.Context, string, bool) (acquire.Download, error)
	StopSharing(context.Context, string) error
	Dirs(acquire.Download) []string
	Dir() string
}

type Progress interface {
	AllProgress(context.Context) ([]progress.Entry, error)
}

type Preferences interface {
	Get(context.Context) (preferences.Preferences, error)
}

const (
	// every is how often a pass runs with nothing asking for one: often
	// enough for the days to keep and a download filling the ceiling.
	every = 10 * time.Minute
	// settle is how long a download counts as playing after its last stream
	// closed: a player reconnects on every seek, and the credits of an
	// episode that already counts as watched are still on screen.
	settle = 10 * time.Minute
	day    = 24 * time.Hour
)

type Service struct {
	downloads Downloads
	progress  Progress
	prefs     Preferences
	log       *slog.Logger
	now       func() time.Time
	kick      chan struct{}

	// mu is held through a removal, so a stream cannot start on a file that
	// is being freed.
	mu      sync.Mutex
	streams map[string]int
	stopped map[string]time.Time
	// played is when each download last opened a stream, which tells the
	// copy of an episode the viewer chose last.
	played map[string]time.Time
}

type episode struct {
	item            string
	season, episode int
}

func episodeOf(row acquire.Download) episode {
	return episode{row.ItemID, row.Season, row.Episode}
}

func New(downloads Downloads, progress Progress, prefs Preferences, log *slog.Logger) *Service {
	return &Service{
		downloads: downloads,
		progress:  progress,
		prefs:     prefs,
		log:       log,
		now:       time.Now,
		kick:      make(chan struct{}, 1),
		streams:   make(map[string]int),
		stopped:   make(map[string]time.Time),
		played:    make(map[string]time.Time),
	}
}

// Run cleans at start, on every Kick and every few minutes, until ctx ends.
func (s *Service) Run(ctx context.Context) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		if err := s.Clean(ctx); err != nil && ctx.Err() == nil {
			s.log.Warn("cleaning the library failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-s.kick:
		}
	}
}

// Kick asks for a pass soon: something the policy looks at has changed.
func (s *Service) Kick() {
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// Play marks a download as playing until the returned func is called.
func (s *Service) Play(id string) (done func()) {
	s.mu.Lock()
	s.streams[id]++
	s.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.streams[id]--; s.streams[id] == 0 {
				delete(s.streams, id)
				s.stopped[id] = s.now()
				// The pass that can free it is the one after it settles;
				// waiting for the next tick instead left a watched episode
				// on disk for up to twice as long.
				time.AfterFunc(settle, s.Kick)
			}
		})
	}
}

// Opened records that a stream of a download has opened, which makes it the
// copy of its episode the viewer chose. Play is earlier than that: it holds
// the file before the lookup that may still fail.
func (s *Service) Opened(id string) {
	s.mu.Lock()
	_, known := s.played[id]
	s.played[id] = s.now()
	s.mu.Unlock()
	// Not on every range request: a player reconnects on each seek.
	if !known {
		s.Kick()
	}
}

// Start runs start with passes held off and counts what it started as just
// played: a player opens the stream only once the file is ready, and pressing
// Play on a watched episode to see it again must not free it in between.
func (s *Service) Start(start func() (acquire.Download, error)) (acquire.Download, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, err := start()
	if err == nil {
		s.stopped[d.ID] = s.now()
	}
	return d, err
}

// Clean drops the copies another copy of their episode replaced, then frees,
// oldest watched first, every finished download the keep policy has expired,
// then more of them while the downloads take more than the ceiling. A
// download nobody finished is never freed by the policy, so one larger than
// the ceiling stays until it is watched.
func (s *Service) Clean(ctx context.Context) error {
	s.dropReplaced(ctx)
	prefs, err := s.prefs.Get(ctx)
	if err != nil {
		return err
	}
	if !prefs.Seed {
		now := s.now()
		for _, row := range s.downloads.List(ctx) {
			if !row.Seeding {
				continue
			}
			s.mu.Lock()
			busy := s.busy(row.ID, now)
			if !busy {
				if err := s.downloads.StopSharing(ctx, row.ID); err != nil {
					s.log.Warn("stopping sharing failed", "download", row.ID, "err", err)
				} else {
					s.log.Info("stopped sharing a finished download", "download", row.ID, "name", row.Name)
				}
			}
			s.mu.Unlock()
		}
	}
	if prefs.Keep == "forever" && prefs.DiskLimit == 0 {
		return nil
	}
	rows := s.downloads.List(ctx)
	candidates, err := s.finished(ctx, rows)
	if err != nil {
		return err
	}
	own, used := Usage(rows, s.downloads.Dirs)

	now := s.now()
	for _, c := range candidates {
		expired := prefs.Keep == "watched" ||
			prefs.Keep == "days" && now.Sub(c.watched) >= time.Duration(prefs.KeepDays)*day
		over := prefs.DiskLimit > 0 && used > prefs.DiskLimit
		if !expired && !over {
			continue
		}
		freed, err := s.free(ctx, c.row, now)
		if err != nil {
			s.log.Warn("freeing a watched download failed", "download", c.row.ID, "err", err)
			continue
		}
		if freed {
			used -= own[c.row.ID]
			s.log.Info("freed a watched download", "download", c.row.ID, "name", c.row.Name, "expired", expired, "over", over)
		}
	}
	return nil
}

// dropReplaced frees the unfinished copies of an episode once another copy of
// it has played since: picking another copy is leaving this one, and half a
// download nobody plays again only takes disk. A finished copy stays, as does
// the user's own file. free leaves a copy until it has not played for a while,
// so switching back soon after finds it where it was; it is paused meanwhile,
// so it takes no bandwidth from the copy playing, and playing it resumes it.
func (s *Service) dropReplaced(ctx context.Context) {
	rows := s.downloads.List(ctx)
	chosen := make(map[episode]string)
	s.mu.Lock()
	known := make(map[string]bool, len(rows))
	for _, row := range rows {
		known[row.ID] = true
	}
	for id := range s.played {
		if !known[id] {
			delete(s.played, id)
		}
	}
	latest := make(map[episode]time.Time)
	for _, row := range rows {
		at, ok := s.played[row.ID]
		if ok && row.ItemID != "" && at.After(latest[episodeOf(row)]) {
			latest[episodeOf(row)] = at
			chosen[episodeOf(row)] = row.ID
		}
	}
	s.mu.Unlock()

	now := s.now()
	for _, row := range rows {
		id, ok := chosen[episodeOf(row)]
		if !ok || id == row.ID || row.State == acquire.StateDone || row.Locator.Scheme == "file" {
			continue
		}
		if row.State == acquire.StateActive {
			if _, err := s.downloads.SetPaused(ctx, row.ID, true); err != nil && !errors.Is(err, acquire.ErrNotFound) && !errors.Is(err, acquire.ErrNothingToFetch) {
				s.log.Warn("pausing a replaced copy failed", "download", row.ID, "err", err)
			}
		}
		freed, err := s.free(ctx, row, now)
		if err != nil {
			s.log.Warn("dropping a replaced copy failed", "download", row.ID, "err", err)
			continue
		}
		if freed {
			s.log.Info("dropped a replaced copy", "download", row.ID, "name", row.Name, "by", id)
		}
	}
}

// Fits says whether a prefetch of size bytes stays inside the free disk and
// the disk limit, after what unfinished downloads have still to fetch: a
// season half way through would otherwise leave room it is about to fill.
// Watched downloads count as room under the limit: over it, they are what
// goes. A size nobody knows never fits.
func (s *Service) Fits(ctx context.Context, size int64) (bool, error) {
	if size <= 0 {
		return false, nil
	}
	rows := s.downloads.List(ctx)
	own, used := Usage(rows, s.downloads.Dirs)
	for _, row := range rows {
		arriving := row.State == acquire.StateActive || row.State == acquire.StatePaused
		if arriving && row.Locator.Scheme != "file" && row.Size > own[row.ID] {
			size += row.Size - own[row.ID]
		}
	}
	disk, err := DiskUsage(s.downloads.Dir())
	if err != nil {
		return false, err
	}
	if uint64(size) > disk.Free {
		return false, nil
	}
	prefs, err := s.prefs.Get(ctx)
	if err != nil {
		return false, err
	}
	if prefs.DiskLimit == 0 {
		return true, nil
	}
	candidates, err := s.finished(ctx, rows)
	if err != nil {
		return false, err
	}
	for _, c := range candidates {
		used -= own[c.row.ID]
	}
	return used+size <= prefs.DiskLimit, nil
}

type candidate struct {
	row     acquire.Download
	watched time.Time
}

// finished is what of rows the policy may free, the longest watched first:
// downloads of an episode whose progress entry is the watched latch with no
// position. A watched entry with a position is a rewatch under way.
func (s *Service) finished(ctx context.Context, rows []acquire.Download) ([]candidate, error) {
	entries, err := s.progress.AllProgress(ctx)
	if err != nil {
		return nil, err
	}
	finished := make(map[episode]time.Time)
	for _, entry := range entries {
		if entry.Watched && entry.Position == 0 {
			finished[episode{entry.ItemID, entry.Season, entry.Episode}] = entry.UpdatedAt
		}
	}
	var candidates []candidate
	for _, row := range rows {
		if row.Locator.Scheme == "file" || row.ItemID == "" {
			continue
		}
		if at, ok := finished[episodeOf(row)]; ok {
			candidates = append(candidates, candidate{row, at})
		}
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].watched.Before(candidates[j].watched) })
	return candidates, nil
}

func (s *Service) free(ctx context.Context, row acquire.Download, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.busy(row.ID, now) {
		return false, nil
	}
	if err := s.downloads.Remove(ctx, row.ID, true); err != nil {
		if errors.Is(err, acquire.ErrNotFound) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// busy reports a stream that is open or still settling. The caller holds mu.
func (s *Service) busy(id string, now time.Time) bool {
	for id, at := range s.stopped {
		if now.Sub(at) >= settle {
			delete(s.stopped, id)
		}
	}
	if _, playing := s.streams[id]; playing {
		return true
	}
	if _, recent := s.stopped[id]; recent {
		return true
	}
	return false
}

// Usage is what the downloads take on disk. A download's own share is its
// file; used counts every directory they live in once, so the pieces a
// torrent keeps of neighbouring files, and what is left of a file deleted by
// hand, count until they are freed. What cannot be read counts as nothing.
func Usage(rows []acquire.Download, dirs func(acquire.Download) []string) (own map[string]int64, used int64) {
	own = make(map[string]int64, len(rows))
	seen := make(map[string]bool)
	for _, row := range rows {
		if row.Locator.Scheme == "file" {
			continue
		}
		if row.FilePath != "" {
			if bytes, err := Allocated(row.FilePath); err == nil {
				own[row.ID] = bytes
			}
		}
		for _, dir := range dirs(row) {
			if seen[dir] {
				continue
			}
			seen[dir] = true
			if bytes, err := Allocated(dir); err == nil {
				used += bytes
			}
		}
	}
	return own, used
}
