package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

type artworkMeta struct{ item catalog.MediaItem }

func (artworkMeta) ID() string                                  { return "art" }
func (artworkMeta) Name() string                                { return "Art" }
func (artworkMeta) Namespace() string                           { return catalog.NamespaceIMDb }
func (artworkMeta) Rows(context.Context) ([]catalog.Row, error) { return nil, nil }
func (m artworkMeta) Browse(context.Context, catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	return []catalog.MediaItem{m.item}, nil
}
func (m artworkMeta) Meta(context.Context, catalog.Kind, string) (*catalog.MediaItem, error) {
	return &m.item, nil
}

func artworkServer(t *testing.T, item catalog.MediaItem) (http.Handler, *store.DB, string) {
	t.Helper()
	return artworkServerWithToken(t, item, "")
}

func artworkServerWithToken(t *testing.T, item catalog.MediaItem, token string) (http.Handler, *store.DB, string) {
	t.Helper()
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "lumeo.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(artworkMeta{item}), db, log)
	t.Cleanup(cat.Close)
	srv := New(Deps{Catalog: cat, Artwork: db, CacheDir: dir, Token: token}, log)
	t.Cleanup(srv.Close)
	return srv.Handler(), db, dir
}

func artRequest(t *testing.T, h http.Handler, method, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, nil)
	req.Host = "localhost:7666"
	h.ServeHTTP(rec, req)
	return rec
}

func TestArtworkRewritesItemsAndCachesFetch(t *testing.T) {
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("\x89PNG\r\n\x1a\nart"))
	}))
	defer upstream.Close()
	item := catalog.MediaItem{Kind: catalog.KindSeries, Title: "Film", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt123"}, Poster: upstream.URL + "/poster", Background: upstream.URL + "/background", Logo: upstream.URL + "/logo", Episodes: []catalog.Episode{{Season: 1, Number: 1, Thumbnail: upstream.URL + "/thumb"}}}
	h, db, _ := artworkServer(t, item)
	page := artRequest(t, h, http.MethodGet, "/api/v1/catalog?id=top")
	if page.Code != http.StatusOK {
		t.Fatalf("catalog: %d %s", page.Code, page.Body)
	}
	var body struct {
		Items []catalog.MediaItem `json:"items"`
	}
	if err := json.Unmarshal(page.Body.Bytes(), &body); err != nil || len(body.Items) != 1 {
		t.Fatalf("catalog body: %v %s", err, page.Body)
	}
	got := body.Items[0]
	stored, _, err := db.Item(context.Background(), got.ID)
	if err != nil || stored.Poster != item.Poster || stored.Episodes[0].Thumbnail != item.Episodes[0].Thumbnail {
		t.Fatalf("stored metadata changed: %+v, err %v", stored, err)
	}
	detail := artRequest(t, h, http.MethodGet, "/api/v1/items/"+got.ID)
	var detailed catalog.MediaItem
	if detail.Code != 200 || json.Unmarshal(detail.Body.Bytes(), &detailed) != nil || len(detailed.Episodes) != 1 || detailed.Poster != got.Poster || detailed.Episodes[0].Thumbnail != got.Episodes[0].Thumbnail {
		t.Fatalf("item detail not rewritten: %d %s", detail.Code, detail.Body)
	}
	for _, image := range []string{got.Poster, got.Background, got.Logo, got.Episodes[0].Thumbnail} {
		if !strings.HasPrefix(image, "http://localhost:7666/api/v1/artwork/") {
			t.Fatalf("unrewritten image: %s", image)
		}
	}
	first := artRequest(t, h, http.MethodGet, got.Poster)
	second := artRequest(t, h, http.MethodGet, got.Poster)
	if first.Code != 200 || second.Code != 200 || first.Header().Get("Cache-Control") != "private, max-age=31536000, immutable" || hits.Load() != 1 {
		t.Fatalf("cache: statuses %d/%d, hits %d, headers %v", first.Code, second.Code, hits.Load(), first.Header())
	}
	if got.Poster == item.Poster {
		t.Fatal("stored metadata was not rewritten")
	}
	unknown := artRequest(t, h, http.MethodGet, "/api/v1/artwork/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	if unknown.Code != http.StatusNotFound {
		t.Fatalf("unknown key: %d", unknown.Code)
	}
}

func TestArtworkFailuresAndClear(t *testing.T) {
	var missingHits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/missing" {
			missingHits.Add(1)
			http.NotFound(w, r)
			return
		}
		if r.URL.Path == "/spoof" {
			w.Header().Set("Content-Type", "image/png")
			_, _ = w.Write([]byte("<script>alert(1)</script>"))
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("not an image"))
	}))
	defer upstream.Close()
	item := catalog.MediaItem{Kind: catalog.KindMovie, Title: "Film", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt456"}, Poster: upstream.URL + "/missing", Logo: upstream.URL + "/text", Background: upstream.URL + "/spoof"}
	h, db, dir := artworkServer(t, item)
	page := artRequest(t, h, http.MethodGet, "/api/v1/catalog?id=top")
	var body struct {
		Items []catalog.MediaItem `json:"items"`
	}
	if err := json.Unmarshal(page.Body.Bytes(), &body); err != nil || len(body.Items) != 1 {
		t.Fatalf("catalog body: %v %s", err, page.Body)
	}
	missing, invalid := body.Items[0].Poster, body.Items[0].Logo
	for i := 0; i < 2; i++ {
		if got := artRequest(t, h, http.MethodGet, missing).Code; got != 404 {
			t.Fatalf("missing status: %d", got)
		}
	}
	if missingHits.Load() != 1 || artRequest(t, h, http.MethodGet, invalid).Code != 502 {
		t.Fatalf("missing hits %d or non-image accepted", missingHits.Load())
	}
	if got := artRequest(t, h, http.MethodGet, body.Items[0].Background).Code; got != 502 {
		t.Fatalf("spoofed image status: %d", got)
	}
	key := strings.TrimPrefix(missing, "http://localhost:7666/api/v1/artwork/")
	_, until, err := db.Artwork(context.Background(), key)
	if err != nil || until <= time.Now().Unix() {
		t.Fatalf("missing_until = %d, err %v", until, err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "artwork"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "artwork", key), []byte("cached"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := artRequest(t, h, http.MethodDelete, "/api/v1/cache").Code; got != 204 {
		t.Fatalf("clear status: %d", got)
	}
	_, until, err = db.Artwork(context.Background(), key)
	if err != nil || until != 0 {
		t.Fatalf("reset missing_until = %d, err %v", until, err)
	}
	if size, err := os.Stat(filepath.Join(dir, "artwork", key)); err == nil {
		t.Fatalf("cached file remains: %+v", size)
	}
	if got := artRequest(t, h, http.MethodGet, missing).Code; got != 404 || missingHits.Load() != 2 {
		t.Fatalf("retry status %d, hits %d", got, missingHits.Load())
	}
}

func TestArtworkEvictsOldestFile(t *testing.T) {
	oldLimit := artworkLimit
	artworkLimit = 12
	t.Cleanup(func() { artworkLimit = oldLimit })
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("\x89PNG\r\n\x1a\n"))
	}))
	defer upstream.Close()
	h, db, dir := artworkServer(t, catalog.MediaItem{})
	urls := map[string]string{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": upstream.URL + "/old", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": upstream.URL + "/new"}
	if err := db.RegisterArtwork(context.Background(), urls); err != nil {
		t.Fatal(err)
	}
	oldPath := filepath.Join(dir, "artwork", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	newPath := filepath.Join(dir, "artwork", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	if got := artRequest(t, h, http.MethodGet, "/api/v1/artwork/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").Code; got != 200 {
		t.Fatalf("old status: %d", got)
	}
	oldTime := time.Now().Add(-time.Hour)
	if err := os.Chtimes(oldPath, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}
	if got := artRequest(t, h, http.MethodGet, "/api/v1/artwork/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").Code; got != 200 {
		t.Fatalf("new status: %d", got)
	}
	if _, err := os.Stat(oldPath); !os.IsNotExist(err) {
		t.Fatalf("old file still present: %v", err)
	}
	if _, err := os.Stat(newPath); err != nil {
		t.Fatalf("new file missing: %v", err)
	}
	if size, err := (&Server{cacheDir: dir}).artworkSize(); err != nil || size != 8 {
		t.Fatalf("cache size = %d, err %v", size, err)
	}
}

func TestArtworkFetchOutlivesTheClient(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		cancel() // the client scrolls past while the image is on its way
		time.Sleep(50 * time.Millisecond)
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("\x89PNG\r\n\x1a\n"))
	}))
	defer upstream.Close()
	h, db, dir := artworkServer(t, catalog.MediaItem{})
	key := "cccccccccccccccccccccccccccccccc"
	if err := db.RegisterArtwork(context.Background(), map[string]string{key: upstream.URL + "/still"}); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/api/v1/artwork/"+key, nil).WithContext(ctx)
	req.Host = "localhost:7666"
	h.ServeHTTP(httptest.NewRecorder(), req)
	// The next tile showing it joins the fetch still running, or reads what
	// it left; either way the image is fetched once.
	if got := artRequest(t, h, http.MethodGet, "/api/v1/artwork/"+key); got.Code != http.StatusOK {
		t.Fatalf("second request: %d %s", got.Code, got.Body)
	}
	if hits.Load() != 1 {
		t.Fatalf("image fetched %d times, want 1", hits.Load())
	}
	if _, err := os.Stat(filepath.Join(dir, "artwork", key)); err != nil {
		t.Fatalf("a request its client abandoned left nothing in the cache: %v", err)
	}
}

func TestArtworkServesTheFallbackOfAMissingStill(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/missing" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("\x89PNG\r\n\x1a\n" + r.URL.Path))
	}))
	defer upstream.Close()
	item := catalog.MediaItem{Kind: catalog.KindSeries, Title: "Show", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt789"}, Episodes: []catalog.Episode{
		{Season: 2, Number: 1, Thumbnail: upstream.URL + "/missing", ThumbnailFallback: upstream.URL + "/fallback"},
		{Season: 2, Number: 2, Thumbnail: upstream.URL + "/present", ThumbnailFallback: upstream.URL + "/unused"},
	}}
	h, _, _ := artworkServer(t, item)
	page := artRequest(t, h, http.MethodGet, "/api/v1/catalog?id=top")
	var body struct {
		Items []catalog.MediaItem `json:"items"`
	}
	if err := json.Unmarshal(page.Body.Bytes(), &body); err != nil || len(body.Items) != 1 {
		t.Fatalf("catalog body: %v %s", err, page.Body)
	}
	for i, want := range []string{"/fallback", "/present"} {
		e := body.Items[0].Episodes[i]
		if e.ThumbnailFallback != "" || !strings.Contains(e.Thumbnail, "?or=") {
			t.Fatalf("episode %d sent as %+v", i, e)
		}
		got := artRequest(t, h, http.MethodGet, e.Thumbnail)
		if got.Code != http.StatusOK || !strings.HasSuffix(got.Body.String(), want) {
			t.Fatalf("episode %d: %d %q, want %s", i, got.Code, got.Body, want)
		}
	}
}

// An addon's image is a web address or nothing: file:, data: and javascript:
// are not passed on for a client to interpret.
func TestArtworkDropsWhatIsNotAWebAddress(t *testing.T) {
	item := catalog.MediaItem{Kind: catalog.KindMovie, Title: "Film", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt1"},
		Poster: "file:///etc/passwd", Background: "javascript:alert(1)", Logo: "data:image/png;base64,AAAA"}
	h, _, _ := artworkServer(t, item)
	page := artRequest(t, h, http.MethodGet, "/api/v1/catalog?id=top")
	var body struct {
		Items []catalog.MediaItem `json:"items"`
	}
	if err := json.Unmarshal(page.Body.Bytes(), &body); err != nil || len(body.Items) != 1 {
		t.Fatalf("catalog body: %v %s", err, page.Body)
	}
	if got := body.Items[0]; got.Poster != "" || got.Background != "" || got.Logo != "" {
		t.Fatalf("passed on: %+v", got)
	}
}
