package store

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/progress"
)

func TestProgressUpsertLatchesWatchedAndDeletes(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "lumeo.db"))
	defer db.Close()
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0).UTC()

	entry, err := db.UpsertProgress(ctx, "series", progress.Entry{
		Season: 1, Episode: 2, Position: 90, Duration: 100, Watched: true, UpdatedAt: at,
	}, nil)
	if err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	if !entry.Watched {
		t.Fatal("90 percent progress was not stored as watched")
	}
	entry, err = db.UpsertProgress(ctx, "series", progress.Entry{
		Season: 1, Episode: 2, Position: 10, Duration: 100, UpdatedAt: at.Add(time.Second),
	}, nil)
	if err != nil {
		t.Fatalf("second upsert: %v", err)
	}
	if !entry.Watched || entry.Position != 10 {
		t.Fatalf("latched entry = %+v", entry)
	}

	reset := false
	entry, err = db.UpsertProgress(ctx, "series", progress.Entry{
		Season: 1, Episode: 2, Duration: 100, UpdatedAt: at.Add(2 * time.Second),
	}, &reset)
	if err != nil {
		t.Fatalf("reset: %v", err)
	}
	if entry.Watched || entry.Position != 0 {
		t.Fatalf("reset entry = %+v", entry)
	}

	season, episode := 1, 2
	if err := db.DeleteProgress(ctx, "series", &season, &episode); err != nil {
		t.Fatalf("delete entry: %v", err)
	}
	entries, err := db.Progress(ctx, "series")
	if err != nil {
		t.Fatalf("read after delete: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("entries after delete = %+v", entries)
	}
}

func TestProgressDeleteWholeItem(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "lumeo.db"))
	defer db.Close()
	ctx := context.Background()
	for episode := 1; episode <= 2; episode++ {
		if _, err := db.UpsertProgress(ctx, "series", progress.Entry{
			Season: 1, Episode: episode, UpdatedAt: time.Now(),
		}, nil); err != nil {
			t.Fatalf("upsert episode %d: %v", episode, err)
		}
	}
	if err := db.DeleteProgress(ctx, "series", nil, nil); err != nil {
		t.Fatalf("delete item: %v", err)
	}
	entries, err := db.Progress(ctx, "series")
	if err != nil || len(entries) != 0 {
		t.Fatalf("progress after delete = %+v, %v", entries, err)
	}
}
