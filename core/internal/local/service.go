package local

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"unicode"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	acquirelocal "github.com/eeegoloauq/lumeo/core/internal/acquire/local"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

// ErrNotVideo is a path that does not name a video, by its name or by what
// it holds.
var ErrNotVideo = acquirelocal.ErrNotVideo

type Service struct {
	catalog   *catalog.Service
	downloads *acquire.Manager
	log       *slog.Logger

	// Identification runs behind Open, for as long as the service does.
	ctx     context.Context
	stop    context.CancelFunc
	running sync.WaitGroup
	mu      sync.Mutex
	pending map[string]bool // download ids being identified
}

func New(catalog *catalog.Service, downloads *acquire.Manager, log *slog.Logger) *Service {
	ctx, stop := context.WithCancel(context.Background())
	return &Service{catalog: catalog, downloads: downloads, log: log, ctx: ctx, stop: stop, pending: map[string]bool{}}
}

// Close stops identifying and waits until nothing is left writing to the
// downloads, so it goes before they close.
func (s *Service) Close() {
	s.mu.Lock()
	s.stop() // under mu: an identification is either counted or not started
	s.mu.Unlock()
	s.running.Wait()
}

func video(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".mkv", ".mp4", ".m4v", ".avi", ".webm", ".mov", ".wmv", ".flv", ".mpg", ".mpeg", ".ts", ".m2ts", ".ogv", ".3gp":
		return true
	}
	return false
}

func parsed(path string) release.Info {
	info := release.Parse(filepath.Base(path))
	for _, dir := range []string{filepath.Base(filepath.Dir(path)), filepath.Base(filepath.Dir(filepath.Dir(path)))} {
		parent := release.Parse(dir)
		if info.Season == 0 {
			info.Season = parent.Season
		}
		if info.Year == 0 {
			info.Year = parent.Year
		}
		if info.Title == "" && parent.Title != "" && !(parent.Season > 0 && seasonOnly(dir)) {
			info.Title = parent.Title
		}
	}
	return info
}

func seasonOnly(name string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	if strings.HasPrefix(lower, "season ") {
		return digits(strings.TrimSpace(lower[7:]))
	}
	if strings.HasPrefix(lower, "s") {
		return digits(lower[1:])
	}
	return false
}
func digits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}
func normalize(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Open makes the file a download and returns at once, so it plays while the
// catalogue is asked what it is: that is a search and, for an episode, a title
// or three, each as slow as the provider, and it was seconds of nothing on
// screen. Until the answer the download has no title and the player reports
// no progress for it; then it gets the catalogue's, or its own hash's.
func (s *Service) Open(ctx context.Context, path string) (acquire.Download, error) {
	if !filepath.IsAbs(path) || !video(path) {
		return acquire.Download{}, ErrNotVideo
	}
	path = filepath.Clean(path)
	file, err := acquirelocal.OpenVideo(path)
	if err != nil {
		return acquire.Download{}, err
	}
	stat, err := file.Stat()
	file.Close()
	if err != nil {
		return acquire.Download{}, err
	}
	row, found := acquire.Download{}, false
	for _, r := range s.downloads.List(ctx) {
		if r.FilePath == path {
			row, found = r, true
			break
		}
	}
	info := parsed(path)
	if !found {
		if row, err = s.start(ctx, path, stat.Size(), info, "", 0, 0); err != nil {
			return acquire.Download{}, err
		}
	}
	// Again for one opened before whose identification the core stopped in
	// the middle of.
	if row.ItemID == "" && row.Locator.Scheme == "file" {
		s.identifyLater(row.ID, path, stat.Size(), info)
	}
	return row, nil
}

func (s *Service) identifyLater(id, path string, size int64, info release.Info) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending[id] || s.ctx.Err() != nil {
		return
	}
	s.pending[id] = true
	s.running.Add(1)
	go func() {
		defer s.running.Done()
		defer func() {
			s.mu.Lock()
			delete(s.pending, id)
			s.mu.Unlock()
		}()
		s.name(s.ctx, id, path, size, info)
	}()
}

// name finds what the file is and gives the download that title, or the hash
// of its bytes when the catalogue does not know it, which is what subtitles
// are looked up by and what keeps its progress apart from other files'.
func (s *Service) name(ctx context.Context, id, path string, size int64, info release.Info) {
	itemID, season, episode := s.identify(ctx, info)
	if ctx.Err() != nil {
		return // stopped: the next Open tries again
	}
	if itemID == "" {
		season, episode = 0, 0
		itemID = s.hashID(path, size)
		if itemID == "" {
			return
		}
	}
	if err := s.downloads.Identify(ctx, id, itemID, season, episode); err != nil {
		s.log.Info("local identification not kept", "path", path, "err", err)
		return
	}
	if !strings.HasPrefix(itemID, "local:") && info.Episode > 0 {
		s.siblings(ctx, path, info, itemID)
	}
}

func (s *Service) hashID(path string, size int64) string {
	file, err := os.Open(path)
	if err != nil {
		s.log.Info("local hash failed", "path", path, "err", err)
		return ""
	}
	defer file.Close()
	hash, err := subtitles.Hash(file, size)
	if err != nil {
		if !errors.Is(err, subtitles.ErrTooSmall) {
			s.log.Info("local hash failed", "path", path, "err", err)
		}
		return ""
	}
	return "local:" + hash
}

func (s *Service) identify(ctx context.Context, info release.Info) (string, int, int) {
	if info.Title == "" {
		s.log.Info("local file has no title to identify")
		return "", 0, 0
	}
	if s.catalog == nil {
		return "", 0, 0
	}
	kind := catalog.KindMovie
	if info.Episode > 0 {
		kind = catalog.KindSeries
	}
	found, err := s.catalog.Search(ctx, kind, info.Title)
	if err != nil {
		s.log.Info("local identification failed", "title", info.Title, "err", err)
		return "", 0, 0
	}
	// A search answers with whatever it has: a ripper's "title_t00" came back
	// as Skibidi Toilet, then as Title Track. A match shares a word with the
	// name; a film with no year has nothing else to check it by, so it has to
	// be the name.
	var candidates []catalog.MediaItem
	for _, c := range found {
		if kind == catalog.KindMovie && info.Year == 0 {
			if normalize(c.Title) == normalize(info.Title) {
				candidates = append(candidates, c)
			}
		} else if sharesWord(c.Title, info.Title) {
			candidates = append(candidates, c)
		}
	}
	if info.Year > 0 {
		exact, near := []catalog.MediaItem{}, []catalog.MediaItem{}
		for _, c := range candidates {
			if c.Year == info.Year {
				exact = append(exact, c)
			} else if c.Year >= info.Year-1 && c.Year <= info.Year+1 {
				near = append(near, c)
			}
		}
		if len(exact) > 0 {
			candidates = exact
		} else {
			candidates = near
		}
	}
	if len(candidates) == 0 {
		s.log.Info("local file not identified", "title", info.Title)
		return "", 0, 0
	}
	// Several shows can share a word ("The Office"); the one named exactly
	// like the file goes first.
	sort.SliceStable(candidates, func(i, j int) bool {
		return normalize(candidates[i].Title) == normalize(info.Title) &&
			normalize(candidates[j].Title) != normalize(info.Title)
	})
	if kind == catalog.KindSeries {
		for i, c := range candidates {
			if i >= 3 {
				break
			}
			full, err := s.catalog.Item(ctx, c.ID)
			if err != nil {
				continue
			}
			if season, episode, ok := episodeIn(full.Episodes, info.Season, info.Episode); ok {
				return c.ID, season, episode
			}
		}
	}
	return candidates[0].ID, info.Season, info.Episode
}

// episodeIn finds the file's episode among the title's. Without a season the
// number counts through the regular seasons, the way fansubs number a show
// ("Frieren - 12" is S01E12).
func episodeIn(episodes []catalog.Episode, season, number int) (int, int, bool) {
	var regular []catalog.Episode
	for _, e := range episodes {
		if season > 0 && e.Season == season && e.Number == number {
			return season, number, true
		}
		if e.Season > 0 {
			regular = append(regular, e)
		}
	}
	if season > 0 || number < 1 || number > len(regular) {
		return 0, 0, false
	}
	sort.Slice(regular, func(i, j int) bool {
		if regular[i].Season != regular[j].Season {
			return regular[i].Season < regular[j].Season
		}
		return regular[i].Number < regular[j].Number
	})
	return regular[number-1].Season, regular[number-1].Number, true
}

func sharesWord(a, b string) bool {
	seen := make(map[string]bool)
	for _, w := range words(a) {
		seen[w] = true
	}
	for _, w := range words(b) {
		if seen[w] {
			return true
		}
	}
	return false
}

// words are the ones that can tell two titles apart: "the" and "of" cannot.
func words(s string) []string {
	var out []string
	for _, w := range strings.FieldsFunc(strings.ToLower(s), func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if len([]rune(w)) >= 3 && w != "the" && w != "and" {
			out = append(out, w)
		}
	}
	return out
}

func (s *Service) start(ctx context.Context, path string, size int64, info release.Info, itemID string, season, episode int) (acquire.Download, error) {
	name := filepath.Base(path)
	return s.downloads.OpenLocal(ctx, acquire.Request{ItemID: itemID, Season: season, Episode: episode, Source: sources.MediaSource{ProviderID: "local", RawName: name, Release: info, Size: size, Filename: name, Locator: sources.Locator{Scheme: "file", Path: path}}})
}

func (s *Service) siblings(ctx context.Context, path string, opened release.Info, itemID string) {
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		s.log.Info("local siblings unavailable", "path", path, "err", err)
		return
	}
	if len(entries) > 200 {
		entries = entries[:200]
	}
	title := normalize(opened.Title)
	var episodes []catalog.Episode
	if full, err := s.catalog.Item(ctx, itemID); err == nil {
		episodes = full.Episodes
	}
	for _, entry := range entries {
		if entry.IsDir() || entry.Name() == filepath.Base(path) || !video(entry.Name()) {
			continue
		}
		other := filepath.Join(filepath.Dir(path), entry.Name())
		info := parsed(other)
		if info.Episode == 0 || (info.Title != "" && normalize(info.Title) != title) {
			continue
		}
		stat, err := entry.Info()
		if err != nil || !stat.Mode().IsRegular() {
			continue
		}
		season, episode := info.Season, info.Episode
		if found, number, ok := episodeIn(episodes, season, episode); ok {
			season, episode = found, number
		}
		if _, err := s.start(ctx, other, stat.Size(), info, itemID, season, episode); err != nil {
			s.log.Info("local sibling registration failed", "path", other, "err", err)
		}
	}
}
