package progress

import (
	"context"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
)

type memoryStore struct{ entries []Entry }

func (m *memoryStore) UpsertProgress(context.Context, string, Entry, *bool) (Entry, error) {
	panic("not used")
}
func (m *memoryStore) Progress(context.Context, string) ([]Entry, error) {
	return append([]Entry(nil), m.entries...), nil
}
func (m *memoryStore) AllProgress(context.Context) ([]Entry, error) { return m.entries, nil }
func (m *memoryStore) History(context.Context, int, int) ([]Entry, error) {
	panic("not used")
}
func (m *memoryStore) DeleteProgress(context.Context, string, *int, *int) error {
	return nil
}

func (m *memoryStore) Choice(context.Context, string) (Choice, error) { return Choice{}, nil }
func (m *memoryStore) SaveChoice(context.Context, string, Choice, time.Time) error {
	return nil
}

type memoryCatalog struct{ item catalog.MediaItem }

func (m memoryCatalog) Item(context.Context, string) (catalog.MediaItem, error) { return m.item, nil }
func (m memoryCatalog) ItemsByIDs(context.Context, []string) ([]catalog.MediaItem, error) {
	return []catalog.MediaItem{m.item}, nil
}

func TestNextUsesMostRecentlyUpdatedEntryWhenUnwatched(t *testing.T) {
	old := time.Unix(10, 0).UTC()
	latest := time.Unix(20, 0).UTC()
	store := &memoryStore{entries: []Entry{
		{Season: 1, Episode: 1, Position: 10, UpdatedAt: old},
		{Season: 1, Episode: 2, Position: 20, UpdatedAt: latest},
	}}
	service := New(store, nil)
	_, got, err := service.Get(context.Background(), "series")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got == nil || got.Episode != 2 {
		t.Fatalf("next = %+v, want episode 2", got)
	}
}

func TestNextAfterMostRecentlyUpdatedWatchedEpisode(t *testing.T) {
	old := time.Unix(10, 0).UTC()
	latest := time.Unix(20, 0).UTC()
	episodes := []catalog.Episode{
		{Season: 1, Number: 4},
		{Season: 1, Number: 1},
		{Season: 1, Number: 3},
	}
	for _, test := range []struct {
		name    string
		entries []Entry
		want    *Entry
	}{
		{
			name: "stale partial does not override freshly watched episode",
			entries: []Entry{
				{ItemID: "series", Season: 1, Episode: 1, Position: 12, UpdatedAt: old},
				{ItemID: "series", Season: 1, Episode: 3, Watched: true, UpdatedAt: latest},
			},
			want: &Entry{ItemID: "series", Season: 1, Episode: 4, UpdatedAt: latest},
		},
		{
			name: "existing partial for following episode is preserved",
			entries: []Entry{
				{ItemID: "series", Season: 1, Episode: 4, Position: 37, Duration: 50, UpdatedAt: old},
				{ItemID: "series", Season: 1, Episode: 3, Watched: true, UpdatedAt: latest},
			},
			want: &Entry{ItemID: "series", Season: 1, Episode: 4, Position: 37, Duration: 50, UpdatedAt: old},
		},
		{
			name: "last catalogued episode has no successor",
			entries: []Entry{
				{ItemID: "series", Season: 1, Episode: 4, Watched: true, UpdatedAt: latest},
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			store := &memoryStore{entries: test.entries}
			cat := memoryCatalog{item: catalog.MediaItem{ID: "series", Kind: catalog.KindSeries, Episodes: episodes}}
			_, got, err := New(store, cat).Get(context.Background(), "series")
			if err != nil {
				t.Fatalf("get: %v", err)
			}
			if !entriesEqual(got, test.want) {
				t.Fatalf("next = %+v, want %+v", got, test.want)
			}
		})
	}
}

func TestNextIsNilForFinishedFilm(t *testing.T) {
	store := &memoryStore{entries: []Entry{{Season: 0, Episode: 0, Watched: true, UpdatedAt: time.Now()}}}
	_, got, err := New(store, memoryCatalog{item: catalog.MediaItem{Kind: catalog.KindMovie}}).Get(context.Background(), "movie")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got != nil {
		t.Fatalf("next = %+v, want nil", got)
	}
}

func entriesEqual(got, want *Entry) bool {
	if got == nil || want == nil {
		return got == want
	}
	return *got == *want
}

func TestNextEpisodeOrdersSeasonsAndStopsAtTheEnd(t *testing.T) {
	// Out of order, and with the specials a provider files as season 0 in the
	// middle of it, because that is how a provider sends them.
	series := &catalog.MediaItem{ID: "series", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
		{Season: 2, Number: 1},
		{Season: 0, Number: 1},
		{Season: 1, Number: 2},
		{Season: 1, Number: 1},
		{Season: 0, Number: 2},
		{Season: 2, Number: 2},
	}}
	at := func(season, number int) *[2]int { return &[2]int{season, number} }
	for _, test := range []struct {
		name            string
		item            *catalog.MediaItem
		season, episode int
		want            *[2]int // nil: there should be no next episode
	}{
		{name: "within a season", item: series, season: 1, episode: 1, want: at(1, 2)},
		{name: "across the season boundary", item: series, season: 1, episode: 2, want: at(2, 1)},
		// A finale is a finale: the extras filed as season 0 are not what
		// comes after it, and the series leaves "Continue watching" instead
		// of offering one.
		{name: "the finale is not followed by the specials", item: series, season: 2, episode: 2},
		// Between specials it does follow — whoever is watching those chose
		// them, and the title page lists them in this order.
		{name: "within the specials", item: series, season: 0, episode: 1, want: at(0, 2)},
		{name: "the last special ends the title", item: series, season: 0, episode: 2},
		{name: "an episode the catalogue does not have", item: series, season: 9, episode: 9},
		{name: "a film", item: &catalog.MediaItem{Kind: catalog.KindMovie}, season: 0, episode: 0},
		{name: "no catalogue at all", item: nil, season: 1, episode: 1},
		{
			name: "the finale of a series with no specials",
			item: &catalog.MediaItem{Kind: catalog.KindSeries, Episodes: []catalog.Episode{
				{Season: 1, Number: 1}, {Season: 1, Number: 2},
			}},
			season: 1, episode: 2,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := NextEpisode(test.item, test.season, test.episode, time.Now())
			if test.want == nil {
				if got != nil {
					t.Fatalf("next = %+v, want none", got)
				}
				return
			}
			if got == nil || got.Season != test.want[0] || got.Number != test.want[1] {
				t.Fatalf("next = %+v, want S%dE%d", got, test.want[0], test.want[1])
			}
		})
	}
}

func TestAfterDoesNotStepOverAnUnairedEpisode(t *testing.T) {
	now := time.Unix(1_000_000, 0).UTC()
	cat := memoryCatalog{item: catalog.MediaItem{ID: "series", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
		{Season: 1, Number: 1, Released: now.Add(-48 * time.Hour)},
		{Season: 1, Number: 2, Released: now.Add(48 * time.Hour)},
		{Season: 1, Number: 3, Released: now.Add(-24 * time.Hour)},
	}}}
	service := New(&memoryStore{}, cat)
	service.now = func() time.Time { return now }
	got, err := service.After(context.Background(), "series", 1, 1)
	if err != nil {
		t.Fatalf("after: %v", err)
	}
	if got != nil {
		t.Fatalf("next = %+v, want none while episode 2 is unaired", got)
	}
	// A date the provider never gave is not a claim that it is unaired.
	cat.item.Episodes[1].Released = time.Time{}
	service = New(&memoryStore{}, cat)
	service.now = func() time.Time { return now }
	got, err = service.After(context.Background(), "series", 1, 1)
	if err != nil {
		t.Fatalf("after: %v", err)
	}
	if got == nil || got.Number != 2 {
		t.Fatalf("next = %+v, want episode 2", got)
	}
}

func TestACaughtUpSeriesHasNoNextUntilTheEpisodeIsOut(t *testing.T) {
	now := time.Unix(1_000_000, 0).UTC()
	store := &memoryStore{entries: []Entry{
		{ItemID: "series", Season: 1, Episode: 1, Watched: true, UpdatedAt: now},
	}}
	cat := memoryCatalog{item: catalog.MediaItem{ID: "series", Kind: catalog.KindSeries, Episodes: []catalog.Episode{
		{Season: 1, Number: 1, Released: now.Add(-48 * time.Hour)},
		{Season: 1, Number: 2, Released: now.Add(48 * time.Hour)},
	}}}
	service := New(store, cat)
	service.now = func() time.Time { return now }

	_, next, err := service.Get(context.Background(), "series")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if next != nil {
		t.Fatalf("next = %+v, want none while episode 2 is unaired", next)
	}
	rows, err := service.Continue(context.Background(), 10)
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("continue = %+v, want the series gone until episode 2 is out", rows)
	}

	// Cinemeta dates are midnight UTC of the release day: from then on the
	// episode is next, whether or not a copy exists yet.
	service.now = func() time.Time { return now.Add(48 * time.Hour) }
	rows, err = service.Continue(context.Background(), 10)
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if len(rows) != 1 || rows[0].Next.Episode != 2 {
		t.Fatalf("continue = %+v, want S1E2 on its release day", rows)
	}
}
