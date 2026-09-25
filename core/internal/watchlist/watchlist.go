// Package watchlist is My list: the titles the viewer keeps to watch, how far
// they are into each, and what is new in the series they follow.
package watchlist

import (
	"context"
	"errors"
	"sort"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
)

// Entry is one title on the list.
type Entry struct {
	ItemID  string    `json:"-"`
	AddedAt time.Time `json:"addedAt"`
}

type Store interface {
	// AddToList keeps the date a title was first added: adding it again is
	// not news, and "recently added" would otherwise reshuffle on every click.
	AddToList(ctx context.Context, itemID string, at time.Time) (Entry, error)
	RemoveFromList(ctx context.Context, itemID string) error
	ListEntry(ctx context.Context, itemID string) (Entry, bool, error)
	// ListEntries returns the list, the latest added first.
	ListEntries(ctx context.Context) ([]Entry, error)
}

type Catalog interface {
	Known(ctx context.Context, id string) (bool, error)
	// Cached answers from the cache without waiting on a provider, and
	// refreshes what is stale behind the answer.
	Cached(ctx context.Context, ids []string) ([]catalog.MediaItem, error)
}

type Progress interface {
	AllProgress(ctx context.Context) ([]progress.Entry, error)
}

type Ratings interface {
	For(ctx context.Context, itemIDs []string) (map[string][]ratings.Rating, error)
}

var ErrUnknown = errors.New("unknown title")

// recent is how long an episode counts as new: the fortnight the episode
// cards already print a date for, and long enough for a series watched at
// the weekend.
const recent = 14 * 24 * time.Hour

type Service struct {
	store    Store
	catalog  Catalog
	progress Progress
	ratings  Ratings
	now      func() time.Time
}

func New(store Store, catalog Catalog, progress Progress, ratings Ratings) *Service {
	return &Service{store: store, catalog: catalog, progress: progress, ratings: ratings, now: time.Now}
}

func (s *Service) Add(ctx context.Context, itemID string) (Entry, error) {
	known, err := s.catalog.Known(ctx, itemID)
	if err != nil {
		return Entry{}, err
	}
	if !known {
		return Entry{}, ErrUnknown
	}
	return s.store.AddToList(ctx, itemID, s.now().UTC().Truncate(time.Second))
}

func (s *Service) Remove(ctx context.Context, itemID string) error {
	return s.store.RemoveFromList(ctx, itemID)
}

// Has reports whether a title is on the list, and since when.
func (s *Service) Has(ctx context.Context, itemID string) (Entry, bool, error) {
	return s.store.ListEntry(ctx, itemID)
}

// Seen is how far the viewer is into a title: of the episodes out, how many
// are watched. A film is one episode.
type Seen struct {
	Watched  int `json:"watched"`
	Released int `json:"released"`
}

// Listed is one title on the list, with what a tile says about it.
type Listed struct {
	Item    catalog.MediaItem `json:"item"`
	AddedAt time.Time         `json:"addedAt"`
	// Rating is the viewer's score of the title itself, 0 when there is none.
	Rating int  `json:"rating,omitempty"`
	Seen   Seen `json:"seen"`
}

// List returns the list, the latest added first, each title without its
// episodes: a tile needs the counts, not forty episodes of every series.
func (s *Service) List(ctx context.Context) ([]Listed, error) {
	entries, err := s.store.ListEntries(ctx)
	if err != nil {
		return nil, err
	}
	ids := make([]string, len(entries))
	for i, e := range entries {
		ids[i] = e.ItemID
	}
	items, err := s.catalog.Cached(ctx, ids)
	if err != nil {
		return nil, err
	}
	byID := make(map[string]catalog.MediaItem, len(items))
	for _, item := range items {
		byID[item.ID] = item
	}
	watched, err := s.watched(ctx)
	if err != nil {
		return nil, err
	}
	scores, err := s.ratings.For(ctx, ids)
	if err != nil {
		return nil, err
	}
	now := s.now()
	out := make([]Listed, 0, len(entries))
	for _, e := range entries {
		item, ok := byID[e.ItemID]
		if !ok {
			continue
		}
		seen := seenOf(item, watched[e.ItemID], now)
		item.Episodes = nil
		out = append(out, Listed{
			Item:    item,
			AddedAt: e.AddedAt,
			Rating:  ratings.Score(scores[e.ItemID], 0, 0),
			Seen:    seen,
		})
	}
	return out, nil
}

// NewEpisode is a series with episodes out in the last fortnight that the
// viewer has not watched.
type NewEpisode struct {
	Item catalog.MediaItem `json:"item"`
	// Episode is the latest of them.
	Episode catalog.Episode `json:"episode"`
	// Count is how many there are, Episode included.
	Count int `json:"count"`
}

// NewEpisodes looks through the series the viewer follows for episodes that
// came out recently and are not watched, the latest release first.
//
// Following is having the series on the list or having watched any of it:
// the series somebody is in the middle of are exactly the ones whose next
// episode they are waiting for, and asking them to add each one to a list
// first would leave the shelf empty for everybody who never did. It is our
// own query over the catalogue's air dates rather than a calendar from
// somewhere else, so it needs no account and no key.
func (s *Service) NewEpisodes(ctx context.Context) ([]NewEpisode, error) {
	entries, err := s.store.ListEntries(ctx)
	if err != nil {
		return nil, err
	}
	all, err := s.progress.AllProgress(ctx)
	if err != nil {
		return nil, err
	}
	var ids []string
	seen := make(map[string]bool)
	follow := func(id string) {
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	for _, e := range entries {
		follow(e.ItemID)
	}
	watched := make(map[string]map[[2]int]bool)
	for _, p := range all {
		follow(p.ItemID)
		if p.Watched {
			if watched[p.ItemID] == nil {
				watched[p.ItemID] = make(map[[2]int]bool)
			}
			watched[p.ItemID][[2]int{p.Season, p.Episode}] = true
		}
	}
	items, err := s.catalog.Cached(ctx, ids)
	if err != nil {
		return nil, err
	}
	now := s.now()
	out := []NewEpisode{}
	for _, item := range items {
		if item.Kind != catalog.KindSeries {
			continue
		}
		var latest *catalog.Episode
		count := 0
		for i := range item.Episodes {
			e := &item.Episodes[i]
			// Specials are extras filed under season 0 with whatever date the
			// provider had, not the next part of the story.
			if e.Season == 0 || e.Released.IsZero() || e.Released.After(now) || now.Sub(e.Released) > recent {
				continue
			}
			if watched[item.ID][[2]int{e.Season, e.Number}] {
				continue
			}
			count++
			if latest == nil || later(*e, *latest) {
				latest = e
			}
		}
		if latest == nil {
			continue
		}
		episode := *latest
		item.Episodes = nil
		out = append(out, NewEpisode{Item: item, Episode: episode, Count: count})
	}
	sort.SliceStable(out, func(i, j int) bool { return later(out[i].Episode, out[j].Episode) })
	return out, nil
}

// later orders episodes by release, then by place in the series: two
// episodes of one season often come out on the same day.
func later(a, b catalog.Episode) bool {
	if !a.Released.Equal(b.Released) {
		return a.Released.After(b.Released)
	}
	if a.Season != b.Season {
		return a.Season > b.Season
	}
	return a.Number > b.Number
}

// watched is every watched entry, by title.
func (s *Service) watched(ctx context.Context) (map[string]map[[2]int]bool, error) {
	all, err := s.progress.AllProgress(ctx)
	if err != nil {
		return nil, err
	}
	out := make(map[string]map[[2]int]bool)
	for _, p := range all {
		if !p.Watched {
			continue
		}
		if out[p.ItemID] == nil {
			out[p.ItemID] = make(map[[2]int]bool)
		}
		out[p.ItemID][[2]int{p.Season, p.Episode}] = true
	}
	return out, nil
}

// seenOf counts the episodes out and the watched ones among them. Specials
// are left out of both: "3 of 10" means the story, and a series finished
// without its OVAs is finished. An episode with no date counts as out, the
// way NextEpisode reads it. A series whose episodes were never fetched says
// nothing rather than "0 of 0".
func seenOf(item catalog.MediaItem, watched map[[2]int]bool, now time.Time) Seen {
	if item.Kind != catalog.KindSeries {
		seen := Seen{Released: 1}
		if watched[[2]int{0, 0}] {
			seen.Watched = 1
		}
		return seen
	}
	var seen Seen
	for _, e := range item.Episodes {
		if e.Season == 0 || (!e.Released.IsZero() && e.Released.After(now)) {
			continue
		}
		seen.Released++
		if watched[[2]int{e.Season, e.Number}] {
			seen.Watched++
		}
	}
	return seen
}
