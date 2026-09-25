package stremio

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/egress"
)

func TestParseReleaseInfo(t *testing.T) {
	cases := []struct {
		in            string
		year, yearEnd int
	}{
		{"1999", 1999, 0},
		{"2015-2019", 2015, 2019},
		{"2015–2019", 2015, 2019}, // en dash, as Cinemeta ships it
		{"2015-", 2015, 0},
		{"2015–", 2015, 0},
		{"", 0, 0},
	}
	for _, c := range cases {
		year, yearEnd := parseReleaseInfo(c.in)
		if year != c.year || yearEnd != c.yearEnd {
			t.Errorf("parseReleaseInfo(%q) = %d, %d; want %d, %d", c.in, year, yearEnd, c.year, c.yearEnd)
		}
	}
}

func TestRowsFromManifest(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/manifest.json" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("User-Agent") != egress.UserAgent {
			t.Errorf("User-Agent: %q", r.Header.Get("User-Agent"))
		}
		hits++
		io.WriteString(w, `{
			"id": "com.linvo.cinemeta",
			"resources": ["catalog", {"name": "meta", "types": ["movie", "series"]}],
			"catalogs": [
				{
					"type": "movie",
					"id": "top",
					"name": "Popular",
					"extra": [
						{"name": "genre", "options": ["Action", "Comedy"]},
						{"name": "search"},
						{"name": "skip"}
					],
					"extraSupported": ["search", "genre", "skip"]
				},
				{
					"type": "series",
					"id": "year",
					"name": "New",
					"genres": ["2024", "2023"],
					"extraSupported": ["genre", "skip"]
				}
			]
		}`)
	}))
	defer srv.Close()

	a := New("cinemeta", "Cinemeta", srv.URL)
	rows, err := a.Rows(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 2 {
		t.Fatalf("rows: %d", len(rows))
	}
	m, _ := a.Manifest(context.Background())
	if !m.Provides("catalog") || !m.Provides("meta") || m.Provides("stream") {
		t.Errorf("resources: %v — a resource written as an object counts like one written as a name", m.Resources)
	}
	if rows[0].ProviderID != "cinemeta" || rows[0].ID != "top" || rows[0].Kind != catalog.KindMovie || rows[0].Name != "Popular" {
		t.Errorf("row 0: %+v", rows[0])
	}
	if !rows[0].Searchable {
		t.Error("top should be searchable")
	}
	if got := strings.Join(rows[0].Genres, ","); got != "Action,Comedy" {
		t.Errorf("genres: %q", got)
	}
	if rows[1].Searchable {
		t.Error("year catalog is not searchable")
	}
	if got := strings.Join(rows[1].Genres, ","); got != "2024,2023" {
		t.Errorf("legacy genres: %q", got)
	}

	if _, err := a.Rows(context.Background()); err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Errorf("manifest fetched %d times, want cache hit", hits)
	}
}

func TestRowsEmptyCatalogs(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, `{"id":"com.stremio.torrentio.addon","catalogs":[],"resources":[{"name":"stream"}]}`)
	}))
	defer srv.Close()

	a := New("torrentio", "Torrentio", srv.URL)
	rows, err := a.Rows(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 0 {
		t.Errorf("got %d rows", len(rows))
	}
}

func TestBrowseBuildsExtraPath(t *testing.T) {
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		paths = append(paths, r.URL.RequestURI())
		io.WriteString(w, `{
			"metas": [{
				"id": "tt0133093",
				"type": "movie",
				"name": "The Matrix",
				"description": "A hacker.",
				"poster": "https://example/poster",
				"background": "https://example/bg",
				"logo": "https://example/logo",
				"genres": ["Action", "Sci-Fi"],
				"cast": ["Keanu Reeves"],
				"director": ["Lana Wachowski", "Lilly Wachowski"],
				"runtime": "136 min",
				"imdbRating": "8.7",
				"moviedb_id": 603,
				"releaseInfo": "1999"
			}]
		}`)
	}))
	defer srv.Close()

	a := New("cinemeta", "Cinemeta", srv.URL)
	ctx := context.Background()

	items, err := a.Browse(ctx, catalog.BrowseRequest{Kind: catalog.KindMovie, CatalogID: "top"})
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("items: %d", len(items))
	}
	it := items[0]
	if it.ID != "" {
		t.Errorf("ID should stay empty, got %q", it.ID)
	}
	if it.Title != "The Matrix" || it.Year != 1999 || it.YearEnd != 0 {
		t.Errorf("title/year: %+v", it)
	}
	if it.IMDbRating != 8.7 {
		t.Errorf("rating: %v", it.IMDbRating)
	}
	if it.ExternalIDs[catalog.NamespaceIMDb] != "tt0133093" {
		t.Errorf("imdb: %v", it.ExternalIDs)
	}
	if it.ExternalIDs[catalog.NamespaceTMDB] != "603" {
		t.Errorf("tmdb: %v", it.ExternalIDs)
	}
	if it.Runtime != "136 min" || it.Overview != "A hacker." {
		t.Errorf("copy fields: %+v", it)
	}
	if len(it.Directors) != 2 {
		t.Errorf("directors: %v", it.Directors)
	}

	if _, err := a.Browse(ctx, catalog.BrowseRequest{
		Kind: catalog.KindMovie, CatalogID: "top", Genre: "Action", Skip: 100,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Browse(ctx, catalog.BrowseRequest{
		Kind: catalog.KindMovie, CatalogID: "top", Search: "game of thrones",
	}); err != nil {
		t.Fatal(err)
	}

	want := []string{
		"/catalog/movie/top.json",
		"/catalog/movie/top/genre=Action&skip=100.json",
		"/catalog/movie/top/search=game%20of%20thrones.json",
	}
	if len(paths) != len(want) {
		t.Fatalf("paths: %v", paths)
	}
	for i := range want {
		if paths[i] != want[i] {
			t.Errorf("path %d: got %s want %s", i, paths[i], want[i])
		}
	}
}

func TestMetaSeriesEpisodes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/meta/series/tt0903747.json" {
			t.Errorf("path: %s", r.URL.Path)
		}
		io.WriteString(w, `{
			"meta": {
				"id": "tt0903747",
				"type": "series",
				"name": "Breaking Bad",
				"description": "A chemistry teacher.",
				"runtime": "49 min",
				"imdbRating": "9.5",
				"moviedb_id": 1396,
				"tvdb_id": 81189,
				"director": null,
				"releaseInfo": "2008–2013",
				"cast": ["Bryan Cranston"],
				"genres": ["Crime", "Drama"],
				"videos": [
					{"name": "Grilled", "season": 2, "episode": 2, "number": 2, "overview": "Tuco", "thumbnail": "t2", "released": "2009-03-16T05:00:00.000Z", "firstAired": "2009-03-16T05:00:00.000Z"},
					{"name": "Pilot", "season": 1, "episode": 1, "number": 1, "overview": "Cancer", "thumbnail": "t1", "released": "2008-01-21T05:00:00.000Z"},
					{"name": "Good Cop", "season": 0, "episode": 1, "number": 1, "overview": "Valentine", "thumbnail": "t0", "released": "", "firstAired": ""},
					{"name": "Cat's in the Bag...", "season": 1, "episode": 2, "number": 2, "overview": "Coin", "thumbnail": "t1b", "released": "2008-01-28T05:00:00.000Z"}
				]
			}
		}`)
	}))
	defer srv.Close()

	a := New("cinemeta", "Cinemeta", srv.URL)
	item, err := a.Meta(context.Background(), catalog.KindSeries, "tt0903747")
	if err != nil {
		t.Fatal(err)
	}
	if item.ID != "" {
		t.Errorf("ID: %q", item.ID)
	}
	if item.Title != "Breaking Bad" || item.Year != 2008 || item.YearEnd != 2013 {
		t.Errorf("title/years: %+v", item)
	}
	if item.IMDbRating != 9.5 {
		t.Errorf("rating: %v", item.IMDbRating)
	}
	if item.ExternalIDs[catalog.NamespaceIMDb] != "tt0903747" {
		t.Errorf("imdb: %v", item.ExternalIDs)
	}
	if item.ExternalIDs[catalog.NamespaceTMDB] != "1396" || item.ExternalIDs[catalog.NamespaceTVDB] != "81189" {
		t.Errorf("ids: %v", item.ExternalIDs)
	}
	if len(item.Directors) != 0 {
		t.Errorf("director null: %v", item.Directors)
	}
	if len(item.Episodes) != 4 {
		t.Fatalf("episodes: %d", len(item.Episodes))
	}
	order := [][2]int{{0, 1}, {1, 1}, {1, 2}, {2, 2}}
	for i, want := range order {
		if item.Episodes[i].Season != want[0] || item.Episodes[i].Number != want[1] {
			t.Errorf("ep %d: S%dE%d, want S%dE%d", i, item.Episodes[i].Season, item.Episodes[i].Number, want[0], want[1])
		}
	}
	if !item.Episodes[0].Released.IsZero() {
		t.Errorf("empty released should stay zero, got %v", item.Episodes[0].Released)
	}
	wantReleased := time.Date(2008, 1, 21, 5, 0, 0, 0, time.UTC)
	if !item.Episodes[1].Released.Equal(wantReleased) {
		t.Errorf("pilot released: %v", item.Episodes[1].Released)
	}
}

func TestHTTPErrorIncludesAddonID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	a := New("cinemeta", "Cinemeta", srv.URL)
	_, err := a.Meta(context.Background(), catalog.KindMovie, "tt0133093")
	if err == nil || !strings.Contains(err.Error(), "cinemeta") {
		t.Errorf("error %v should name the addon", err)
	}
}

func TestNamespace(t *testing.T) {
	a := New("cinemeta", "Cinemeta", "https://example.invalid")
	if a.Namespace() != catalog.NamespaceIMDb {
		t.Errorf("namespace: %s", a.Namespace())
	}
}

func TestMetaObjectUnmarshalTolerant(t *testing.T) {
	raw := []byte(`{
		"id": "tt1",
		"type": "movie",
		"name": "X",
		"imdbRating": "",
		"director": "One Person",
		"moviedb_id": "42",
		"tvdb_id": null
	}`)
	var m metaObject
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	item := m.toItem(false)
	if item.IMDbRating != 0 {
		t.Errorf("empty rating: %v", item.IMDbRating)
	}
	if len(item.Directors) != 1 || item.Directors[0] != "One Person" {
		t.Errorf("director string: %v", item.Directors)
	}
	if item.ExternalIDs[catalog.NamespaceTMDB] != "42" {
		t.Errorf("tmdb string: %v", item.ExternalIDs)
	}
	if _, ok := item.ExternalIDs[catalog.NamespaceTVDB]; ok {
		t.Errorf("null tvdb should be omitted: %v", item.ExternalIDs)
	}
}

func TestSeasonOneStills(t *testing.T) {
	still := func(season, episode int) string {
		return fmt.Sprintf("https://episodes.metahub.space/tt5607616/%d/%d/w780.jpg", season, episode)
	}
	episodes := []catalog.Episode{
		{Season: 0, Number: 1, Thumbnail: still(0, 1)},
		{Season: 1, Number: 1, Thumbnail: still(1, 1)},
		{Season: 1, Number: 2, Thumbnail: still(1, 2)},
		{Season: 2, Number: 1, Thumbnail: still(2, 1)},
		{Season: 3, Number: 1, Thumbnail: "https://example.com/3/1/w780.jpg"},
		{Season: 3, Number: 2, Thumbnail: still(3, 2)},
	}
	seasonOneStills(episodes)
	want := []string{"", "", "", still(1, 3), "", still(1, 5)}
	for i, e := range episodes {
		if e.ThumbnailFallback != want[i] {
			t.Errorf("S%dE%d fallback = %q, want %q", e.Season, e.Number, e.ThumbnailFallback, want[i])
		}
	}
}

// An addon's answer is bounded: one that streams a gigabyte of manifest must
// cost an error, not the machine's memory.
func TestAnswerLargerThanTheLimitIsRefused(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, `{"id":"org.example","description":"`)
		chunk := strings.Repeat("x", 1<<20)
		for range maxResponse>>20 + 1 {
			if _, err := io.WriteString(w, chunk); err != nil {
				return
			}
		}
		_, _ = io.WriteString(w, `"}`)
	}))
	defer srv.Close()
	_, err := New("big", "Big", srv.URL).RefreshManifest(context.Background())
	if _, ok := errors.AsType[*http.MaxBytesError](err); !ok {
		t.Fatalf("got %v, want the answer refused for its size", err)
	}
}
