package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

func preferenceServer(t *testing.T, defaults preferences.Preferences) http.Handler {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	prefs := preferences.New(db, defaults)
	return New(Deps{Preferences: prefs}, log).Handler()
}

func requestJSON(t *testing.T, h http.Handler, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func decodePreferences(t *testing.T, rec *httptest.ResponseRecorder) preferences.Preferences {
	t.Helper()
	var got preferences.Preferences
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode preferences: %v", err)
	}
	return got
}

func TestGetPreferencesReturnsDefaults(t *testing.T) {
	want := preferences.Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 1}
	rec := requestJSON(t, preferenceServer(t, want), http.MethodGet, "/api/v1/preferences", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if got := decodePreferences(t, rec); !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %+v, want %+v", got, want)
	}
}

func TestPatchPreferencesPersistsNormalizedValues(t *testing.T) {
	h := preferenceServer(t, preferences.Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 1})
	want := preferences.Preferences{SubtitleLanguages: []string{"ru", "en"}, SubtitleScale: 1.5}
	rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"subtitleLanguages":["RU","en","ru"],"subtitleScale":1.5}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("patch status %d: %s", rec.Code, rec.Body)
	}
	if got := decodePreferences(t, rec); !reflect.DeepEqual(got, want) {
		t.Fatalf("patched preferences = %+v, want %+v", got, want)
	}

	rec = requestJSON(t, h, http.MethodGet, "/api/v1/preferences", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("get status %d: %s", rec.Code, rec.Body)
	}
	if got := decodePreferences(t, rec); !reflect.DeepEqual(got, want) {
		t.Fatalf("stored preferences = %+v, want %+v", got, want)
	}
}

func TestPatchPreferencesNullRestoresDefault(t *testing.T) {
	want := preferences.Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 1}
	h := preferenceServer(t, want)
	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"subtitleScale":1.5}`); rec.Code != http.StatusOK {
		t.Fatalf("initial patch status %d: %s", rec.Code, rec.Body)
	}
	rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"subtitleScale":null}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("reset status %d: %s", rec.Code, rec.Body)
	}
	if got := decodePreferences(t, rec); !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %+v, want %+v", got, want)
	}
}

func TestPatchEpisodeArtworkPersistsAndResets(t *testing.T) {
	want := preferences.Preferences{SubtitleScale: 1, EpisodeArtwork: "blur"}
	h := preferenceServer(t, want)
	rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"episodeArtwork":"show"}`)
	if rec.Code != http.StatusOK || decodePreferences(t, rec).EpisodeArtwork != "show" {
		t.Fatalf("patch status %d: %s", rec.Code, rec.Body)
	}
	rec = requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"episodeArtwork":null}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("reset status %d: %s", rec.Code, rec.Body)
	}
	if got := decodePreferences(t, rec); !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %+v, want %+v", got, want)
	}
}

func TestPatchPreferencesRejectsInvalidRequestsWithoutChangingValues(t *testing.T) {
	want := preferences.Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 1}
	h := preferenceServer(t, want)
	tests := []struct {
		name string
		body string
		code int
	}{
		{name: "unknown preference", body: `{"foo":1}`, code: http.StatusBadRequest},
		{name: "out of range subtitle scale", body: `{"subtitleScale":9}`, code: http.StatusBadRequest},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", tt.body)
			if rec.Code != tt.code {
				t.Fatalf("status %d: %s", rec.Code, rec.Body)
			}
			rec = requestJSON(t, h, http.MethodGet, "/api/v1/preferences", "")
			if got := decodePreferences(t, rec); !reflect.DeepEqual(got, want) {
				t.Fatalf("preferences changed to %+v, want %+v", got, want)
			}
		})
	}
}

func TestPatchPreferencesRequiresJSONContentType(t *testing.T) {
	h := preferenceServer(t, preferences.Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 1})
	req := httptest.NewRequest(http.MethodPatch, "/api/v1/preferences", strings.NewReader(`{"subtitleScale":1.5}`))
	req.Header.Set("Content-Type", "text/plain")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
}

func TestPreferenceLanguagesReturnsNamedLanguages(t *testing.T) {
	h := preferenceServer(t, preferences.Preferences{})
	rec := requestJSON(t, h, http.MethodGet, "/api/v1/preferences/languages", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	var body struct {
		Languages []subtitles.NamedLanguage `json:"languages"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode languages: %v", err)
	}
	if !reflect.DeepEqual(body.Languages, subtitles.Languages()) {
		t.Fatalf("languages = %+v, want %+v", body.Languages, subtitles.Languages())
	}
}

func TestPreferenceRoutesWithoutServiceSaySo(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New(Deps{}, log).Handler()
	for _, path := range []string{"/api/v1/preferences", "/api/v1/preferences/languages"} {
		rec := requestJSON(t, h, http.MethodGet, path, "")
		if rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s: status %d, want 503", path, rec.Code)
		}
	}
}

func TestAboutReturnsVersionAndDirectories(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	want := About{Version: "0.1.42", Addr: "127.0.0.1:7666", DataDir: "/srv/lumeo", DownloadDir: "/mnt/media", LogPath: "/srv/lumeo/core.log"}
	h := New(Deps{About: want}, log).Handler()
	rec := requestJSON(t, h, http.MethodGet, "/api/v1/about", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	var got About
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode about: %v", err)
	}
	if got != want {
		t.Fatalf("about = %+v, want %+v", got, want)
	}

	// A log that is not a file has no path, and says nothing of one.
	want.LogPath = ""
	rec = requestJSON(t, New(Deps{About: want}, log).Handler(), http.MethodGet, "/api/v1/about", "")
	if strings.Contains(rec.Body.String(), "logPath") {
		t.Fatalf("about names a log file it has not got: %s", rec.Body)
	}
}

// The download folder a client is shown is the one downloads go to now: a
// preference moves it while the core runs, and storage reports the same one.
func TestAboutAndStorageReportTheEffectiveDownloadDir(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	manager := acquire.NewManager("/built/in", nil, newFakeStore(), log)
	h := New(Deps{Downloads: manager, About: About{DownloadDir: "/built/in"}}, log).Handler()
	moved := t.TempDir()
	manager.SetDir(moved)

	var about About
	if err := json.Unmarshal(requestJSON(t, h, http.MethodGet, "/api/v1/about", "").Body.Bytes(), &about); err != nil {
		t.Fatal(err)
	}
	var storage struct {
		Dir string `json:"dir"`
	}
	if err := json.Unmarshal(requestJSON(t, h, http.MethodGet, "/api/v1/storage", "").Body.Bytes(), &storage); err != nil {
		t.Fatal(err)
	}
	if about.DownloadDir != moved || storage.Dir != moved {
		t.Fatalf("about says %s, storage %s; want %s", about.DownloadDir, storage.Dir, moved)
	}
}

// DELETE puts every preference back, and answers with the defaults.
func TestResetPreferences(t *testing.T) {
	defaults := preferences.Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 1, Accent: "white", Keep: "forever", KeepDays: 30, SeekStep: 5, Seed: true}
	h := preferenceServer(t, defaults)
	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences",
		`{"accent":"violet","keep":"30days","seekStep":10,"seed":false,"downloadLimit":1000}`); rec.Code != http.StatusOK {
		t.Fatalf("patch: status %d: %s", rec.Code, rec.Body)
	}
	rec := requestJSON(t, h, http.MethodDelete, "/api/v1/preferences", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("reset: status %d: %s", rec.Code, rec.Body)
	}
	if got := decodePreferences(t, rec); !reflect.DeepEqual(got, defaults) {
		t.Fatalf("after reset = %+v, want %+v", got, defaults)
	}
	if got := decodePreferences(t, requestJSON(t, h, http.MethodGet, "/api/v1/preferences", "")); !reflect.DeepEqual(got, defaults) {
		t.Fatalf("read back = %+v, want %+v", got, defaults)
	}
}
