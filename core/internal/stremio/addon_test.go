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
