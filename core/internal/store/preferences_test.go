package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"io/fs"
	"path/filepath"
	"reflect"
	"testing"
)

func TestPreferencesRoundTrip(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()
	want := map[string]json.RawMessage{
		"subtitleLanguages": json.RawMessage(`["ru","en"]`),
		"subtitleScale":     json.RawMessage(`1.5`),
	}

	if err := db.SetPreferences(ctx, want); err != nil {
		t.Fatalf("set preferences: %v", err)
	}
	got, err := db.Preferences(ctx)
	if err != nil {
		t.Fatalf("read preferences: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %v, want %v", got, want)
	}
}

func TestSetPreferencesOverwrites(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	if err := db.SetPreferences(ctx, map[string]json.RawMessage{"subtitleScale": json.RawMessage(`1.5`)}); err != nil {
		t.Fatalf("set initial preference: %v", err)
	}
	if err := db.SetPreferences(ctx, map[string]json.RawMessage{"subtitleScale": json.RawMessage(`2`)}); err != nil {
		t.Fatalf("overwrite preference: %v", err)
	}
	got, err := db.Preferences(ctx)
	if err != nil {
		t.Fatalf("read preferences: %v", err)
	}
	if string(got["subtitleScale"]) != "2" || len(got) != 1 {
		t.Fatalf("preferences = %v, want subtitleScale 2", got)
	}
}

func TestSetPreferencesNilDeletes(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	if err := db.SetPreferences(ctx, map[string]json.RawMessage{"subtitleScale": json.RawMessage(`1.5`)}); err != nil {
		t.Fatalf("set preference: %v", err)
	}
	if err := db.SetPreferences(ctx, map[string]json.RawMessage{"subtitleScale": nil}); err != nil {
		t.Fatalf("delete preference: %v", err)
	}
	got, err := db.Preferences(ctx)
	if err != nil {
		t.Fatalf("read preferences: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("preferences = %v, want empty", got)
	}
}

func TestSetPreferencesEmptyMapIsNoOp(t *testing.T) {
	db := openTestDB(t, filepath.Join(t.TempDir(), "catalog.db"))
	defer db.Close()
	ctx := context.Background()

	if err := db.SetPreferences(ctx, map[string]json.RawMessage{"subtitleScale": json.RawMessage(`1.5`)}); err != nil {
		t.Fatalf("set preference: %v", err)
	}
	if err := db.SetPreferences(ctx, map[string]json.RawMessage{}); err != nil {
		t.Fatalf("set empty preferences: %v", err)
	}
	got, err := db.Preferences(ctx)
	if err != nil {
		t.Fatalf("read preferences: %v", err)
	}
	if string(got["subtitleScale"]) != "1.5" || len(got) != 1 {
		t.Fatalf("preferences = %v, want unchanged subtitleScale", got)
	}
}

func TestMigrationRewritesThirtyDays(t *testing.T) {
	for _, stored := range []map[string]string{
		{"keep": `"30days"`},
		{"keep": `"30days"`, "keepDays": `7`},
	} {
		path := filepath.Join(t.TempDir(), "catalog.db")
		old, err := sql.Open("sqlite", "file:"+path)
		if err != nil {
			t.Fatal(err)
		}
		entries, err := fs.ReadDir(migrationFiles, "migrations")
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if entry.Name() >= "0016" {
				break
			}
			body, err := migrationFiles.ReadFile("migrations/" + entry.Name())
			if err != nil {
				t.Fatal(err)
			}
			if _, err := old.Exec(string(body)); err != nil {
				t.Fatalf("%s: %v", entry.Name(), err)
			}
		}
		for key, value := range stored {
			if _, err := old.Exec(`INSERT INTO preferences(key, value, updated_at) VALUES (?, ?, 0)`, key, value); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := old.Exec("PRAGMA user_version = 15"); err != nil {
			t.Fatal(err)
		}
		if err := old.Close(); err != nil {
			t.Fatal(err)
		}

		db := openTestDB(t, path)
		got, err := db.Preferences(context.Background())
		db.Close()
		if err != nil {
			t.Fatal(err)
		}
		if string(got["keep"]) != `"days"` || string(got["keepDays"]) != `30` {
			t.Fatalf("from %v: keep = %s, keepDays = %s; want \"days\" and 30", stored, got["keep"], got["keepDays"])
		}
	}
}
