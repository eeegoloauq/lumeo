// Package library keeps what is on disk to the keep policy: it frees what the
// viewer finished once the policy says so, and nothing they have not.
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

// Clean frees, oldest watched first, every finished download the keep
// policy has expired, then more of them while the downloads take more than
// the ceiling. A download nobody finished is never freed here, so one larger
// than the ceiling stays until it is watched.
func (s *Service) Clean(ctx context.Context) error {
	prefs, err := s.prefs.Get(ctx)
	if err != nil {
		return err
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
	type episode struct {
		item            string
		season, episode int
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
		if at, ok := finished[episode{row.ItemID, row.Season, row.Episode}]; ok {
			candidates = append(candidates, candidate{row, at})
		}
	}
	sort.Slice(candidates, func(i, j int) bool { return candidates[i].watched.Before(candidates[j].watched) })
	return candidates, nil
}

func (s *Service) free(ctx context.Context, row acquire.Download, now time.Time) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, at := range s.stopped {
		if now.Sub(at) >= settle {
			delete(s.stopped, id)
		}
	}
	if _, playing := s.streams[row.ID]; playing {
		return false, nil
	}
	if _, recent := s.stopped[row.ID]; recent {
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
