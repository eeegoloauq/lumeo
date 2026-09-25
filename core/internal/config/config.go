// Package config holds the runtime knobs of the core. Local mode and server
// mode differ only in what is set here, never in code paths.
package config

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// cinemetaURL is the addon that makes the whole MVP work with zero setup: the
// same protocol our source providers speak, no API key, and it carries the
// tmdb/tvdb ids that fill our external id map for free.
const cinemetaURL = "https://v3-cinemeta.strem.io"

// opensubtitlesURL is the same protocol again, for the resource that turns a
// file being played into subtitles timed for it. Like Cinemeta it needs no
// account, which is what keeps "watch it with subtitles" out of the setup.
const opensubtitlesURL = "https://opensubtitles-v3.strem.io"

type Addon struct {
	ID      string
	Name    string
	BaseURL string
}

type Config struct {
	Addr     string // HTTP listen address
	DataDir  string // SQLite + library metadata
	CacheDir string // downloaded artwork
	// Addons a fresh database starts with. What each one is for — catalog,
	// metadata, streams, subtitles — is read from its manifest, not set here.
	Addons []Addon
	// SubtitleLanguages is the preference order a lookup uses when the client
	// does not state one, as ISO 639-1.
	SubtitleLanguages []string
	EpisodeArtwork    string // episode image treatment: "show", "blur", or "hide"
	TorrentPort       int    // 0 asks the OS for a free port
	Seed              bool   // keep uploading after a download completes
	// ExitOnStdinEOF makes the core stop when its stdin closes. The app that
	// starts it as a child holds the pipe, and any death of the app closes
	// it, kill -9 included; a core started by hand does not set it.
	ExitOnStdinEOF bool
}

// DBPath is the one SQLite file the core keeps everything in.
func (c Config) DBPath() string { return filepath.Join(c.DataDir, "lumeo.db") }

// DownloadDir is where acquired media lands, one directory per download.
func (c Config) DownloadDir() string { return filepath.Join(c.DataDir, "downloads") }

// FromEnv reads the environment, falling back to values that make a fresh
// checkout run without a config file.
func FromEnv() Config {
	c := Config{
		Addr:     envOr("LUMEO_ADDR", "127.0.0.1:7666"),
		DataDir:  envOr("LUMEO_DATA", defaultDataDir()),
		CacheDir: envOr("LUMEO_CACHE", defaultCacheDir()),
	}
	// LUMEO_ADDONS: comma-separated addon URLs, optionally "name=url". It is
	// what a database with no addons starts with — the list is edited over
	// the API after that — and "none" starts with an empty one.
	if spec := os.Getenv("LUMEO_ADDONS"); spec != "" {
		if spec != "none" {
			c.Addons = parseAddons(spec, "addon")
		}
	} else {
		c.Addons = []Addon{
			{ID: "cinemeta", Name: "Cinemeta", BaseURL: cinemetaURL},
			{ID: "opensubtitles", Name: "OpenSubtitles", BaseURL: opensubtitlesURL},
		}
	}
	c.SubtitleLanguages = parseList(envOr("LUMEO_SUBTITLE_LANGS", "en"))
	c.EpisodeArtwork = os.Getenv("LUMEO_EPISODE_ARTWORK")
	if c.EpisodeArtwork != "show" && c.EpisodeArtwork != "blur" && c.EpisodeArtwork != "hide" {
		c.EpisodeArtwork = "show"
	}
	c.TorrentPort, _ = strconv.Atoi(os.Getenv("LUMEO_TORRENT_PORT"))
	// Seeding is on unless asked otherwise: leeching from a swarm and giving
	// nothing back is how swarms die.
	c.Seed = os.Getenv("LUMEO_SEED") != "false"
	c.ExitOnStdinEOF = os.Getenv("LUMEO_EXIT_ON_STDIN_EOF") == "1"
	return c
}

// defaultDataDir is where an installed copy keeps the library. A desktop
// application that writes into whatever directory it happened to be started
// from is a bug, so this follows the XDG base directory spec, and on Windows
// %LOCALAPPDATA% (local rather than roaming: downloads are gigabytes that must
// not follow the account between machines). A checkout run from the source
// tree still gets ./data by setting LUMEO_DATA.
func defaultDataDir() string {
	if dir := os.Getenv("LOCALAPPDATA"); runtime.GOOS == "windows" && dir != "" {
		return filepath.Join(dir, "Lumeo", "Data")
	}
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		return filepath.Join(dir, "lumeo")
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".local", "share", "lumeo")
	}
	return "./data"
}

func defaultCacheDir() string {
	if dir := os.Getenv("LOCALAPPDATA"); runtime.GOOS == "windows" && dir != "" {
		return filepath.Join(dir, "Lumeo", "Cache")
	}
	if dir := os.Getenv("XDG_CACHE_HOME"); dir != "" {
		return filepath.Join(dir, "lumeo")
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".cache", "lumeo")
	}
	return "./cache"
}

func parseAddons(spec, defaultName string) []Addon {
	var out []Addon
	for _, entry := range strings.Split(spec, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		name, url, ok := strings.Cut(entry, "=")
		if !ok {
			name, url = defaultName, entry
		}
		out = append(out, Addon{ID: name, Name: name, BaseURL: url})
	}
	return out
}

// parseList reads a comma-separated setting into the order it was written in.
func parseList(spec string) []string {
	var out []string
	for _, v := range strings.Split(spec, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
