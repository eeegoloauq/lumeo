package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	acquirelocal "github.com/eeegoloauq/lumeo/core/internal/acquire/local"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/local"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

func localAPI(t *testing.T) (http.Handler, *acquire.Manager, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "Film.2020.mkv")
	if err := os.WriteFile(path, append([]byte("\x1a\x45\xdf\xa3"), make([]byte, 128<<10-4)...), 0600); err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	store := newFakeStore()
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{acquirelocal.Backend{}}, store, log)
	t.Cleanup(func() { manager.Close() })
	files := local.New(nil, manager, log)
	t.Cleanup(files.Close) // before the manager's, as in the core
	h := New(Deps{Downloads: manager, Local: files}, log).Handler()
	return h, manager, path
}
func TestLocalEndpointAndStreamETag(t *testing.T) {
	h, _, path := localAPI(t)
	body, _ := json.Marshal(map[string]string{"path": path})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/local", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("open status=%d body=%s", rec.Code, rec.Body)
	}
	var d acquire.Download
	if err := json.Unmarshal(rec.Body.Bytes(), &d); err != nil {
		t.Fatal(err)
	}
	stream := func() string {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodHead, "/api/v1/downloads/"+d.ID+"/stream", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("stream status=%d body=%s", rec.Code, rec.Body)
		}
		return rec.Header().Get("ETag")
	}
	first := stream()
	now := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	if second := stream(); first == second {
		t.Fatalf("etag unchanged: %s", first)
	}
	for _, tc := range []struct {
		body   string
		status int
	}{{`{"path":"` + filepath.Join(filepath.Dir(path), "missing.mkv") + `"}`, 404}, {`{"path":"` + filepath.Join(filepath.Dir(path), "note.txt") + `"}`, 400}, {`{`, 400}} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodPost, "/api/v1/local", bytes.NewBufferString(tc.body))
		req.Header.Set("Content-Type", "application/json")
		h.ServeHTTP(rec, req)
		if rec.Code != tc.status {
			t.Errorf("body=%s status=%d", tc.body, rec.Code)
		}
	}
}
func TestLocalMissingService(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New(Deps{}, log).Handler()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/v1/local", bytes.NewBufferString(`{"path":"/tmp/a.mkv"}`)))
	if rec.Code != 503 {
		t.Fatalf("status=%d", rec.Code)
	}
}
func TestLoopbackHostGuard(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	for _, tc := range []struct {
		addr, host string
		status     int
	}{{"127.0.0.1:7666", "evil.example:7666", 403}, {"localhost:7666", "[::1]:7666", 200}, {"[::1]:7666", "127.0.0.1:1234", 200}, {"127.0.0.1:7666", "[::1]", 200}, {"0.0.0.0:7666", "evil.example", 200}} {
		h := New(Deps{Addr: tc.addr}, log).Handler()
		req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
		req.Host = tc.host
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != tc.status {
			t.Errorf("addr=%s host=%s status=%d", tc.addr, tc.host, rec.Code)
		}
	}
}

// A download request names a copy; a file on this machine is not one it can
// name, or the API would read any file this user can.
func TestDownloadRequestCannotNameALocalFile(t *testing.T) {
	h, _, _ := localAPI(t)
	secret := filepath.Join(t.TempDir(), "secret")
	if err := os.WriteFile(secret, []byte("password"), 0o600); err != nil {
		t.Fatal(err)
	}
	body := `{"source":{"locator":{"scheme":"file","path":"` + secret + `"}}}`
	req := httptest.NewRequest(http.MethodPost, "/api/v1/downloads", bytes.NewBufferString(body))
	req.Host = "localhost:7666"
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code < 400 {
		t.Fatalf("a local file named in a request was started: %d %s", rec.Code, rec.Body)
	}
}

// A page on another site can make a browser send requests here; one that
// would change something is refused whatever its content type, and reads
// and the client's own requests (no browser headers) go through.
func TestCrossSiteBrowserRequestsAreRefused(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New(Deps{Addr: "127.0.0.1:7666"}, log).Handler()
	for _, tc := range []struct {
		name, method string
		header       map[string]string
		refused      bool
	}{
		{"fetch from another site", http.MethodPost, map[string]string{"Sec-Fetch-Site": "cross-site"}, true},
		{"form from another origin", http.MethodPost, map[string]string{"Origin": "https://evil.example"}, true},
		{"delete from another site", http.MethodDelete, map[string]string{"Sec-Fetch-Site": "cross-site"}, true},
		{"the client", http.MethodPost, nil, false},
		{"a cross-site read", http.MethodGet, map[string]string{"Sec-Fetch-Site": "cross-site"}, false},
	} {
		req := httptest.NewRequest(tc.method, "/api/v1/local", bytes.NewBufferString(`{"path":"/tmp/a.mkv"}`))
		req.Host = "127.0.0.1:7666"
		for k, v := range tc.header {
			req.Header.Set(k, v)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if refused := rec.Code == http.StatusForbidden; refused != tc.refused {
			t.Errorf("%s: status %d, refused %v, want %v", tc.name, rec.Code, refused, tc.refused)
		}
	}
}

func TestLocalSourcesAndStorage(t *testing.T) {
	h, manager, path := localAPI(t)
	_ = h
	item := severance()
	ctx := context.Background()
	d, err := manager.OpenLocal(ctx, acquire.Request{ItemID: item.ID, Season: 2, Episode: 3, Source: sources.MediaSource{RawName: "Severance.S02E03.mkv", Size: 128 << 10, Locator: sources.Locator{Scheme: "file", Path: path}}})
	if err != nil {
		t.Fatal(err)
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: item}, log)
	provider := &recordingSubtitles{}
	subs := subtitles.NewService(func() []subtitles.Provider { return []subtitles.Provider{provider} }, nil, log)
	api := New(Deps{Downloads: manager, Catalog: cat, Subtitles: subs, CacheDir: t.TempDir()}, log).Handler()
	rec := httptest.NewRecorder()
	api.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/sources?item="+item.ID+"&season=2&episode=3", nil))
	if rec.Code != 200 {
		t.Fatalf("sources status=%d body=%s", rec.Code, rec.Body)
	}
	var found struct {
		Sources []sources.MediaSource `json:"sources"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &found); err != nil {
		t.Fatal(err)
	}
	if len(found.Sources) != 1 || found.Sources[0].ProviderID != "local" || found.Sources[0].Tracker != "This computer" || found.Sources[0].Locator.Path != path {
		t.Fatalf("sources=%+v", found.Sources)
	}
	rec = httptest.NewRecorder()
	api.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/subtitles?item="+item.ID+"&download="+d.ID, nil))
	if rec.Code != http.StatusOK || provider.got.VideoHash == "" || provider.got.IMDbID != item.IMDbID() {
		t.Fatalf("subtitles status=%d query=%+v", rec.Code, provider.got)
	}
	rec = httptest.NewRecorder()
	api.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/storage", nil))
	if rec.Code != 200 {
		t.Fatalf("storage status=%d body=%s", rec.Code, rec.Body)
	}
	var storage storageResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &storage); err != nil {
		t.Fatal(err)
	}
	if storage.Used != 0 || len(storage.Titles) != 0 {
		t.Fatalf("storage=%+v", storage)
	}
	rec = httptest.NewRecorder()
	api.ServeHTTP(rec, httptest.NewRequest(http.MethodDelete, "/api/v1/storage", nil))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("clear storage status=%d body=%s", rec.Code, rec.Body)
	}
	if _, err := manager.Get(ctx, d.ID); err != nil {
		t.Fatalf("local row cleared with storage: %v", err)
	}
	if err := manager.Remove(ctx, d.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("user file missing: %v", err)
	}
}
