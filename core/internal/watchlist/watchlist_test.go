package watchlist

import (
	"context"
	"sort"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
)

type memory struct {
	list     []Entry
	progress []progress.Entry
	items    map[string]catalog.MediaItem
	ratings  map[string][]ratings.Rating
}

func (m *memory) AddToList(_ context.Context, id string, at time.Time) (Entry, error) {
	for _, e := range m.list {
		if e.ItemID == id {
			return e, nil
		}
	}
	e := Entry{ItemID: id, AddedAt: at}
	m.list = append([]Entry{e}, m.list...)
	return e, nil
}
func (m *memory) RemoveFromList(context.Context, string) error { panic("not used") }
func (m *memory) ListEntry(context.Context, string) (Entry, bool, error) {
	panic("not used")
}
func (m *memory) ListEntries(context.Context) ([]Entry, error) { return m.list, nil }

func (m *memory) Known(_ context.Context, id string) (bool, error) {
	_, ok := m.items[id]
	return ok, nil
}
func (m *memory) Cached(_ context.Context, ids []string) ([]catalog.MediaItem, error) {
	var out []catalog.MediaItem
	for _, id := range ids {
		if item, ok := m.items[id]; ok {
			out = append(out, item)
		}
	}
	return out, nil
}
func (m *memory) AllProgress(context.Context) ([]progress.Entry, error) { return m.progress, nil }
func (m *memory) For(context.Context, []string) (map[string][]ratings.Rating, error) {
	return m.ratings, nil
}

var now = time.Date(2026, 9, 24, 18, 0, 0, 0, time.UTC)

func day(offset int) time.Time {
	return time.Date(2026, 9, 24, 0, 0, 0, 0, time.UTC).AddDate(0, 0, offset)
}

func service(m *memory) *Service {
	s := New(m, m, m, m)
	s.now = func() time.Time { return now }
	return s
}

func TestListCountsWhatIsOutAndWatched(t *testing.T) {
	m := &memory{
		items: map[string]catalog.MediaItem{
			"series": {ID: "series", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
				{Season: 0, Number: 1, Released: day(-400)}, // a special: counts for neither
				{Season: 1, Number: 1, Released: day(-30)},
				{Season: 1, Number: 2, Released: day(-23)},
				{Season: 1, Number: 3},                   // no date: out
				{Season: 1, Number: 4, Released: day(0)}, // out today
				{Season: 1, Number: 5, Released: day(7)}, // not out
			}},
			"film":  {ID: "film", Kind: catalog.KindMovie},
			"bare":  {ID: "bare", Kind: catalog.KindSeries},
			"other": {ID: "other", Kind: catalog.KindMovie},
		},
		list: []Entry{{ItemID: "series"}, {ItemID: "film"}, {ItemID: "bare"}, {ItemID: "gone"}},
		progress: []progress.Entry{
			{ItemID: "series", Season: 0, Episode: 1, Watched: true},
			{ItemID: "series", Season: 1, Episode: 1, Watched: true},
			{ItemID: "series", Season: 1, Episode: 2, Position: 100},
			{ItemID: "film", Watched: true},
			{ItemID: "other", Watched: true},
		},
		ratings: map[string][]ratings.Rating{"film": {{Score: 9}}, "series": {{Season: 1, Episode: 1, Score: 4}}},
	}
	got, err := service(m).List(context.Background())
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("list = %+v, want the three titles the catalogue knows", got)
	}
	if s := got[0].Seen; s != (Seen{Watched: 1, Released: 4}) || got[0].Rating != 0 || got[0].Item.Episodes != nil {
		t.Errorf("series = %+v", got[0])
	}
	if s := got[1].Seen; s != (Seen{Watched: 1, Released: 1}) || got[1].Rating != 9 {
		t.Errorf("film = %+v", got[1])
	}
	if s := got[2].Seen; s != (Seen{}) {
		t.Errorf("series with no episodes fetched = %+v, want nothing said", got[2])
	}
}

func TestAddRefusesWhatTheCatalogueDoesNotKnow(t *testing.T) {
	m := &memory{items: map[string]catalog.MediaItem{"film": {ID: "film"}}}
	s := service(m)
	if _, err := s.Add(context.Background(), "nobody"); err != ErrUnknown {
		t.Fatalf("add unknown: %v", err)
	}
	e, err := s.Add(context.Background(), "film")
	if err != nil || !e.AddedAt.Equal(now) {
		t.Fatalf("add = %+v, %v", e, err)
	}
}

func TestNewEpisodesOfFollowedSeries(t *testing.T) {
	m := &memory{
		items: map[string]catalog.MediaItem{
			// On the list, never watched: two new episodes, the latest shown.
			"listed": {ID: "listed", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
				{Season: 2, Number: 3, Released: day(-20)}, // too old
				{Season: 2, Number: 4, Released: day(-6)},
				{Season: 2, Number: 5, Released: day(0)}, // out today
				{Season: 2, Number: 6, Released: day(7)}, // not out
			}},
			// Being watched, not on the list: followed all the same. The new
			// episode already watched is not new.
			"watching": {ID: "watching", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
				{Season: 1, Number: 8, Released: day(-8)},
				{Season: 1, Number: 9, Released: day(-1)},
				{Season: 0, Number: 1, Released: day(-1)}, // a special
			}},
			// Caught up: nothing new.
			"caught": {ID: "caught", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
				{Season: 1, Number: 1, Released: day(-2)},
			}},
			// Not followed at all.
			"stranger": {ID: "stranger", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
				{Season: 1, Number: 1, Released: day(-1)},
			}},
			"film": {ID: "film", Kind: catalog.KindMovie},
		},
		list: []Entry{{ItemID: "listed"}, {ItemID: "film"}},
		progress: []progress.Entry{
			{ItemID: "watching", Season: 1, Episode: 8, Watched: true},
			{ItemID: "caught", Season: 1, Episode: 1, Watched: true},
		},
	}
	got, err := service(m).NewEpisodes(context.Background())
	if err != nil {
		t.Fatalf("new episodes: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("new episodes = %+v", got)
	}
	if got[0].Item.ID != "listed" || got[0].Episode.Number != 5 || got[0].Count != 2 || got[0].Item.Episodes != nil {
		t.Errorf("first = %+v, want the listed series at E5, two new", got[0])
	}
	if got[1].Item.ID != "watching" || got[1].Episode.Number != 9 || got[1].Count != 1 {
		t.Errorf("second = %+v, want the watched series at E9", got[1])
	}
}

func TestLaterBreaksSameDayReleasesByPlace(t *testing.T) {
	episodes := []catalog.Episode{
		{Season: 1, Number: 1, Released: day(-1)},
		{Season: 1, Number: 3, Released: day(-1)},
		{Season: 1, Number: 2, Released: day(-1)},
		{Season: 1, Number: 4, Released: day(0)},
	}
	sort.SliceStable(episodes, func(i, j int) bool { return later(episodes[i], episodes[j]) })
	for i, want := range []int{4, 3, 2, 1} {
		if episodes[i].Number != want {
			t.Fatalf("order = %+v", episodes)
		}
	}
}
