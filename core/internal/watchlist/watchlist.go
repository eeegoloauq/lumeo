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
// are watched. A film is one episode. Played is whether anything of it was,
// to the end or part way, specials included: what My list's To watch leaves
// out.
type Seen struct {
	Watched  int  `json:"watched"`
	Released int  `json:"released"`
	Played   bool `json:"played"`
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
	watched, played, err := s.progressByTitle(ctx)
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
		seen.Played = played[e.ItemID]
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

// Finished is every title the viewer has seen all of, in no order: a film
// watched, a series caught up with by the rule of Seen. Any title counts,
// listed or not; one the catalogue has not kept is left out.
func (s *Service) Finished(ctx context.Context) ([]string, error) {
	watched, _, err := s.progressByTitle(ctx)
	if err != nil {
		return nil, err
	}
	ids := make([]string, 0, len(watched))
	for id := range watched {
		ids = append(ids, id)
	}
	items, err := s.catalog.Cached(ctx, ids)
	if err != nil {
		return nil, err
	}
	now := s.now()
	out := []string{}
	for _, item := range items {
		if seen := seenOf(item, watched[item.ID], now); seen.Released > 0 && seen.Watched == seen.Released {
			out = append(out, item.ID)
		}
	}
	return out, nil
}

// Shelved is a title on a library shelf: a series by one of its episodes,
// for New episodes the viewer's next, out in the last fortnight, and for
// Coming up the soonest not out yet; or on Coming up a film not out yet.
type Shelved struct {
	Item catalog.MediaItem `json:"item"`
	// Episode is a series' and left out for a film, which is dated by its
	// Item's Released.
	Episode catalog.Episode `json:"episode,omitzero"`
	// Count is, on New episodes, how many are out from Episode on, Episode
	// included.
	Count int `json:"count,omitempty"`
}

// NewEpisodes looks through the series the viewer follows for the ones they
// had caught up with until an episode came out, the latest release first.
// A series with older episodes still to watch is behind, not new: that is
// Continue watching's, and a whole season out while the viewer is in the
// one before is not news to them. It is our own query over the catalogue's
// air dates rather than a calendar from somewhere else, so it needs no
// account and no key.
func (s *Service) NewEpisodes(ctx context.Context) ([]Shelved, error) {
	items, furthest, err := s.followed(ctx)
	if err != nil {
		return nil, err
	}
	now := s.now()
	out := []Shelved{}
	for _, item := range items {
		if item.Kind != catalog.KindSeries {
			continue
		}
		var first *catalog.Episode
		count := 0
		for i := range item.Episodes {
			e := &item.Episodes[i]
			at := [2]int{e.Season, e.Number}
			// Specials are extras filed under season 0 with whatever date the
			// provider had, not the next part of the story.
			if e.Season == 0 || e.Released.IsZero() || e.Released.After(now) || !after(at, furthest[item.ID]) {
				continue
			}
			count++
			if first == nil || after([2]int{first.Season, first.Number}, at) {
				first = e
			}
		}
		if first == nil || now.Sub(first.Released) > recent {
			continue
		}
		episode := *first
		item.Episodes = nil
		out = append(out, Shelved{Item: item, Episode: episode, Count: count})
	}
	sort.SliceStable(out, func(i, j int) bool { return later(out[i].Episode, out[j].Episode) })
	return out, nil
}

// ComingUp is the calendar of what the viewer follows: the soonest dated
// episode not out yet of each series and the films not out yet, the soonest
// first. Unlike NewEpisodes it does not ask how far the viewer is: a season
// announced is worth knowing about while still in the one before.
func (s *Service) ComingUp(ctx context.Context) ([]Shelved, error) {
	items, _, err := s.followed(ctx)
	if err != nil {
		return nil, err
	}
	now := s.now()
	out := []Shelved{}
	for _, item := range items {
		if item.Kind == catalog.KindMovie && item.Released.After(now) {
			out = append(out, Shelved{Item: item})
			continue
		}
		if item.Kind != catalog.KindSeries {
			continue
		}
		var soonest *catalog.Episode
		for i := range item.Episodes {
			e := &item.Episodes[i]
			if e.Season == 0 || !e.Released.After(now) {
				continue
			}
			if soonest == nil || later(*soonest, *e) {
				soonest = e
			}
		}
		if soonest == nil {
			continue
		}
		episode := *soonest
		item.Episodes = nil
		out = append(out, Shelved{Item: item, Episode: episode})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if a, b := out[i].day(), out[j].day(); !a.Equal(b) {
			return a.Before(b)
		}
		return later(out[j].Episode, out[i].Episode)
	})
	return out, nil
}

// day is when the shelved title comes out: its episode, or the film.
func (s Shelved) day() time.Time {
	if s.Item.Kind == catalog.KindMovie {
		return s.Item.Released
	}
	return s.Episode.Released
}

// followed is every series and film the viewer follows, as the catalogue
// has it cached, with the last episode of the story watched of each.
//
// Following is having the title on the list or having watched any of it:
// the series somebody is in the middle of are exactly the ones whose next
// episode they are waiting for, and asking them to add each one to a list
// first would leave the shelves empty for everybody who never did.
func (s *Service) followed(ctx context.Context) ([]catalog.MediaItem, map[string][2]int, error) {
	entries, err := s.store.ListEntries(ctx)
	if err != nil {
		return nil, nil, err
	}
	all, err := s.progress.AllProgress(ctx)
	if err != nil {
		return nil, nil, err
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
	// furthest is the last episode of the story watched: one before it that
	// is not watched was skipped or seen elsewhere, not something to wait for.
	furthest := make(map[string][2]int)
	for _, p := range all {
		follow(p.ItemID)
		if at := [2]int{p.Season, p.Episode}; p.Watched && p.Season > 0 && after(at, furthest[p.ItemID]) {
			furthest[p.ItemID] = at
		}
	}
	items, err := s.catalog.Cached(ctx, ids)
	if err != nil {
		return nil, nil, err
	}
	return items, furthest, nil
}

// after says whether episode a comes after b in the story.
func after(a, b [2]int) bool {
	if a[0] != b[0] {
		return a[0] > b[0]
	}
	return a[1] > b[1]
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

// progressByTitle is every watched entry, by title, and which titles were
// played at all: watched, or left part way. One marked unwatched keeps an
// entry at 0, which is not playing it.
func (s *Service) progressByTitle(ctx context.Context) (watched map[string]map[[2]int]bool, played map[string]bool, err error) {
	all, err := s.progress.AllProgress(ctx)
	if err != nil {
		return nil, nil, err
	}
	watched = make(map[string]map[[2]int]bool)
	played = make(map[string]bool)
	for _, p := range all {
		if p.Watched || p.Position > 0 {
			played[p.ItemID] = true
		}
		if !p.Watched {
			continue
		}
		if watched[p.ItemID] == nil {
			watched[p.ItemID] = make(map[[2]int]bool)
		}
		watched[p.ItemID][[2]int{p.Season, p.Episode}] = true
	}
	return watched, played, nil
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
