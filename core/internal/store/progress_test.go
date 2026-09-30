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

// The delay a viewer set stays with the episode until they set another: the
// reports that do not carry one leave it.
func TestProgressKeepsTheSubtitleDelay(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "lumeo.db"))
	defer db.Close()
	ctx := context.Background()
	at := time.Unix(1_700_000_000, 0).UTC()
	put := func(delay *float64) progress.Entry {
		t.Helper()
		at = at.Add(time.Second)
		entry, err := db.UpsertProgress(ctx, "series", progress.Entry{
			Season: 1, Episode: 2, Position: 30, Duration: 100, UpdatedAt: at, SubtitleDelay: delay,
		}, nil)
		if err != nil {
			t.Fatalf("upsert: %v", err)
		}
		return entry
	}
	if e := put(nil); e.SubtitleDelay == nil || *e.SubtitleDelay != 0 {
		t.Fatalf("first = %+v", e.SubtitleDelay)
	}
	late := 1.5
	if e := put(&late); *e.SubtitleDelay != 1.5 {
		t.Fatalf("set = %v", *e.SubtitleDelay)
	}
	if e := put(nil); *e.SubtitleDelay != 1.5 {
		t.Fatalf("after a report without one = %v", *e.SubtitleDelay)
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
