package config

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestPublicURLRequiresAnHTTPSOrigin(t *testing.T) {
	for _, value := range []string{"", "https://lumeo.example.com", "https://example.com:8443"} {
		if err := (Config{PublicURL: value}).Validate(); err != nil {
			t.Errorf("%q: %v", value, err)
		}
	}
	for _, value := range []string{"http://example.com", "https://user:secret@example.com", "https://example.com/path", "https://example.com?x=1", "https://example.com#fragment", "https://"} {
		if err := (Config{PublicURL: value}).Validate(); err == nil {
			t.Errorf("accepted %q", value)
		}
	}
}

// The certificate names the public address, so TLS without one is refused,
// as is a value that is not a kind of TLS the core knows.
func TestTLSNeedsThePublicAddress(t *testing.T) {
	ok := Config{TLS: "self-signed", PublicURL: "https://192.168.1.50:7666"}
	if err := ok.Validate(); err != nil || ok.PublicHost() != "192.168.1.50" {
		t.Fatalf("%v %q", err, ok.PublicHost())
	}
	for _, c := range []Config{{TLS: "self-signed"}, {TLS: "yes", PublicURL: "https://lumeo.lan"}} {
		if err := c.Validate(); err == nil {
			t.Errorf("accepted %+v", c)
		}
	}
}

// An installed application must not write its library into whatever directory
// it was started from — for a desktop launcher that is the user's home, or /.
func TestDataDirFollowsXDG(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "/tmp/xdg")
	if got := FromEnv().DataDir; got != filepath.Join("/tmp/xdg", "lumeo") {
		t.Errorf("got %q", got)
	}
}

func TestDataDirFallsBackToTheHomeDirectory(t *testing.T) {
	t.Setenv("XDG_DATA_HOME", "")
	t.Setenv("HOME", "/home/someone")
	if got := FromEnv().DataDir; got != "/home/someone/.local/share/lumeo" {
		t.Errorf("got %q", got)
	}
}

// A checkout still runs out of its own directory when asked to.
func TestDataDirIsOverridable(t *testing.T) {
	t.Setenv("LUMEO_DATA", "./data")
	if got := FromEnv().DataDir; got != "./data" {
		t.Errorf("got %q", got)
	}
}

func TestCacheDirPriority(t *testing.T) {
	t.Setenv("HOME", "/home/someone")
	t.Setenv("XDG_CACHE_HOME", "")
	t.Setenv("LUMEO_CACHE", "")
	if got := FromEnv().CacheDir; got != "/home/someone/.cache/lumeo" {
		t.Fatalf("home cache = %q", got)
	}
	t.Setenv("XDG_CACHE_HOME", "/tmp/xdg-cache")
	if got := FromEnv().CacheDir; got != "/tmp/xdg-cache/lumeo" {
		t.Fatalf("XDG cache = %q", got)
	}
	t.Setenv("LUMEO_CACHE", "/tmp/artwork-cache")
	if got := FromEnv().CacheDir; got != "/tmp/artwork-cache" {
		t.Fatalf("override cache = %q", got)
	}
}

func TestSubtitleLanguageDefault(t *testing.T) {
	t.Setenv("LUMEO_SUBTITLE_LANGS", "")
	cfg := FromEnv()
	if len(cfg.SubtitleLanguages) != 1 || cfg.SubtitleLanguages[0] != "en" {
		t.Errorf("languages: %v", cfg.SubtitleLanguages)
	}
}

func TestEpisodeArtworkDefaultAndValidation(t *testing.T) {
	for _, test := range []struct{ value, want string }{
		{"", "show"},
		{"blur", "blur"},
		{"show", "show"},
		{"hide", "hide"},
		{"unknown", "show"},
	} {
		t.Run(test.value, func(t *testing.T) {
			t.Setenv("LUMEO_EPISODE_ARTWORK", test.value)
			if got := FromEnv().EpisodeArtwork; got != test.want {
				t.Fatalf("episode artwork = %q, want %q", got, test.want)
			}
		})
	}
}

// Nothing sets LUMEO_ADDONS for an installed copy — not the desktop launcher,
// not the RPM — so an empty environment has to already be a working one: a
// catalogue and subtitles. Where to play from is the user's to add: no source
// ships with the app.
func TestAddonDefaults(t *testing.T) {
	t.Setenv("LUMEO_ADDONS", "")
	cfg := FromEnv()
	var ids []string
	for _, a := range cfg.Addons {
		ids = append(ids, a.ID)
	}
	if got := strings.Join(ids, ","); got != "cinemeta,opensubtitles" {
		t.Errorf("addons: %v", got)
	}
}

func TestAddonsAreOverridable(t *testing.T) {
	t.Setenv("LUMEO_ADDONS", "mine=https://example.invalid/addon")
	got := FromEnv().Addons
	if len(got) != 1 || got[0].ID != "mine" || got[0].BaseURL != "https://example.invalid/addon" {
		t.Errorf("got %+v", got)
	}
}

func TestAddonsCanBeTurnedOff(t *testing.T) {
	t.Setenv("LUMEO_ADDONS", "none")
	if got := FromEnv().Addons; len(got) != 0 {
		t.Errorf("got %+v, want none", got)
	}
}

func TestModeDefaultAndValidation(t *testing.T) {
	t.Setenv("LUMEO_MODE", "")
	if got := FromEnv().Mode; got != "full" {
		t.Errorf("default mode = %q, want full", got)
	}
	t.Setenv("LUMEO_MODE", "media")
	if c := FromEnv(); c.Mode != "media" || c.Validate() != nil {
		t.Errorf("media: mode %q, %v", c.Mode, c.Validate())
	}
	// A typo must not quietly keep the devices' data on the server.
	t.Setenv("LUMEO_MODE", "medai")
	if err := FromEnv().Validate(); err == nil {
		t.Error("accepted an unknown mode")
	}
}
