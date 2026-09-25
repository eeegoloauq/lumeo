package store

import (
	"context"
	"encoding/json"
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
