package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

// recordingSubtitles is the provider under the service, kept only to see what
// the API decided the query was.
type recordingSubtitles struct{ got subtitles.Query }

func (r *recordingSubtitles) ID() string   { return "os" }
func (r *recordingSubtitles) Name() string { return "os" }
func (r *recordingSubtitles) Subtitles(_ context.Context, q subtitles.Query) ([]subtitles.Subtitle, error) {
	r.got = q
	return []subtitles.Subtitle{
		{ProviderID: "os", Language: "en", SourceURL: "https://opensubtitles/1.srt"},
	}, nil
}

// subtitleServer wires a catalog with one series in it to a download of one
// episode of that series, which is the state the player asks from.
func subtitleServer(t *testing.T, provider subtitles.Provider, data []byte) (http.Handler, string) {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: severance()}, log)
	backend := &fakeStreamBackend{task: &fakeStreamTask{
		file: &fakeStreamFile{name: "Severance.S02E03.1080p.WEB.H264-SuccessfulCrab.mkv", data: data},
	}}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, newFakeStore(), log)
	d, err := manager.Start(context.Background(), acquire.Request{
		ItemID:  "abc123",
		Season:  2,
		Episode: 3,
		Source: sources.MediaSource{
			RawName: "Severance.S02E03.1080p.WEB.H264-SuccessfulCrab",
			Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"},
		},
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	subs := subtitles.NewService(func() []subtitles.Provider { return []subtitles.Provider{provider} }, []string{"en"}, log)
	return New(Deps{Catalog: cat, Downloads: manager, Subtitles: subs}, log).Handler(), d.ID
}

// The lookup is about the file being played: our id becomes an IMDb id, the
// download supplies the episode, the name it downloaded under, and the hash
// that identifies this exact encode.
func TestSubtitlesDescribesTheFileBeingPlayed(t *testing.T) {
	provider := &recordingSubtitles{}
	data := make([]byte, 200000)
	for i := range data {
		data[i] = byte((i*7 + 3) % 251)
	}
	h, id := subtitleServer(t, provider, data)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet,
		"/api/v1/subtitles?item=abc123&download="+id+"&lang=rus,en", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}

	got := provider.got
	if got.IMDbID != "tt11280740" || got.Kind != catalog.KindSeries {
		t.Errorf("id: got %q %q", got.IMDbID, got.Kind)
	}
	if got.Season != 2 || got.Episode != 3 {
		t.Errorf("episode: got S%02dE%02d", got.Season, got.Episode)
	}
	if got.Filename != "Severance.S02E03.1080p.WEB.H264-SuccessfulCrab.mkv" {
		t.Errorf("filename: got %q", got.Filename)
	}
	if got.VideoSize != int64(len(data)) {
		t.Errorf("size: got %d", got.VideoSize)
	}
	if got.VideoHash != "e6ed0e283146465f" {
		t.Errorf("hash: got %q", got.VideoHash)
	}
	if got.Release.Group != "SuccessfulCrab" {
		t.Errorf("release: got %+v", got.Release)
	}
	// "rus" is what a subtitle database calls it and "ru" is what everything
	// else here does; a preference that does not survive that is no
	// preference at all.
	if len(got.Languages) != 2 || got.Languages[0] != "ru" || got.Languages[1] != "en" {
		t.Errorf("languages: got %v", got.Languages)
	}
}

// A file too short to hash, or a swarm that has not sent its last piece yet,
// costs precision — never the lookup.
func TestSubtitlesWithoutAHashStillAnswers(t *testing.T) {
	provider := &recordingSubtitles{}
	h, id := subtitleServer(t, provider, []byte("too short to hash"))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?item=abc123&download="+id, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if provider.got.VideoHash != "" {
		t.Errorf("hash: got %q, want none", provider.got.VideoHash)
	}
	if provider.got.IMDbID != "tt11280740" {
		t.Errorf("id: got %q", provider.got.IMDbID)
	}
}

// The client is handed ids of ours. The provider's address stays in the core,
// or the fetch endpoint becomes a way to make the core request anything.
func TestSubtitlesHidesTheProviderURL(t *testing.T) {
	h, id := subtitleServer(t, &recordingSubtitles{}, []byte("short"))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?item=abc123&download="+id, nil))
	var body struct {
		Subtitles []subtitles.Subtitle `json:"subtitles"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Subtitles) != 1 {
		t.Fatalf("got %d subtitles", len(body.Subtitles))
	}
	if url := body.Subtitles[0].URL; !strings.HasPrefix(url, "/api/v1/subtitles/") {
		t.Errorf("url: got %q", url)
	}
	if strings.Contains(rec.Body.String(), "opensubtitles/1.srt") {
		t.Errorf("the provider url reached the client: %s", rec.Body)
	}
}

func TestSubtitleFileRejectsUnknownTokens(t *testing.T) {
	h, _ := subtitleServer(t, &recordingSubtitles{}, []byte("short"))

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles/deadbeef.srt", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
}

// A core configured without subtitle providers says so, rather than answering
// with an empty list that looks like "nothing exists for this film".
func TestSubtitlesWithoutProvidersSaysSo(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New(Deps{}, log).Handler()

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?imdb=tt1375666", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
}

func TestSubtitlesUsesPreferencesUnlessLangIsGiven(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer db.Close()
	prefs := preferences.New(db, preferences.Preferences{SubtitleLanguages: []string{"en"}})
	if _, err := prefs.Patch(context.Background(), []byte(`{"subtitleLanguages":["ru","en"]}`)); err != nil {
		t.Fatalf("store preferences: %v", err)
	}
	provider := &recordingSubtitles{}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	subs := subtitles.NewService(func() []subtitles.Provider { return []subtitles.Provider{provider} }, []string{"fr"}, log)
	h := New(Deps{Subtitles: subs, Preferences: prefs}, log).Handler()

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?imdb=tt1375666", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("preference request status %d: %s", rec.Code, rec.Body)
	}
	if !reflect.DeepEqual(provider.got.Languages, []string{"ru", "en"}) {
		t.Fatalf("preference languages = %v, want [ru en]", provider.got.Languages)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?imdb=tt1375666&lang=de", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("parameter request status %d: %s", rec.Code, rec.Body)
	}
	if !reflect.DeepEqual(provider.got.Languages, []string{"de"}) {
		t.Fatalf("parameter languages = %v, want [de]", provider.got.Languages)
	}
}

type keptProvider struct {
	url string
	err error
}

func (p *keptProvider) ID() string   { return "os" }
func (p *keptProvider) Name() string { return "os" }
func (p *keptProvider) Subtitles(context.Context, subtitles.Query) ([]subtitles.Subtitle, error) {
	return []subtitles.Subtitle{{ProviderID: "os", ID: "7", Language: "en", SourceURL: p.url}}, p.err
}

// Subtitles kept with a download come first and play with no provider and no
// catalog to ask: offline, they are all there is.
func TestSubtitlesKeptWithTheDownloadAnswerOffline(t *testing.T) {
	files := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "1\n00:00:01,000 --> 00:00:02,000\nPlay it, Sam.\n")
	}))
	defer files.Close()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: severance()}, log)
	backend := &fakeStreamBackend{task: &fakeStreamTask{
		file: &fakeStreamFile{name: "episode.mkv", data: make([]byte, 200000)},
	}}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, newFakeStore(), log)
	d, err := manager.Start(context.Background(), acquire.Request{
		ItemID: "abc123", Season: 2, Episode: 3,
		Source: sources.MediaSource{Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"}},
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	provider := &keptProvider{url: files.URL + "/en.srt"}
	subs := subtitles.NewService(func() []subtitles.Provider { return []subtitles.Provider{provider} }, nil, log)
	subtitles.NewKeeper(subs, manager, cat, func(context.Context, string) []string { return []string{"en"} }, log).
		Pass(context.Background())
	h := New(Deps{Catalog: cat, Downloads: manager, Subtitles: subs}, log).Handler()

	provider.err = errors.New("no route to host")
	for _, item := range []string{"abc123", "not-in-the-catalog"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?item="+item+"&download="+d.ID, nil))
		var body struct {
			Subtitles []subtitles.Subtitle `json:"subtitles"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || rec.Code != http.StatusOK {
			t.Fatalf("item %s: status %d: %s", item, rec.Code, rec.Body)
		}
		if len(body.Subtitles) != 1 || !body.Subtitles[0].Kept || body.Subtitles[0].URL != "/api/v1/downloads/"+d.ID+"/subtitles/1.srt" {
			t.Fatalf("item %s: got %+v, want the kept file", item, body.Subtitles)
		}
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+d.ID+"/subtitles/1.srt", nil))
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Play it, Sam.") ||
		!strings.HasPrefix(rec.Header().Get("Content-Type"), "application/x-subrip") {
		t.Fatalf("kept file: %d %q %s", rec.Code, rec.Header().Get("Content-Type"), rec.Body)
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+d.ID+"/subtitles/subtitles.json", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("a file the index does not list: status %d", rec.Code)
	}

	// Answered again, the provider's copy of the kept file is not listed twice.
	provider.err = nil
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?item=abc123&download="+d.ID, nil))
	if n := strings.Count(rec.Body.String(), `"id":"7"`); n != 1 {
		t.Fatalf("the kept subtitle is listed %d times: %s", n, rec.Body)
	}
}
