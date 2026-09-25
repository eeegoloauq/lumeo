package torrent

import (
	"path/filepath"
	"testing"
)

// Torrent metadata is written by strangers, so the path it names is checked
// before we ever report it as a place on this machine.
func TestSafeFilePathRefusesEscapes(t *testing.T) {
	dir := filepath.Join(string(filepath.Separator), "data", "downloads", "abc")
	cases := []struct {
		name string
		in   string
		want string // empty means it must be refused
	}{
		{"plain file", "movie.mkv", filepath.Join(dir, "movie.mkv")},
		{"nested", "pack/S02E01.mkv", filepath.Join(dir, "pack", "S02E01.mkv")},
		{"dot segments that stay inside", "pack/./sub/../S02E01.mkv", filepath.Join(dir, "pack", "S02E01.mkv")},
		{"parent", "../escaped.mkv", ""},
		{"deep parent", "a/../../../etc/cron.d/payload", ""},
		{"absolute", "/etc/cron.d/payload", filepath.Join(dir, "etc", "cron.d", "payload")},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := safeFilePath(dir, c.in)
			if c.want == "" {
				if ok {
					t.Errorf("accepted %q as %q, want refusal", c.in, got)
				}
				return
			}
			if !ok {
				t.Fatalf("refused %q, want %q", c.in, c.want)
			}
			if got != c.want {
				t.Errorf("%q resolved to %q, want %q", c.in, got, c.want)
			}
		})
	}
}
