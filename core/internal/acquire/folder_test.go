package acquire

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestFolderForNamesTheTitleTheWayLibrariesDo(t *testing.T) {
	long := strings.Repeat("Long ", 30)
	for _, c := range []struct {
		title  string
		year   int
		series bool
		season int
		want   string
	}{
		{"The Matrix", 1999, false, 0, "The Matrix (1999)"},
		{"Severance", 2022, true, 1, filepath.Join("Severance (2022)", "Season 01")},
		{"Severance", 2022, true, 0, filepath.Join("Severance (2022)", "Specials")},
		{"Star Wars: Andor", 2022, true, 2, filepath.Join("Star Wars - Andor (2022)", "Season 02")},
		// What Windows refuses goes, and the dots it drops from the end.
		{"What If...?", 2021, true, 10, filepath.Join("What If (2021)", "Season 10")},
		{"AC/DC <Live>", 0, false, 0, "AC DC Live"},
		// A leading dot hides a folder.
		{"...And Justice for All", 1979, false, 0, "And Justice for All (1979)"},
		{"Nul", 0, false, 0, "Nul_"},
		{"Nul", 2020, false, 0, "Nul (2020)"},
		{"?", 2020, false, 0, ""},
		{long, 0, false, 0, strings.TrimSpace(long[:80])},
	} {
		if got := FolderFor(c.title, c.year, c.series, c.season); got != c.want {
			t.Errorf("FolderFor(%q, %d, %v, %d) = %q, want %q", c.title, c.year, c.series, c.season, got, c.want)
		}
	}
}
