package main

import (
	"os"
	"path/filepath"
	"testing"
)

// The log is named when it goes to a file, and not when it goes anywhere else.
func TestLogFileNamesOnlyAFile(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "core.log")
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if got := logFile(file); got != path {
		t.Fatalf("log file = %q, want %q", got, path)
	}

	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	if got := logFile(writer); got != "" {
		t.Fatalf("a pipe is named %q", got)
	}

	// Deleted, it has no name to show.
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if got := logFile(file); got != "" {
		t.Fatalf("a deleted log is named %q", got)
	}
}
