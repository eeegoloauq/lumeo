package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
)

func TestListKeepsTheFirstDateAndOrdersLatestFirst(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "lumeo.db"))
	defer db.Close()
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0).UTC()

	for i, id := range []string{"a", "b", "c"} {
		if _, err := db.AddToList(ctx, id, at.Add(time.Duration(i)*time.Hour)); err != nil {
			t.Fatalf("add %s: %v", id, err)
		}
	}
	// Added again later: the date it was first added stays, and so does its
	// place in the list.
	entry, err := db.AddToList(ctx, "a", at.Add(10*time.Hour))
	if err != nil || !entry.AddedAt.Equal(at) {
		t.Fatalf("re-add = %+v, %v; want the first date", entry, err)
	}
	// Two in one second keep the order they were added in.
	if _, err := db.AddToList(ctx, "d", at.Add(2*time.Hour)); err != nil {
		t.Fatalf("add d: %v", err)
	}
	if err := db.RemoveFromList(ctx, "b"); err != nil {
		t.Fatalf("remove: %v", err)
	}
	entries, err := db.ListEntries(ctx)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var got []string
	for _, e := range entries {
		got = append(got, e.ItemID)
	}
	if want := []string{"d", "c", "a"}; len(got) != len(want) || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("list = %v, want %v", got, want)
	}
	if _, ok, err := db.ListEntry(ctx, "b"); ok || err != nil {
		t.Fatalf("removed entry still there: %v, %v", ok, err)
	}
	if e, ok, err := db.ListEntry(ctx, "c"); !ok || err != nil || !e.AddedAt.Equal(at.Add(2*time.Hour)) {
		t.Fatalf("entry c = %+v, %v, %v", e, ok, err)
	}
}

func TestRatingsReplaceAndDelete(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "lumeo.db"))
	defer db.Close()
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0).UTC()

	for _, r := range []struct {
		id string
		ratings.Rating
	}{
		{"series", ratings.Rating{Score: 7, RatedAt: at}},
		{"series", ratings.Rating{Season: 1, Episode: 2, Score: 9, RatedAt: at}},
		{"series", ratings.Rating{Score: 8, RatedAt: at.Add(time.Minute)}},
		{"film", ratings.Rating{Score: 10, RatedAt: at}},
		{"other", ratings.Rating{Score: 3, RatedAt: at}},
	} {
		if err := db.SaveRating(ctx, r.id, r.Rating); err != nil {
			t.Fatalf("save: %v", err)
		}
	}
	got, err := db.Ratings(ctx, []string{"series", "film", "nothing"})
	if err != nil {
		t.Fatalf("ratings: %v", err)
	}
	if len(got) != 2 || len(got["series"]) != 2 || got["series"][0].Score != 8 || !got["series"][0].RatedAt.Equal(at.Add(time.Minute)) ||
		got["series"][1].Episode != 2 || got["film"][0].Score != 10 {
		t.Fatalf("ratings = %+v", got)
	}
	if err := db.DeleteRating(ctx, "series", 0, 0); err != nil {
		t.Fatalf("delete: %v", err)
	}
	got, _ = db.Ratings(ctx, []string{"series"})
	if len(got["series"]) != 1 || got["series"][0].Episode != 2 {
		t.Fatalf("after delete = %+v", got)
	}
	// The table refuses a score outside the scale, whoever writes it.
	if err := db.SaveRating(ctx, "series", ratings.Rating{Score: 11, RatedAt: at}); err == nil {
		t.Fatal("a rating of 11 was stored")
	}
}

func TestHistoryIsWhatWasWatchedLatestFirst(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "lumeo.db"))
	defer db.Close()
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0).UTC()
	for _, id := range []string{"film", "series", "other"} {
		if _, err := db.db.Exec("INSERT INTO items(id, kind, title, payload, updated_at) VALUES (?, 'movie', ?, '{}', 0)", id, id); err != nil {
			t.Fatalf("insert item: %v", err)
		}
	}
	unwatched := false
	for i, e := range []struct {
		id      string
		entry   progress.Entry
		watched *bool
	}{
		{"film", progress.Entry{Position: 600, Duration: 6000}, nil},
		{"series", progress.Entry{Season: 1, Episode: 1, Duration: 1500, Watched: true}, nil},
		{"series", progress.Entry{Season: 1, Episode: 2, Position: 300, Duration: 1500}, nil},
		// Marked unwatched: at the start and not watched, which nobody watched.
		{"other", progress.Entry{Duration: 6000}, &unwatched},
		// A local file nothing matched: no title to list it by.
		{"local:abc", progress.Entry{Position: 60, Duration: 6000}, nil},
	} {
		e.entry.UpdatedAt = at.Add(time.Duration(i) * time.Minute)
		if _, err := db.UpsertProgress(ctx, e.id, e.entry, e.watched); err != nil {
			t.Fatalf("upsert: %v", err)
		}
	}
	page, err := db.History(ctx, 2, 0)
	if err != nil {
		t.Fatalf("history: %v", err)
	}
	if len(page) != 2 || page[0].Episode != 2 || page[1].Episode != 1 {
		t.Fatalf("first page = %+v", page)
	}
	page, err = db.History(ctx, 2, 2)
	if err != nil || len(page) != 1 || page[0].ItemID != "film" {
		t.Fatalf("second page = %+v, %v", page, err)
	}
}
