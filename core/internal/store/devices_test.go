package store

import (
	"bytes"
	"context"
	"path/filepath"
	"testing"
	"time"
)

func TestDeviceCredentialsAreHashedAndSurviveRestart(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "core.db")
	db := openTestDB(t, path)
	credential := "a-device-credential-that-is-not-stored"
	if err := db.AddDevice(ctx, Device{ID: "one", Name: "Laptop", CreatedAt: time.Now()}, credential); err != nil {
		t.Fatal(err)
	}
	var hash []byte
	if err := db.db.QueryRow("SELECT token_hash FROM devices WHERE id = 'one'").Scan(&hash); err != nil {
		t.Fatal(err)
	}
	if len(hash) != 32 || bytes.Contains(hash, []byte(credential)) {
		t.Fatal("credential stored in plaintext")
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	db = openTestDB(t, path)
	defer db.Close()
	if id, found, err := db.DeviceByToken(ctx, credential); id != "one" || !found || err != nil {
		t.Fatalf("after restart: %q %v %v", id, found, err)
	}
	if _, found, err := db.DeviceByToken(ctx, "wrong"); found || err != nil {
		t.Fatalf("wrong credential: %v %v", found, err)
	}
}
