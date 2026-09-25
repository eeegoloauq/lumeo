package local

import (
	"context"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestBackend(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "film.mkv")
	if err := os.WriteFile(path, []byte("\x1a\x45\xdf\xa3m"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, path string
		ok         bool
	}{{"file", path, true}, {"missing", filepath.Join(dir, "gone"), false}, {"directory", dir, false}, {"relative", "film.mkv", false}} {
		t.Run(tc.name, func(t *testing.T) {
			task, err := (Backend{}).Start(context.Background(), sources.Locator{Scheme: "file", Path: tc.path}, "ignored")
			if !tc.ok {
				if err == nil {
					t.Fatal("accepted invalid path")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			f, ready := task.File()
			if !ready || f.Head() != 5 || f.Size() != 5 || task.Progress().Completed != 5 || task.Progress().Total != 5 {
				t.Fatalf("file=%v progress=%+v", f, task.Progress())
			}
			r, err := f.Open(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			defer r.Close()
			got, err := io.ReadAll(r)
			if err != nil || string(got) != "\x1a\x45\xdf\xa3m" {
				t.Fatalf("read %q: %v", got, err)
			}
		})
	}
}
