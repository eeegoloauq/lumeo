// Package progress owns watch positions and decides what an item should play next.
package progress

import (
	"context"
	"errors"
	"math"
	"sort"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
)

type Entry struct {
	ItemID    string    `json:"-"`
	Season    int       `json:"season"`
	Episode   int       `json:"episode"`
	Position  float64   `json:"position"`
	Duration  float64   `json:"duration"`
	Watched   bool      `json:"watched"`
	UpdatedAt time.Time `json:"updatedAt"`
}

type Update struct {
	Season   int
	Episode  int
	Position float64
	Duration float64
	Watched  *bool
}

type Store interface {
	UpsertProgress(context.Context, string, Entry, *bool) (Entry, error)
	Progress(context.Context, string) ([]Entry, error)
	AllProgress(context.Context) ([]Entry, error)
	History(ctx context.Context, limit, offset int) ([]Entry, error)
	DeleteProgress(context.Context, string, *int, *int) error
	Choice(context.Context, string) (Choice, error)
	SaveChoice(context.Context, string, Choice, time.Time) error
}

// Choice is what the viewer settled on for a title. It is kept here rather
// than in a client because every client plays the same library: the copy
// picked on one machine is the one on disk for the next.
type Choice struct {
	// BingeGroup is the provider's name for the pack the copy came from.
	// Nearly every copy of an episode is a whole season, so the next episode
	// from the same pack is usually already on disk.
	BingeGroup string `json:"bingeGroup"`
	// Audio and Subtitle are the tracks last picked by hand, for the whole
	// title rather than the episode: a pick the next episode forgot would be
	// asked for again every evening. Nil when nobody picked.
	Audio    *Track `json:"audio"`
	Subtitle *Track `json:"subtitle"`
}

// Track names a track the way it carries over from one file to the next.
// mpv's ids are per file; a release keeps its languages and titles, and the
// title is what tells apart the tracks that share a language — "English
// Full", "English Honorifics", "Signs & Songs".
type Track struct {
	Language string `json:"language"`
	Title    string `json:"title"`
	// Off is a subtitle turned off by hand.
	Off bool `json:"off,omitempty"`
}

type Catalog interface {
	Item(context.Context, string) (catalog.MediaItem, error)
	ItemsByIDs(context.Context, []string) ([]catalog.MediaItem, error)
}

type Service struct {
	store   Store
	catalog Catalog
	now     func() time.Time

	// choiceMu makes each change to a choice a whole read and write: the
	// source is recorded by a download starting and the tracks by the
	// player, and the two can arrive together.
	choiceMu sync.Mutex
}

var ErrInvalid = errors.New("invalid progress")

type invalidError struct{ message string }

func (e invalidError) Error() string { return e.message }
func (e invalidError) Unwrap() error { return ErrInvalid }

func New(store Store, catalog Catalog) *Service {
	return &Service{store: store, catalog: catalog, now: time.Now}
}

func (s *Service) Put(ctx context.Context, itemID string, update Update) (Entry, error) {
	if itemID == "" {
		return Entry{}, invalidError{"itemId must not be empty"}
	}
	if update.Season < 0 || update.Episode < 0 {
		return Entry{}, invalidError{"season and episode must not be negative"}
	}
	if math.IsNaN(update.Position) || math.IsInf(update.Position, 0) || update.Position < 0 {
		return Entry{}, invalidError{"position must be a finite, non-negative number"}
	}
	if math.IsNaN(update.Duration) || math.IsInf(update.Duration, 0) || update.Duration < 0 {
		return Entry{}, invalidError{"duration must be a finite, non-negative number"}
	}
	if update.Duration > 0 && update.Position > update.Duration {
		return Entry{}, invalidError{"position must not be greater than duration"}
	}
	finished := update.Duration > 0 && update.Position/update.Duration >= 0.9
	if update.Watched != nil {
		finished = *update.Watched
	}
	// Finishing and starting over both leave no position: the watched mark
	// stays, and a position on a watched entry is a rewatch under way.
	if finished || update.Watched != nil {
		update.Position = 0
	}
	entry := Entry{
		ItemID:    itemID,
		Season:    update.Season,
		Episode:   update.Episode,
		Position:  update.Position,
		Duration:  update.Duration,
		Watched:   finished,
		UpdatedAt: s.now().UTC(),
	}
	return s.store.UpsertProgress(ctx, itemID, entry, update.Watched)
}

func (s *Service) Get(ctx context.Context, itemID string) ([]Entry, *Entry, error) {
	entries, err := s.store.Progress(ctx, itemID)
	if err != nil {
		return nil, nil, err
	}
	var item *catalog.MediaItem
	if s.catalog != nil {
		if found, err := s.catalog.Item(ctx, itemID); err == nil {
			item = &found
		}
	}
	return entries, next(entries, item, s.now()), nil
}

// After is what follows the episode the caller names, straight out of the
// catalogue. The player asks it in the middle of an episode, where [Get]'s own
// answer is no use: that one is counted from the last position reported, and
// an episode latches as watched at 90%, so by the credits it already names the
// episode after the one being asked about.
//
// Through the service rather than as a bare call to [NextEpisode] so that the
// clock is the service's — the release-date rule is otherwise untestable from
// the outside — and so that the catalogue is reached the one way it is reached
// everywhere else here.
func (s *Service) After(ctx context.Context, itemID string, season, episode int) (*catalog.Episode, error) {
	if s.catalog == nil {
		// Nothing to search. The route above refuses the request before this,
		// the same way it refuses one with no progress service behind it.
		return nil, nil
	}
	item, err := s.catalog.Item(ctx, itemID)
	if err != nil {
		return nil, err
	}
	return NextEpisode(&item, season, episode, s.now()), nil
}

func (s *Service) Choice(ctx context.Context, itemID string) (Choice, error) {
	return s.store.Choice(ctx, itemID)
}

// RememberSource records the pack of a copy that was started. An empty group
// is recorded too: the viewer's last pick was a copy outside any pack, and an
// older pack is no longer what they chose.
func (s *Service) RememberSource(ctx context.Context, itemID, bingeGroup string) error {
	if itemID == "" {
		return nil
	}
	return s.changeChoice(ctx, itemID, func(c *Choice) { c.BingeGroup = bingeGroup })
}

// RememberTracks records the tracks picked by hand. A nil track leaves the
// stored one as it was.
func (s *Service) RememberTracks(ctx context.Context, itemID string, audio, subtitle *Track) (Choice, error) {
	if itemID == "" {
		return Choice{}, invalidError{"itemId must not be empty"}
	}
	if audio != nil && audio.Off {
		return Choice{}, invalidError{"audio cannot be turned off"}
	}
	var saved Choice
	err := s.changeChoice(ctx, itemID, func(c *Choice) {
		if audio != nil {
			c.Audio = audio
		}
		if subtitle != nil {
			if subtitle.Off {
				subtitle = &Track{Off: true}
			}
			c.Subtitle = subtitle
		}
		saved = *c
	})
	return saved, err
}

func (s *Service) changeChoice(ctx context.Context, itemID string, change func(*Choice)) error {
	s.choiceMu.Lock()
	defer s.choiceMu.Unlock()
	choice, err := s.store.Choice(ctx, itemID)
	if err != nil {
		return err
	}
	change(&choice)
	return s.store.SaveChoice(ctx, itemID, choice, s.now().UTC())
}

func (s *Service) Delete(ctx context.Context, itemID string, season, episode *int) error {
	return s.store.DeleteProgress(ctx, itemID, season, episode)
}

type ContinueItem struct {
	Item      catalog.MediaItem `json:"item"`
	Next      Entry             `json:"next"`
	UpdatedAt time.Time         `json:"updatedAt"`
}

func (s *Service) Continue(ctx context.Context, limit int) ([]ContinueItem, error) {
	entries, err := s.store.AllProgress(ctx)
	if err != nil {
		return nil, err
	}
	if s.catalog == nil || len(entries) == 0 {
		return []ContinueItem{}, nil
	}
	grouped := make(map[string][]Entry)
	var ids []string
	for _, entry := range entries {
		if _, ok := grouped[entry.ItemID]; !ok {
			ids = append(ids, entry.ItemID)
		}
		grouped[entry.ItemID] = append(grouped[entry.ItemID], entry)
	}
	items, err := s.catalog.ItemsByIDs(ctx, ids)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]catalog.MediaItem, len(items))
	for _, item := range items {
		byID[item.ID] = item
	}
	result := make([]ContinueItem, 0, min(limit, len(items)))
	for _, id := range ids {
		item, ok := byID[id]
		if !ok {
			continue
		}
		n := next(grouped[id], &item, s.now())
		if n == nil {
			continue
		}
		latest := grouped[id][0].UpdatedAt
		for _, entry := range grouped[id][1:] {
			if entry.UpdatedAt.After(latest) {
				latest = entry.UpdatedAt
			}
		}
		item.Episodes = nil
		result = append(result, ContinueItem{Item: item, Next: *n, UpdatedAt: latest})
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].UpdatedAt.After(result[j].UpdatedAt) })
	if len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

// Viewing is one entry of the history: what was watched, of which title.
type Viewing struct {
	Item  catalog.MediaItem `json:"item"`
	Entry Entry             `json:"entry"`
	// Episode is the episode as the catalogue has it, for its name and
	// still; nil for a film, or an episode the catalogue no longer lists.
	Episode *catalog.Episode `json:"episode,omitempty"`
}

// History is what was watched, the latest first: every episode and film
// watched or stopped part way, a page at a time. More says whether there is
// another page. Positions kept for files the catalogue never matched are
// left out by the store; there is no title to name them by.
func (s *Service) History(ctx context.Context, limit, offset int) (viewings []Viewing, more bool, err error) {
	if limit < 1 || offset < 0 {
		return nil, false, invalidError{"limit must be positive and offset not negative"}
	}
	entries, err := s.store.History(ctx, limit+1, offset)
	if err != nil {
		return nil, false, err
	}
	if len(entries) > limit {
		entries, more = entries[:limit], true
	}
	viewings = []Viewing{}
	if s.catalog == nil || len(entries) == 0 {
		return viewings, more, nil
	}
	var ids []string
	seen := make(map[string]bool)
	for _, e := range entries {
		if !seen[e.ItemID] {
			seen[e.ItemID] = true
			ids = append(ids, e.ItemID)
		}
	}
	items, err := s.catalog.ItemsByIDs(ctx, ids)
	if err != nil {
		return nil, false, err
	}
	byID := make(map[string]catalog.MediaItem, len(items))
	for _, item := range items {
		byID[item.ID] = item
	}
	for _, e := range entries {
		item, ok := byID[e.ItemID]
		if !ok {
			continue
		}
		v := Viewing{Entry: e}
		if item.Kind == catalog.KindSeries {
			for _, episode := range item.Episodes {
				if episode.Season == e.Season && episode.Number == e.Episode {
					v.Episode = &episode
					break
				}
			}
		}
		item.Episodes = nil
		v.Item = item
		viewings = append(viewings, v)
	}
	return viewings, more, nil
}

// NextEpisode is the one search for "which episode follows this one", asked
// about an episode the caller names. Two questions want it: what to open when
// the last thing watched is finished, and what the player moves on to when the
// file it is playing runs out — and two searches would sooner or later
// disagree about where a season ends.
//
// The catalogue arrives in whatever order the provider wrote it, so it is
// sorted by (season, number) here; the answer is the episode immediately after
// the named one, across the season boundary as readily as within a season.
//
// An episode that has not aired by now is not next: nothing can play it, and
// offering it put a Play button on an empty source list. A caught-up series
// therefore leaves "Continue watching" and comes back on the release date.
// The date is Cinemeta's midnight UTC, not an air time, so an episode is next
// from the start of its release day, when an empty source list is normal. A
// missing date is not a claim that it is unaired — the client's
// Episode.isUpcoming reads it the same way.
func NextEpisode(item *catalog.MediaItem, season, episode int, now time.Time) *catalog.Episode {
	if item == nil || item.Kind != catalog.KindSeries {
		return nil
	}
	episodes := append([]catalog.Episode(nil), item.Episodes...)
	sort.SliceStable(episodes, func(i, j int) bool {
		a, b := episodes[i], episodes[j]
		if a.Season != b.Season {
			// Season 0 is where a provider files the specials, and it goes
			// last rather than before the pilot — which is where the title
			// page already puts it. Sorted the other way the core and the
			// page disagree about what follows the last special: the page
			// says "nothing after this", the player starts the pilot.
			if a.Season == 0 || b.Season == 0 {
				return b.Season == 0
			}
			return a.Season < b.Season
		}
		return a.Number < b.Number
	})
	index := make(map[[2]int]int, len(episodes))
	for i, e := range episodes {
		index[[2]int{e.Season, e.Number}] = i
	}
	i, ok := index[[2]int{season, episode}]
	if !ok || i+1 == len(episodes) {
		return nil
	}
	following := episodes[i+1]
	// A special is never what comes next after a story. Season 0 is where a
	// provider files the OVAs, the recaps and the behind-the-scenes, and none
	// of those continues anything: a series that has reached its finale is
	// finished, and it should leave "Continue watching" rather than hand over
	// an extra nobody asked for. The title page puts season 0 at the end for
	// the same reason — it is a shelf, not a continuation. Inside season 0 the
	// next special still follows, because whoever is watching those picked
	// them.
	if following.Season == 0 && season != 0 {
		return nil
	}
	if !following.Released.IsZero() && following.Released.After(now) {
		return nil
	}
	return &following
}

func next(entries []Entry, item *catalog.MediaItem, now time.Time) *Entry {
	var latest *Entry
	for i := range entries {
		entry := &entries[i]
		if latest == nil || entry.UpdatedAt.After(latest.UpdatedAt) {
			latest = entry
		}
	}
	if latest == nil {
		return nil
	}
	if !latest.Watched || latest.Position > 0 {
		copy := *latest
		return &copy
	}
	following := NextEpisode(item, latest.Season, latest.Episode, now)
	if following == nil {
		return nil
	}
	for i := range entries {
		entry := &entries[i]
		if entry.Season == following.Season && entry.Episode == following.Number {
			copy := *entry
			return &copy
		}
	}
	return &Entry{
		ItemID: latest.ItemID, Season: following.Season, Episode: following.Number,
		UpdatedAt: latest.UpdatedAt,
	}
}
