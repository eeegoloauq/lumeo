package store

import (
	"context"
	"io/fs"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
)

func TestOpenAppliesMigrationsIdempotently(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "catalog.db")
	db := openTestDB(t, path)

	// Derived, not hardcoded: every new migration file would otherwise fail
	// this test for no reason.
	want, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		t.Fatalf("read migrations: %v", err)
	}
	var version int
	if err := db.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatalf("read user_version: %v", err)
	}
	if version != len(want) {
		t.Fatalf("user_version = %d, want %d", version, len(want))
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close database: %v", err)
	}

	db = openTestDB(t, path)
	if err := db.Close(); err != nil {
		t.Fatalf("close reopened database: %v", err)
	}
}

func TestUpsertItemsKeepsStableIDAndSkipsUnidentifiedItems(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	items := []catalog.MediaItem{
		{Kind: catalog.KindMovie, Title: "First", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt1"}},
		{Kind: catalog.KindMovie, Title: "Duplicate", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt1"}},
		{Kind: catalog.KindMovie, Title: "No id"},
	}
	inserted, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, items, false)
	if err != nil {
		t.Fatalf("first upsert: %v", err)
	}
	if inserted[0].ID == "" || len(inserted[0].ID) != 16 {
		t.Fatalf("generated ID = %q, want 16 hex characters", inserted[0].ID)
	}
	if inserted[1].ID != inserted[0].ID {
		t.Fatalf("duplicate ID = %q, want %q", inserted[1].ID, inserted[0].ID)
	}
	if inserted[2].ID != "" {
		t.Fatalf("unidentified item ID = %q, want empty", inserted[2].ID)
	}

	again, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: catalog.KindMovie, Title: "Updated", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt1"},
	}}, false)
	if err != nil {
		t.Fatalf("second upsert: %v", err)
	}
	if again[0].ID != inserted[0].ID {
		t.Fatalf("second ID = %q, want %q", again[0].ID, inserted[0].ID)
	}

	var count int
	if err := db.db.QueryRow("SELECT count(*) FROM items").Scan(&count); err != nil {
		t.Fatalf("count items: %v", err)
	}
	if count != 1 {
		t.Fatalf("item count = %d, want 1", count)
	}
}

func TestUpsertItemsMergesMetadataAndKeepsDetailedData(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()
	released := time.Date(2020, time.January, 2, 0, 0, 0, 0, time.UTC)

	initial, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind:     catalog.KindSeries,
		Title:    "Detailed title",
		Overview: "Detailed overview",
		ExternalIDs: catalog.ExternalIDs{
			catalog.NamespaceIMDb: "tt-series",
			catalog.NamespaceTMDB: "100",
			catalog.NamespaceTVDB: "200",
		},
		Episodes: []catalog.Episode{{Season: 1, Number: 1, Title: "Pilot", Released: released}},
	}}, true)
	if err != nil {
		t.Fatalf("detailed upsert: %v", err)
	}

	if _, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind:        catalog.KindSeries,
		Title:       "Catalog title",
		ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt-series"},
	}}, false); err != nil {
		t.Fatalf("catalog upsert: %v", err)
	}

	item, state, err := db.Item(ctx, initial[0].ID)
	if err != nil {
		t.Fatalf("read item: %v", err)
	}
	if !state.Found || !state.Detailed {
		t.Fatalf("state = %+v, want found and detailed", state)
	}
	if item.Title != "Catalog title" || item.Overview != "Detailed overview" {
		t.Fatalf("merged text fields = title %q, overview %q", item.Title, item.Overview)
	}
	if len(item.Episodes) != 1 || item.Episodes[0].Title != "Pilot" {
		t.Fatalf("episodes = %+v, want detailed episodes preserved", item.Episodes)
	}
	if item.ExternalIDs[catalog.NamespaceTMDB] != "100" || item.ExternalIDs[catalog.NamespaceTVDB] != "200" {
		t.Fatalf("external IDs = %+v, want metadata IDs preserved", item.ExternalIDs)
	}
}

func TestUpsertItemsAddsExternalIDsFromMeta(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	inserted, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: catalog.KindMovie, Title: "Movie", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt-movie"},
	}}, false)
	if err != nil {
		t.Fatalf("catalog upsert: %v", err)
	}
	updated, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		ExternalIDs: catalog.ExternalIDs{
			catalog.NamespaceIMDb: "tt-movie",
			catalog.NamespaceTMDB: "300",
			catalog.NamespaceTVDB: "400",
		},
	}}, true)
	if err != nil {
		t.Fatalf("metadata upsert: %v", err)
	}
	if updated[0].ID != inserted[0].ID {
		t.Fatalf("metadata ID = %q, want %q", updated[0].ID, inserted[0].ID)
	}

	item, _, err := db.Item(ctx, inserted[0].ID)
	if err != nil {
		t.Fatalf("read item: %v", err)
	}
	if item.ExternalIDs[catalog.NamespaceTMDB] != "300" || item.ExternalIDs[catalog.NamespaceTVDB] != "400" {
		t.Fatalf("external IDs = %+v, want tmdb and tvdb", item.ExternalIDs)
	}
}

func TestItemsByIDsPreservesRequestedOrder(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	inserted, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{
		{Title: "One", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt-one"}},
		{Title: "Two", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt-two"}},
		{Title: "Three", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt-three"}},
	}, false)
	if err != nil {
		t.Fatalf("upsert items: %v", err)
	}

	items, err := db.ItemsByIDs(ctx, []string{inserted[2].ID, "missing", inserted[0].ID, inserted[2].ID})
	if err != nil {
		t.Fatalf("read items: %v", err)
	}
	want := []string{"Three", "One", "Three"}
	got := make([]string, len(items))
	for i := range items {
		got[i] = items[i].Title
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("titles = %v, want %v", got, want)
	}
}

func TestPageRoundTripIncludingEmptyKey(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	if ids, updatedAt, err := db.Page(ctx, "missing"); err != nil || ids != nil || !updatedAt.IsZero() {
		t.Fatalf("missing page = (%v, %v, %v), want nil, zero, nil", ids, updatedAt, err)
	}
	for key, want := range map[string][]string{
		"popular": {"one", "two"},
		"":        {},
	} {
		if err := db.SavePage(ctx, key, want); err != nil {
			t.Fatalf("save page %q: %v", key, err)
		}
		got, updatedAt, err := db.Page(ctx, key)
		if err != nil {
			t.Fatalf("read page %q: %v", key, err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("page %q = %v, want %v", key, got, want)
		}
		if updatedAt.IsZero() {
			t.Fatalf("page %q has zero update time", key)
		}
	}
}

func openTestDB(t *testing.T, path string) *DB {
	t.Helper()
	db, err := Open(path, "test")
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	return db
}

func TestCatalogUpsertLeavesDetailsStale(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()
	ids := catalog.ExternalIDs{catalog.NamespaceIMDb: "tt-series"}

	saved, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: catalog.KindSeries, Title: "Show", ExternalIDs: ids,
		Episodes: []catalog.Episode{{Season: 1, Number: 1}},
	}}, true)
	if err != nil {
		t.Fatalf("detailed upsert: %v", err)
	}
	fetched := time.Now().Add(-48 * time.Hour).Unix()
	if _, err := db.db.Exec("UPDATE items SET updated_at = ? WHERE id = ?", fetched, saved[0].ID); err != nil {
		t.Fatalf("age item: %v", err)
	}
	if _, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: catalog.KindSeries, Title: "Show", ExternalIDs: ids,
	}}, false); err != nil {
		t.Fatalf("catalog upsert: %v", err)
	}

	_, state, err := db.Item(ctx, saved[0].ID)
	if err != nil {
		t.Fatalf("read item: %v", err)
	}
	if state.UpdatedAt.Unix() != fetched {
		t.Fatalf("details fetched at %d look fetched at %d after a catalog row", fetched, state.UpdatedAt.Unix())
	}
}

func TestAnotherCoreVersionExpiresTheCatalog(t *testing.T) {
	path := filepath.Join(t.TempDir(), "catalog.db")
	ctx := context.Background()
	db, err := Open(path, "0.1.1")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	saved, err := db.UpsertItems(ctx, catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: catalog.KindSeries, Title: "Show", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt-series"},
	}}, true)
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if err := db.SavePage(ctx, "popular", []string{saved[0].ID}); err != nil {
		t.Fatalf("save page: %v", err)
	}
	db.Close()

	fresh := time.Now().Add(-time.Minute)
	for _, step := range []struct {
		version string
		fresh   bool
	}{{"0.1.1", true}, {"0.1.2", false}} {
		db, err := Open(path, step.version)
		if err != nil {
			t.Fatalf("reopen as %s: %v", step.version, err)
		}
		_, state, err := db.Item(ctx, saved[0].ID)
		if err != nil {
			t.Fatalf("read item: %v", err)
		}
		_, pageAt, err := db.Page(ctx, "popular")
		if err != nil {
			t.Fatalf("read page: %v", err)
		}
		db.Close()
		// Expired reads as the zero time: the catalog tells "another
		// version wrote this" from "this is old" by it.
		if step.fresh && (!state.UpdatedAt.After(fresh) || !pageAt.After(fresh)) ||
			!step.fresh && (!state.UpdatedAt.IsZero() || !pageAt.IsZero()) {
			t.Fatalf("as %s: item at %v, page at %v, want fresh %v", step.version, state.UpdatedAt, pageAt, step.fresh)
		}
	}
}
