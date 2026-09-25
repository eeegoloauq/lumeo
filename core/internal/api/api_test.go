package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/egress"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// The API's own job is routing and translation — our ids in, IMDb ids out —
// so the catalog behind it is a stub with one item in it.
type stubStore struct{ item catalog.MediaItem }

func (s *stubStore) UpsertItems(_ context.Context, _ string, items []catalog.MediaItem, _ bool) ([]catalog.MediaItem, error) {
	return items, nil
}
func (s *stubStore) Item(_ context.Context, id string) (catalog.MediaItem, catalog.ItemState, error) {
	if id != s.item.ID {
		return catalog.MediaItem{}, catalog.ItemState{}, nil
	}
	return s.item, catalog.ItemState{Found: true, Detailed: true, UpdatedAt: time.Now()}, nil
}
func (s *stubStore) ItemsByIDs(_ context.Context, ids []string) ([]catalog.MediaItem, error) {
	var items []catalog.MediaItem
	for _, id := range ids {
		if id == s.item.ID {
			items = append(items, s.item)
		}
	}
	return items, nil
}
func (s *stubStore) SavePage(context.Context, string, []string) error { return nil }
func (s *stubStore) Page(context.Context, string) ([]string, time.Time, error) {
	return nil, time.Time{}, nil
}

type stubMeta struct{}

func (stubMeta) ID() string        { return "meta" }
func (stubMeta) Name() string      { return "meta" }
func (stubMeta) Namespace() string { return catalog.NamespaceIMDb }
func (stubMeta) Rows(context.Context) ([]catalog.Row, error) {
	return nil, nil
}
func (stubMeta) Browse(context.Context, catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	return nil, nil
}
func (stubMeta) Meta(context.Context, catalog.Kind, string) (*catalog.MediaItem, error) {
	return nil, nil
}

// recordingSource remembers the query it was asked, which is what the item ->
// IMDb translation has to get right.
type recordingSource struct{ got sources.Query }

func (r *recordingSource) ID() string   { return "src" }
func (r *recordingSource) Name() string { return "src" }
func (r *recordingSource) Find(_ context.Context, q sources.Query) ([]sources.MediaSource, error) {
	r.got = q
	return []sources.MediaSource{{ProviderID: "src", RawName: "Severance.S02E03.1080p"}}, nil
}

func testServer(item catalog.MediaItem, src sources.Provider) http.Handler {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: item}, log)
	return New(Deps{Sources: func() []sources.Provider { return []sources.Provider{src} }, Catalog: cat}, log).Handler()
}

func severance() catalog.MediaItem {
	return catalog.MediaItem{
		ID:          "abc123",
		Kind:        catalog.KindSeries,
		Title:       "Severance",
		ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt11280740"},
	}
}

func TestSourcesTranslatesOurIDToIMDb(t *testing.T) {
	src := &recordingSource{}
	h := testServer(severance(), src)

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/sources?item=abc123&season=2&episode=3", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if src.got.IMDbID != "tt11280740" || src.got.Kind != catalog.KindSeries {
		t.Errorf("provider asked for %+v", src.got)
	}
	if src.got.Season != 2 || src.got.Episode != 3 {
		t.Errorf("episode lost: %+v", src.got)
	}
	var body struct {
		Sources []sources.MediaSource `json:"sources"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Sources) != 1 {
		t.Errorf("got %d sources", len(body.Sources))
	}
}

func TestSourcesStillAcceptsIMDbDirectly(t *testing.T) {
	src := &recordingSource{}
	h := testServer(severance(), src)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/sources?imdb=tt0133093", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if src.got.IMDbID != "tt0133093" || src.got.Kind != catalog.KindMovie {
		t.Errorf("provider asked for %+v", src.got)
	}
}

func TestSourcesWithoutAnyID(t *testing.T) {
	rec := httptest.NewRecorder()
	testServer(severance(), &recordingSource{}).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/sources", nil))
	if rec.Code != http.StatusBadRequest {
		t.Errorf("status %d, want 400", rec.Code)
	}
}

func TestUnknownItem(t *testing.T) {
	rec := httptest.NewRecorder()
	testServer(severance(), &recordingSource{}).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/items/nope", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status %d, want 404", rec.Code)
	}
}

// A core without a catalog service is a supported configuration: sources
// still work, the catalog endpoints say plainly that there is nothing behind
// them.
func TestCatalogEndpointsWithoutProvider(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New(Deps{}, log).Handler()
	for _, path := range []string{"/api/v1/catalogs", "/api/v1/catalog?id=top", "/api/v1/search?q=x", "/api/v1/items/abc"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s: status %d, want 503", path, rec.Code)
		}
	}
}

type refusingSource struct{ err error }

func (refusingSource) ID() string   { return "torrentio" }
func (refusingSource) Name() string { return "Torrentio" }
func (r refusingSource) Find(context.Context, sources.Query) ([]sources.MediaSource, error) {
	return nil, r.err
}

// A provider that refuses must not read as a film nobody has: the answer
// keeps the other providers' copies and says who refused and how.
func TestSourcesNamesProvidersThatFailed(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: severance()}, log)
	providers := []sources.Provider{
		refusingSource{&egress.StatusError{Provider: "torrentio", Status: "403 Forbidden", Code: 403}},
		&recordingSource{},
		refusingSource{context.DeadlineExceeded},
	}
	h := New(Deps{Sources: func() []sources.Provider { return providers }, Catalog: cat}, log).Handler()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/sources?imdb=tt0133093", nil))

	var body struct {
		Sources   []sources.MediaSource `json:"sources"`
		Failed    []failedProvider      `json:"failed"`
		Providers int                   `json:"providers"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.Providers != 3 {
		t.Errorf("providers = %d, want the 3 asked", body.Providers)
	}
	if len(body.Sources) != 1 {
		t.Errorf("got %d sources, want the working provider's one", len(body.Sources))
	}
	want := []failedProvider{{"Torrentio", "403 Forbidden", 403}, {"Torrentio", "no answer", 0}}
	if !slices.Equal(body.Failed, want) {
		t.Errorf("failed = %+v, want %+v", body.Failed, want)
	}
}
