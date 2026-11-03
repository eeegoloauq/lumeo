package store

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

func TestDownloadRoundTrip(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	fileIndex := 3
	cases := []acquire.Download{
		{
			ID:      "dl-nil-index",
			ItemID:  "item-movie",
			Name:    "Movie",
			Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc", Trackers: []string{"udp://tracker.example/announce"}},
			Dir:     "/data/Movie (1999)/dl", Folder: "Movie (1999)", FilePath: "/data/Movie (1999)/dl/movie.mkv", Size: 1234,
			State:     acquire.StateDone,
			Progress:  acquire.Progress{Completed: 100, Total: 200, Peers: 3, Seeders: 1, Rate: 9},
			CreatedAt: time.Unix(1_700_000_000, 0).UTC(),
			UpdatedAt: time.Unix(1_700_000_100, 0).UTC(),
		},
		{
			ID:     "dl-with-index",
			ItemID: "item-series",
			Season: 1, Episode: 5, Name: "Pilot",
			Locator: sources.Locator{
				Scheme: "torrent", InfoHash: "def", FileIndex: &fileIndex,
				Trackers: []string{"http://t1", "http://t2"},
			},
			State:     acquire.StateActive,
			CreatedAt: time.Unix(1_700_000_200, 0).UTC(),
			UpdatedAt: time.Unix(1_700_000_300, 0).UTC(),
		},
	}
	for _, want := range cases {
		if err := db.SaveDownload(ctx, want); err != nil {
			t.Fatalf("save download %q: %v", want.ID, err)
		}
		got, found, err := db.Download(ctx, want.ID)
		if err != nil {
			t.Fatalf("read download %q: %v", want.ID, err)
		}
		if !found {
			t.Fatalf("download %q not found", want.ID)
		}
		want.Progress = acquire.Progress{}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("download %q = %#v, want %#v", want.ID, got, want)
		}
	}
}

// A pause somebody asked for comes back after a restart, with how far the
// download had got; nothing else of the progress is kept.
func TestPausedDownloadKeepsItsProgress(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()
	for _, tt := range []struct {
		byUser bool
		want   acquire.Progress
	}{
		{byUser: true, want: acquire.Progress{Completed: 700, Total: 1000}},
		{byUser: false, want: acquire.Progress{}},
	} {
		row := acquire.Download{
			ID: "dl", Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"}, Size: 1000,
			State: acquire.StatePaused, PausedByUser: tt.byUser,
			Progress:  acquire.Progress{Completed: 700, Total: 1000, Peers: 4, Rate: 10},
			CreatedAt: time.Unix(1_700_000_000, 0).UTC(), UpdatedAt: time.Unix(1_700_000_000, 0).UTC(),
		}
		if err := db.SaveDownload(ctx, row); err != nil {
			t.Fatal(err)
		}
		got, _, err := db.Download(ctx, "dl")
		if err != nil {
			t.Fatal(err)
		}
		if got.PausedByUser != tt.byUser || got.Progress != tt.want {
			t.Fatalf("by user %v: read back paused %v, progress %+v, want %+v", tt.byUser, got.PausedByUser, got.Progress, tt.want)
		}
	}
}

func TestSaveDownloadUpsertsByID(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	original := acquire.Download{
		ID:        "same",
		Name:      "First",
		Locator:   sources.Locator{Scheme: "http", URL: "https://example/a"},
		FilePath:  "/tmp/a.mkv",
		State:     acquire.StateActive,
		CreatedAt: time.Unix(1_700_000_000, 0).UTC(),
		UpdatedAt: time.Unix(1_700_000_000, 0).UTC(),
	}
	if err := db.SaveDownload(ctx, original); err != nil {
		t.Fatalf("save original: %v", err)
	}

	updated := original
	updated.State = acquire.StateDone
	updated.FilePath = "/tmp/b.mkv"
	updated.UpdatedAt = time.Unix(1_700_000_050, 0).UTC()
	if err := db.SaveDownload(ctx, updated); err != nil {
		t.Fatalf("save update: %v", err)
	}

	var count int
	if err := db.db.QueryRow("SELECT count(*) FROM downloads").Scan(&count); err != nil {
		t.Fatalf("count downloads: %v", err)
	}
	if count != 1 {
		t.Fatalf("download count = %d, want 1", count)
	}

	got, found, err := db.Download(ctx, "same")
	if err != nil || !found {
		t.Fatalf("read updated = found %v, err %v", found, err)
	}
	if got.State != acquire.StateDone || got.FilePath != "/tmp/b.mkv" {
		t.Fatalf("updated fields = state %q path %q", got.State, got.FilePath)
	}
}

func TestDownloadsOrdersByCreatedAtDescending(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	for _, row := range []acquire.Download{
		{ID: "old", Name: "Old", Locator: sources.Locator{Scheme: "file", Path: "/old"}, State: acquire.StateDone, CreatedAt: time.Unix(100, 0).UTC(), UpdatedAt: time.Unix(100, 0).UTC()},
		{ID: "new", Name: "New", Locator: sources.Locator{Scheme: "file", Path: "/new"}, State: acquire.StateDone, CreatedAt: time.Unix(300, 0).UTC(), UpdatedAt: time.Unix(300, 0).UTC()},
		{ID: "mid", Name: "Mid", Locator: sources.Locator{Scheme: "file", Path: "/mid"}, State: acquire.StateDone, CreatedAt: time.Unix(200, 0).UTC(), UpdatedAt: time.Unix(200, 0).UTC()},
	} {
		if err := db.SaveDownload(ctx, row); err != nil {
			t.Fatalf("save %q: %v", row.ID, err)
		}
	}

	got, err := db.Downloads(ctx)
	if err != nil {
		t.Fatalf("list downloads: %v", err)
	}
	want := []string{"new", "mid", "old"}
	ids := make([]string, len(got))
	for i := range got {
		ids[i] = got[i].ID
	}
	if !reflect.DeepEqual(ids, want) {
		t.Fatalf("download ids = %v, want %v", ids, want)
	}
}

func TestDownloadMissingIsNotFound(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()

	got, found, err := db.Download(context.Background(), "missing")
	if err != nil || found || !reflect.DeepEqual(got, acquire.Download{}) {
		t.Fatalf("missing download = (%#v, %v, %v), want zero, false, nil", got, found, err)
	}
}

func TestDeleteDownloadMissingIsNotError(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	if err := db.DeleteDownload(ctx, "missing"); err != nil {
		t.Fatalf("delete missing: %v", err)
	}

	row := acquire.Download{
		ID: "keep-then-drop", Name: "Gone",
		Locator:   sources.Locator{Scheme: "file", Path: "/gone"},
		State:     acquire.StatePaused,
		CreatedAt: time.Unix(1, 0).UTC(), UpdatedAt: time.Unix(1, 0).UTC(),
	}
	if err := db.SaveDownload(ctx, row); err != nil {
		t.Fatalf("save: %v", err)
	}
	if err := db.DeleteDownload(ctx, row.ID); err != nil {
		t.Fatalf("delete existing: %v", err)
	}
	if _, found, err := db.Download(ctx, row.ID); err != nil || found {
		t.Fatalf("deleted download found=%v err=%v", found, err)
	}
}

func TestOpenAppliesDownloadsMigrationOnExistingV1Database(t *testing.T) {
	path := filepath.Join(t.TempDir(), "catalog.db")
	legacy, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)&_pragma=foreign_keys(on)")
	if err != nil {
		t.Fatalf("open legacy database: %v", err)
	}
	body, err := migrationFiles.ReadFile("migrations/0001_init.sql")
	if err != nil {
		t.Fatalf("read v1 migration: %v", err)
	}
	if _, err := legacy.Exec(string(body)); err != nil {
		t.Fatalf("apply v1 schema: %v", err)
	}
	if _, err := legacy.Exec("PRAGMA user_version = 1"); err != nil {
		t.Fatalf("set v1 user_version: %v", err)
	}
	if err := legacy.Close(); err != nil {
		t.Fatalf("close legacy database: %v", err)
	}

	db := openTestDB(t, path)
	defer db.Close()

	var version int
	if err := db.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	migrations, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		t.Fatalf("read migrations: %v", err)
	}
	if version != len(migrations) {
		t.Fatalf("user_version = %d, want %d", version, len(migrations))
	}

	ctx := context.Background()
	if err := db.SaveDownload(ctx, acquire.Download{
		ID: "after-upgrade", Name: "Upgraded",
		Locator:   sources.Locator{Scheme: "http", URL: "https://example/file"},
		State:     acquire.StatePaused,
		CreatedAt: time.Unix(10, 0).UTC(), UpdatedAt: time.Unix(10, 0).UTC(),
	}); err != nil {
		t.Fatalf("save after upgrade: %v", err)
	}
}

// Each device's hold comes back with the download, survives the download
// being saved again, and goes with it.
func TestHoldsRoundTrip(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()
	row := acquire.Download{
		ID: "dl", ItemID: "item", Season: 1, Episode: 2, Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"},
		State: acquire.StateDone, CreatedAt: time.Unix(1_700_000_000, 0).UTC(), UpdatedAt: time.Unix(1_700_000_000, 0).UTC(),
	}
	if err := db.SaveDownload(ctx, row); err != nil {
		t.Fatal(err)
	}
	holds := []acquire.Hold{
		{
			Device: "laptop", WatchedAt: time.Unix(1_700_000_500, 0).UTC(), SubtitleLanguages: []string{"ru", "en"},
			KeepWatchedDays: 2, KeepUnwatchedDays: 10, ActiveAt: time.Unix(1_700_000_100, 0).UTC(),
		},
		{
			Device: "tv", SubtitleLanguages: []string{}, KeepWatchedDays: 0, KeepUnwatchedDays: 7,
			ActiveAt: time.Unix(1_700_000_200, 0).UTC(), ReleasedAt: time.Unix(1_700_000_300, 0).UTC(),
		},
	}
	if err := db.SaveHolds(ctx, "dl", holds); err != nil {
		t.Fatal(err)
	}
	if err := db.SaveDownload(ctx, row); err != nil {
		t.Fatal(err)
	}
	got, _, err := db.Download(ctx, "dl")
	if err != nil || !reflect.DeepEqual(got.Holds, holds) {
		t.Fatalf("holds = %#v, %v; want %#v", got.Holds, err, holds)
	}
	all, err := db.Downloads(ctx)
	if err != nil || len(all) != 1 || !reflect.DeepEqual(all[0].Holds, holds) {
		t.Fatalf("listed holds = %#v, %v", all, err)
	}
	if err := db.DeleteDownload(ctx, "dl"); err != nil {
		t.Fatal(err)
	}
	var left int
	if err := db.db.QueryRow("SELECT count(*) FROM holds").Scan(&left); err != nil || left != 0 {
		t.Fatalf("holds left after the download: %d, %v", left, err)
	}
}

// A hold from before keep rules gets the default rules and starts its
// unwatched clock at the upgrade: counting it from zero would free every
// unwatched file a device holds on the first pass.
func TestHoldsFromBeforeKeepRulesStartTheirClocksAtTheUpgrade(t *testing.T) {
	path := filepath.Join(t.TempDir(), "catalog.db")
	old, err := sql.Open("sqlite", "file:"+path+"?_pragma=foreign_keys(on)")
	if err != nil {
		t.Fatal(err)
	}
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		t.Fatal(err)
	}
	applied := 0
	for _, entry := range entries {
		if entry.Name() >= "0022" {
			break
		}
		body, err := migrationFiles.ReadFile("migrations/" + entry.Name())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := old.Exec(string(body)); err != nil {
			t.Fatalf("%s: %v", entry.Name(), err)
		}
		applied++
	}
	for _, stmt := range []string{
		`INSERT INTO downloads(id, item_id, name, scheme, locator, dir, state, created_at, updated_at)
		 VALUES ('dl', 'item', 'Film', 'torrent', '{}', '', 'done', 0, 0)`,
		`INSERT INTO holds(download_id, device_id, watched_at, subtitle_languages) VALUES ('dl', 'tv', 0, '["en"]')`,
		fmt.Sprintf("PRAGMA user_version = %d", applied),
	} {
		if _, err := old.Exec(stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}

	before := time.Now().Add(-time.Second)
	db := openTestDB(t, path)
	defer db.Close()
	got, _, err := db.Download(context.Background(), "dl")
	if err != nil || len(got.Holds) != 1 {
		t.Fatalf("download = %+v, %v", got, err)
	}
	hold := got.Holds[0]
	if hold.KeepWatchedDays != acquire.DefaultKeepWatchedDays || hold.KeepUnwatchedDays != acquire.DefaultKeepUnwatchedDays ||
		hold.ActiveAt.Before(before) || !hold.ReleasedAt.IsZero() {
		t.Fatalf("hold = %+v; want the default rules, active since the upgrade, not released", hold)
	}
}
