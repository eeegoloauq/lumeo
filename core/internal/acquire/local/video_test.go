package local

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

func TestVideoContainer(t *testing.T) {
	ts := make([]byte, 200)
	ts[0], ts[188] = 0x47, 0x47
	for name, head := range map[string][]byte{
		"matroska":  []byte("\x1a\x45\xdf\xa3\x01"),
		"mp4":       []byte("\x00\x00\x00\x20ftypisom"),
		"quicktime": []byte("\x00\x00\x00\x08wide"),
		"avi":       []byte("RIFF\x00\x00\x00\x00AVI LIST"),
		"asf":       []byte("\x30\x26\xb2\x75\x8e\x66\xcf\x11\xa6"),
		"flv":       []byte("FLV\x01"),
		"ogg":       []byte("OggS\x00"),
		"mpeg-ps":   []byte("\x00\x00\x01\xba\x44"),
		"mpeg-ts":   ts,
	} {
		if !videoContainer(head) {
			t.Errorf("%s not recognised", name)
		}
	}
	for name, head := range map[string][]byte{
		"empty":    nil,
		"text":     []byte("root:x:0:0:root:/root:/bin/bash\n"),
		"ssh key":  []byte("-----BEGIN OPENSSH PRIVATE KEY-----"),
		"sqlite":   []byte("SQLite format 3\x00"),
		"wav":      []byte("RIFF\x00\x00\x00\x00WAVEfmt "),
		"one sync": append([]byte{0x47}, make([]byte, 199)...),
	} {
		if videoContainer(head) {
			t.Errorf("%s taken for a video", name)
		}
	}
}

// Whoever can reach the API can name a path. A link called film.mkv to a
// secret, or a video swapped for one after it was opened, is not served.
func TestLocalFilesAreReadOnlyWhileTheyHoldAVideo(t *testing.T) {
	dir := t.TempDir()
	secret := filepath.Join(dir, "id_ed25519")
	if err := os.WriteFile(secret, []byte("-----BEGIN OPENSSH PRIVATE KEY-----\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "film.mkv")
	if err := os.Symlink(secret, link); err != nil {
		t.Fatal(err)
	}
	if _, err := (Backend{}).Start(context.Background(), sources.Locator{Scheme: "file", Path: link}, ""); !errors.Is(err, ErrNotVideo) {
		t.Fatalf("a link to a secret was opened: %v", err)
	}

	film := filepath.Join(dir, "real.mkv")
	if err := os.WriteFile(film, []byte("\x1a\x45\xdf\xa3film"), 0o600); err != nil {
		t.Fatal(err)
	}
	task, err := (Backend{}).Start(context.Background(), sources.Locator{Scheme: "file", Path: film}, "")
	if err != nil {
		t.Fatal(err)
	}
	f, _ := task.File()
	if err := os.Remove(film); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, film); err != nil {
		t.Fatal(err)
	}
	if r, err := f.Open(context.Background()); !errors.Is(err, ErrNotVideo) {
		if r != nil {
			r.Close()
		}
		t.Fatalf("a video swapped for a secret was read: %v", err)
	}
}
