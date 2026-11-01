package personal_test

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/personal"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

var at = time.Unix(1_790_000_000, 0).UTC()

type core struct {
	db       *store.DB
	prefs    *preferences.Service
	personal *personal.Service
}

func newCore(t *testing.T) core {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	prefs := preferences.New(db, preferences.Preferences{})
	return core{db: db, prefs: prefs, personal: personal.New(db, prefs)}
}

// title adds a title the way the catalogue does, with its details, and
// returns our id for it.
func (c core) title(t *testing.T, imdb string, kind catalog.Kind, name string) string {
	t.Helper()
	items, err := c.db.UpsertItems(context.Background(), catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: kind, Title: name, Year: 2008, Poster: "https://images.example/" + imdb + ".jpg",
		ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: imdb},
	}}, true)
	if err != nil {
		t.Fatal(err)
	}
	return items[0].ID
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// carry exports from one core and imports into another through the file's
// JSON, as a person moving the file between machines does.
func carry(t *testing.T, from, to core) personal.Counts {
	t.Helper()
	doc, err := from.personal.Export(context.Background())
	must(t, err)
	file, err := json.Marshal(doc)
	must(t, err)
	var read personal.Document
	must(t, json.Unmarshal(file, &read))
	counts, err := to.personal.Import(context.Background(), read)
	must(t, err)
	return counts
}

// seed gives a core a series watched part way, scored and on My list with
// tracks picked, a film watched, two searches and preferences of both kinds.
func seed(t *testing.T, c core) (series, film string) {
	t.Helper()
	ctx := context.Background()
	series = c.title(t, "tt0903747", catalog.KindSeries, "Breaking Bad")
	film = c.title(t, "tt0063350", catalog.KindMovie, "Night of the Living Dead")
	delay := 0.25
	for _, e := range []progress.Entry{
		{Season: 1, Episode: 1, Duration: 2900, Watched: true, UpdatedAt: at},
		{Season: 1, Episode: 2, Position: 600, Duration: 2900, UpdatedAt: at.Add(time.Hour), SubtitleDelay: &delay},
	} {
		_, err := c.db.UpsertProgress(ctx, series, e, nil)
		must(t, err)
	}
	_, err := c.db.UpsertProgress(ctx, film, progress.Entry{Duration: 5760, Watched: true, UpdatedAt: at}, nil)
	must(t, err)
	// A local file nothing matched has no title another core could find.
	_, err = c.db.UpsertProgress(ctx, "local:0123456789abcdef", progress.Entry{Position: 10, Duration: 100, UpdatedAt: at}, nil)
	must(t, err)
	must(t, c.db.SaveRating(ctx, series, ratings.Rating{Score: 9, RatedAt: at}))
	must(t, c.db.SaveRating(ctx, series, ratings.Rating{Season: 1, Episode: 1, Score: 8, RatedAt: at}))
	_, err = c.db.AddToList(ctx, series, at)
	must(t, err)
	must(t, c.db.SaveChoice(ctx, series, progress.Choice{
		Pack:     progress.Pack{BingeGroup: "pack-of-this-core", InfoHash: "abc"},
		Audio:    &progress.Track{Language: "ru", Title: "LostFilm"},
		Subtitle: &progress.Track{Off: true},
	}, at))
	must(t, c.db.RecordSearch(ctx, "breaking", at, 10))
	must(t, c.db.RecordSearch(ctx, "Night", at.Add(time.Minute), 10))
	_, err = c.prefs.Patch(ctx, []byte(`{"accent":"amber","subtitleLanguages":["ru","en"],"seekStep":10,"diskLimit":1000000,"keep":"forever"}`))
	must(t, err)
	return series, film
}

func TestCarriesTheViewersDataToAnotherCore(t *testing.T) {
	ctx := context.Background()
	from, to := newCore(t), newCore(t)
	seed(t, from)
	var notified preferences.Preferences
	to.prefs.Subscribe(func(p preferences.Preferences) { notified = p })

	counts := carry(t, from, to)
	want := personal.Counts{Titles: 2, Progress: 3, Ratings: 2, List: 1, Tracks: 1, Searches: 2, Preferences: 3}
	if counts != want {
		t.Fatalf("counts %+v, want %+v", counts, want)
	}

	series, found, err := to.db.ItemID(ctx, catalog.NamespaceIMDb, "tt0903747")
	must(t, err)
	if !found {
		t.Fatal("the series is not in the other core's catalogue")
	}
	item, state, err := to.db.Item(ctx, series)
	must(t, err)
	if item.Title != "Breaking Bad" || item.Kind != catalog.KindSeries || item.Poster == "" || state.Detailed {
		t.Fatalf("catalogue row %+v %+v, want the title's row without details", item, state)
	}

	entries, err := to.db.AllProgress(ctx)
	must(t, err)
	if len(entries) != 3 {
		t.Fatalf("progress %+v, want the three entries with a title", entries)
	}
	got, err := to.db.Progress(ctx, series)
	must(t, err)
	if len(got) != 2 || !got[0].Watched || got[1].Position != 600 || !got[1].UpdatedAt.Equal(at.Add(time.Hour)) ||
		*got[1].SubtitleDelay != 0.25 {
		t.Fatalf("series progress %+v", got)
	}

	scores, err := to.db.Ratings(ctx, []string{series})
	must(t, err)
	if len(scores[series]) != 2 || scores[series][0].Score != 9 || scores[series][1].Score != 8 {
		t.Fatalf("ratings %+v", scores[series])
	}
	entry, listed, err := to.db.ListEntry(ctx, series)
	must(t, err)
	if !listed || !entry.AddedAt.Equal(at) {
		t.Fatalf("list entry %+v %v", entry, listed)
	}

	choice, err := to.db.Choice(ctx, series)
	must(t, err)
	wantChoice := progress.Choice{
		Audio:    &progress.Track{Language: "ru", Title: "LostFilm"},
		Subtitle: &progress.Track{Off: true},
	}
	if !reflect.DeepEqual(choice, wantChoice) {
		t.Fatalf("choice %+v, want the tracks without the other core's copy", choice)
	}

	recent, err := to.db.Searches(ctx)
	must(t, err)
	if !reflect.DeepEqual(recent, []string{"Night", "breaking"}) {
		t.Fatalf("searches %q", recent)
	}

	prefs, err := to.prefs.Get(ctx)
	must(t, err)
	if prefs.Accent != "amber" || prefs.SeekStep != 10 || !reflect.DeepEqual(prefs.SubtitleLanguages, []string{"ru", "en"}) {
		t.Fatalf("personal preferences not carried: %+v", prefs)
	}
	if prefs.DiskLimit != 0 || prefs.Keep != "" {
		t.Fatalf("the machine's preferences were carried: %+v", prefs)
	}
	if notified.Accent != "amber" {
		t.Fatal("subscribers were not told about the imported preferences")
	}
}

func TestImportingTheSameFileTwiceChangesNothing(t *testing.T) {
	from, to := newCore(t), newCore(t)
	seed(t, from)
	carry(t, from, to)
	if counts := carry(t, from, to); counts != (personal.Counts{}) {
		t.Fatalf("second import changed %+v", counts)
	}
}

func TestImportKeepsTheLaterOfTwoEntries(t *testing.T) {
	ctx := context.Background()
	from, to := newCore(t), newCore(t)
	seed(t, from)
	series := to.title(t, "tt0903747", catalog.KindSeries, "Breaking Bad")
	// Watched further here after the file's entry; scored here before its
	// score; listed here later.
	_, err := to.db.UpsertProgress(ctx, series, progress.Entry{Season: 1, Episode: 2, Position: 1200, Duration: 2900, UpdatedAt: at.Add(2 * time.Hour)}, nil)
	must(t, err)
	must(t, to.db.SaveRating(ctx, series, ratings.Rating{Score: 5, RatedAt: at.Add(-time.Hour)}))
	_, err = to.db.AddToList(ctx, series, at.Add(time.Hour))
	must(t, err)

	counts := carry(t, from, to)
	if counts.Titles != 1 || counts.Progress != 2 || counts.Ratings != 2 || counts.List != 0 {
		t.Fatalf("counts %+v", counts)
	}
	got, err := to.db.Progress(ctx, series)
	must(t, err)
	if len(got) != 2 || got[1].Position != 1200 {
		t.Fatalf("progress %+v, want this core's later position kept", got)
	}
	scores, err := to.db.Ratings(ctx, []string{series})
	must(t, err)
	if scores[series][0].Score != 9 {
		t.Fatalf("ratings %+v, want the file's later score", scores[series])
	}
	entry, _, err := to.db.ListEntry(ctx, series)
	must(t, err)
	if !entry.AddedAt.Equal(at.Add(time.Hour)) {
		t.Fatalf("list entry %+v, want this core's date kept", entry)
	}
}

func TestOneBadEntryRefusesTheWholeFile(t *testing.T) {
	ctx := context.Background()
	good := personal.Title{IMDb: "tt0063350", Kind: catalog.KindMovie, Name: "Night of the Living Dead",
		Progress: []personal.Progress{{Duration: 5760, Watched: true, UpdatedAt: at}}}
	for name, doc := range map[string]personal.Document{
		"rating out of range": {Titles: []personal.Title{good, {IMDb: "tt0903747", Kind: catalog.KindSeries, Name: "Breaking Bad",
			Ratings: []personal.Rating{{Score: 11, RatedAt: at}}}}},
		"machine preference": {Titles: []personal.Title{good},
			Preferences: map[string]json.RawMessage{"downloadDir": json.RawMessage(`"/tmp"`)}},
		"bad preference value": {Titles: []personal.Title{good},
			Preferences: map[string]json.RawMessage{"accent": json.RawMessage(`"pink"`)}},
		"not an IMDb id":   {Titles: []personal.Title{good, {IMDb: "local:0123", Kind: catalog.KindMovie, Name: "x"}}},
		"title twice":      {Titles: []personal.Title{good, good}},
		"poster not web":   {Titles: []personal.Title{{IMDb: "tt1", Kind: catalog.KindMovie, Name: "x", Poster: "file:///etc/passwd"}}},
		"blank search":     {Titles: []personal.Title{good}, Searches: []personal.Search{{Query: "  ", SearchedAt: at}}},
		"newer version":    {Version: personal.Version + 1, Titles: []personal.Title{good}},
		"another format":   {Format: "trakt", Titles: []personal.Title{good}},
		"progress no time": {Titles: []personal.Title{{IMDb: "tt1", Kind: catalog.KindMovie, Name: "x", Progress: []personal.Progress{{Duration: 1}}}}},
	} {
		t.Run(name, func(t *testing.T) {
			to := newCore(t)
			if doc.Format == "" {
				doc.Format = personal.Format
			}
			if doc.Version == 0 {
				doc.Version = personal.Version
			}
			_, err := to.personal.Import(ctx, doc)
			if !errors.Is(err, personal.ErrInvalid) {
				t.Fatalf("import: %v, want ErrInvalid", err)
			}
			if _, found, _ := to.db.ItemID(ctx, catalog.NamespaceIMDb, good.IMDb); found {
				t.Fatal("the good title was written from a refused file")
			}
		})
	}
}

// A file a core wrote is one every core of its version takes, whatever odd
// rows its database holds.
func TestExportLeavesOutWhatAnImportWouldRefuse(t *testing.T) {
	ctx := context.Background()
	from, to := newCore(t), newCore(t)
	film, err := from.db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: catalog.KindMovie, Title: "x", Poster: "data:image/png;base64,AAAA",
		ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt0000001"},
	}}, true)
	must(t, err)
	_, err = from.db.AddToList(ctx, film[0].ID, at)
	must(t, err)
	must(t, from.db.SetPreferences(ctx, map[string]json.RawMessage{
		"accent": json.RawMessage(`"pink"`), "seekStep": json.RawMessage(`5`),
	}))

	counts := carry(t, from, to)
	if counts.Titles != 1 || counts.Preferences != 1 {
		t.Fatalf("counts %+v, want the title without its poster and seekStep alone", counts)
	}
}
