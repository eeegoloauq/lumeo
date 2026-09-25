package token

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestLoadCreatesOnceAndKeepsIt(t *testing.T) {
	dir := t.TempDir()
	first, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !valid(first) {
		t.Fatalf("token %q", first)
	}
	again, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if again != first {
		t.Fatal("a second load made a new token")
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("left %d files behind, want the token alone", len(entries))
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(filepath.Join(dir, FileName))
		if err != nil {
			t.Fatal(err)
		}
		if mode := info.Mode().Perm(); mode != 0o600 {
			t.Fatalf("mode %o, want 600", mode)
		}
	}
}

func TestLoadReplacesABrokenFile(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, FileName), []byte("short\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	token, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !valid(token) {
		t.Fatalf("token %q", token)
	}
	data, err := os.ReadFile(filepath.Join(dir, FileName))
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != token+"\n" {
		t.Fatalf("file holds %q", data)
	}
}
