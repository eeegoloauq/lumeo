package store

import (
	"context"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestSearchesLatestFirstOncePerWordAndBounded(t *testing.T) {
	db, err := Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0)
	for i, q := range []string{"fargo", "Дюна", "matrix", "ДЮНА", "Fargo"} {
		if err := db.RecordSearch(ctx, q, at.Add(time.Duration(i)*time.Second), 3); err != nil {
			t.Fatal(err)
		}
	}
	got, err := db.Searches(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// Searched again, a word moves up and takes the case it was typed in.
	if want := []string{"Fargo", "ДЮНА", "matrix"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("searches = %q, want %q", got, want)
	}

	if err := db.RecordSearch(ctx, "arrival", at.Add(time.Minute), 3); err != nil {
		t.Fatal(err)
	}
	if err := db.ForgetSearch(ctx, "дюна"); err != nil {
		t.Fatal(err)
	}
	got, _ = db.Searches(ctx)
	if want := []string{"arrival", "Fargo"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("after one more and a forget: %q, want %q", got, want)
	}

	if err := db.ClearSearches(ctx); err != nil {
		t.Fatal(err)
	}
	if got, _ = db.Searches(ctx); len(got) != 0 {
		t.Fatalf("after clear: %q", got)
	}
}
