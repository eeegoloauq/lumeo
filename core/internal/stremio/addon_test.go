package stremio

import "testing"

func TestParseSeedersAndSize(t *testing.T) {
	// Shape taken from a real Torrentio response.
	text := "[Erai-raws] Re:Zero kara Hajimeru Isekai Seikatsu 4th Season - 14 [1080p][HEVC]\n👤 2390 💾 1.35 GB ⚙️ Torrentio"
	if got := parseSeeders(text); got != 2390 {
		t.Errorf("seeders: got %d", got)
	}
	if got := parseSize(text); got != 1449551462 {
		t.Errorf("size: got %d", got)
	}
	if got := firstLine(text); got != "[Erai-raws] Re:Zero kara Hajimeru Isekai Seikatsu 4th Season - 14 [1080p][HEVC]" {
		t.Errorf("firstLine: got %q", got)
	}
}

// Everything below the release name is the addon's own rendering, and it is
// the only place some facts exist at all: which tracker answered, and which
// audio languages the copy carries.
func TestParseTrackerAndFlags(t *testing.T) {
	text := "[Tenrai-Sensei] Is It Wrong to Try to Pick Up Girls in a Dungeon?\n" +
		"Season 1/S01E01 - Adventurer Bell Cranel.mkv\n" +
		"👤 154 💾 346.03 MB ⚙️ NyaaSi\n" +
		"Multi Audio / 🇬🇧 / 🇷🇺 / 🇯🇵"

	if got := parseTracker(text); got != "NyaaSi" {
		t.Errorf("tracker: got %q", got)
	}
	got := parseFlagLanguages(text)
	want := []string{"en", "ru", "ja"}
	if len(got) != len(want) {
		t.Fatalf("languages: got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("languages: got %v, want %v", got, want)
		}
	}
}

func TestParseFlagsIgnoresTextWithoutFlags(t *testing.T) {
	if got := parseFlagLanguages("👤 12 💾 1.4 GB ⚙️ 1337x\nDubbed / Dual Audio"); got != nil {
		t.Errorf("got %v, want nothing", got)
	}
}

func TestParseTrackerWhenAbsent(t *testing.T) {
	if got := parseTracker("Some.Release.1080p\n👤 5 💾 900 MB"); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

// One pack can carry an episode twice, as a broadcast cut and a director's
// cut in their own folders; the folder exists only on the addon's second line.
func TestPackPathIsTheLineEndingWithTheFile(t *testing.T) {
	text := "[Group] The Prisoner (Season 01 + Director's Cut) [1080p]\n" +
		"[Group] The Prisoner Director's Cut/[Group] The Prisoner Director's Cut - 09.mkv\n" +
		"👤 395 💾 486.71 MB ⚙️ NyaaSi"
	if got := packPath(text, "[Group] The Prisoner Director's Cut - 09.mkv"); got != "[Group] The Prisoner Director's Cut/[Group] The Prisoner Director's Cut - 09.mkv" {
		t.Errorf("path: got %q", got)
	}
	if got := packPath("The.Prisoner.S01E09.1080p\n👤 5 💾 900 MB", "The.Prisoner.S01E09.1080p.mkv"); got != "" {
		t.Errorf("a line that is not the file: got %q", got)
	}
}
