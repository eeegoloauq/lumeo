package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/watchlist"
)

// libraryServer is the library routes over a real database, which is also
// the catalogue's cache, holding one series whose latest episode came out
// yesterday. It returns the id the store minted for it.
func libraryServer(t *testing.T) (http.Handler, string) {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	yesterday := time.Now().UTC().Truncate(24*time.Hour).AddDate(0, 0, -1)
	saved, err := db.UpsertItems(context.Background(), catalog.NamespaceIMDb, []catalog.MediaItem{{
		Kind: catalog.KindSeries, Title: "Series",
		ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt1"},
		Episodes: []catalog.Episode{
			{Season: 1, Number: 1, Title: "Pilot", Released: yesterday.AddDate(0, 0, -7)},
			{Season: 1, Number: 2, Title: "Second", Released: yesterday},
		},
	}}, true)
	if err != nil {
		t.Fatalf("store the series: %v", err)
	}
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), db, log)
	t.Cleanup(cat.Close)
	watched := progress.New(db, cat)
	scores := ratings.New(db, cat)
	return New(Deps{
		Catalog:   cat,
		Progress:  watched,
		Ratings:   scores,
		Watchlist: watchlist.New(db, cat, db, scores),
	}, log).Handler(), saved[0].ID
}

func decode[T any](t *testing.T, h http.Handler, method, path, body string, status int) T {
	t.Helper()
	rec := requestJSON(t, h, method, path, body)
	if rec.Code != status {
		t.Fatalf("%s %s: status %d, want %d: %s", method, path, rec.Code, status, rec.Body)
	}
	var out T
	if status != http.StatusNoContent {
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatalf("%s %s: decode: %v", method, path, err)
		}
	}
	return out
}

type listStateBody struct {
	InList  bool      `json:"inList"`
	AddedAt time.Time `json:"addedAt"`
}

func TestListRoutes(t *testing.T) {
	h, id := libraryServer(t)
	if got := decode[listStateBody](t, h, http.MethodGet, "/api/v1/list/"+id, "", http.StatusOK); got.InList {
		t.Fatalf("on the list before it was added: %+v", got)
	}
	decode[struct{}](t, h, http.MethodPut, "/api/v1/list/nobody", "", http.StatusNotFound)
	added := decode[listStateBody](t, h, http.MethodPut, "/api/v1/list/"+id, "", http.StatusOK)
	if !added.InList || added.AddedAt.IsZero() {
		t.Fatalf("add = %+v", added)
	}
	decode[ratings.Rating](t, h, http.MethodPut, "/api/v1/ratings/"+id, `{"rating":8}`, http.StatusOK)
	decode[progress.Entry](t, h, http.MethodPut, "/api/v1/progress/"+id,
		`{"season":1,"episode":1,"position":1400,"duration":1500}`, http.StatusOK)

	list := decode[struct {
		Items []watchlist.Listed `json:"items"`
	}](t, h, http.MethodGet, "/api/v1/list", "", http.StatusOK)
	if len(list.Items) != 1 {
		t.Fatalf("list = %+v", list)
	}
	got := list.Items[0]
	if got.Item.ID != id || got.Rating != 8 || got.Seen != (watchlist.Seen{Watched: 1, Released: 2}) || len(got.Item.Episodes) != 0 {
		t.Fatalf("listed = %+v", got)
	}

	decode[struct{}](t, h, http.MethodDelete, "/api/v1/list/"+id, "", http.StatusNoContent)
	if got := decode[listStateBody](t, h, http.MethodGet, "/api/v1/list/"+id, "", http.StatusOK); got.InList {
		t.Fatalf("still on the list: %+v", got)
	}
}

func TestRatingRoutes(t *testing.T) {
	h, id := libraryServer(t)
	for _, body := range []string{`{"rating":0}`, `{"rating":11}`, `{"season":1,"rating":5}`} {
		decode[struct{}](t, h, http.MethodPut, "/api/v1/ratings/"+id, body, http.StatusBadRequest)
	}
	decode[struct{}](t, h, http.MethodPut, "/api/v1/ratings/nobody", `{"rating":5}`, http.StatusNotFound)
	decode[ratings.Rating](t, h, http.MethodPut, "/api/v1/ratings/"+id, `{"rating":6}`, http.StatusOK)
	decode[ratings.Rating](t, h, http.MethodPut, "/api/v1/ratings/"+id, `{"season":1,"episode":2,"rating":9}`, http.StatusOK)

	type ratingsBody struct {
		Ratings []ratings.Rating `json:"ratings"`
	}
	got := decode[ratingsBody](t, h, http.MethodGet, "/api/v1/ratings/"+id, "", http.StatusOK)
	if len(got.Ratings) != 2 || got.Ratings[0].Score != 6 || got.Ratings[1].Score != 9 {
		t.Fatalf("ratings = %+v", got)
	}
	decode[struct{}](t, h, http.MethodDelete, "/api/v1/ratings/"+id+"?season=1", "", http.StatusBadRequest)
	decode[struct{}](t, h, http.MethodDelete, "/api/v1/ratings/"+id, "", http.StatusNoContent)
	got = decode[ratingsBody](t, h, http.MethodGet, "/api/v1/ratings/"+id, "", http.StatusOK)
	if len(got.Ratings) != 1 || got.Ratings[0].Episode != 2 {
		t.Fatalf("after clearing the title's = %+v", got)
	}
	decode[struct{}](t, h, http.MethodDelete, "/api/v1/ratings/"+id+"?season=1&episode=2", "", http.StatusNoContent)
	if got = decode[ratingsBody](t, h, http.MethodGet, "/api/v1/ratings/nobody", "", http.StatusOK); got.Ratings == nil || len(got.Ratings) != 0 {
		t.Fatalf("no ratings = %+v, want an empty list", got)
	}
}

func TestHistoryRoute(t *testing.T) {
	h, id := libraryServer(t)
	decode[progress.Entry](t, h, http.MethodPut, "/api/v1/progress/"+id,
		`{"season":1,"episode":1,"position":1400,"duration":1500}`, http.StatusOK)
	decode[progress.Entry](t, h, http.MethodPut, "/api/v1/progress/"+id,
		`{"season":1,"episode":2,"position":300,"duration":1500}`, http.StatusOK)
	// Unmatched local files keep a position too; history has no name for them.
	decode[progress.Entry](t, h, http.MethodPut, "/api/v1/progress/local:abc",
		`{"position":300,"duration":1500}`, http.StatusOK)
	decode[ratings.Rating](t, h, http.MethodPut, "/api/v1/ratings/"+id, `{"season":1,"episode":1,"rating":7}`, http.StatusOK)

	type historyBody struct {
		Entries []historyEntry `json:"entries"`
		More    bool           `json:"more"`
	}
	for _, bad := range []string{"?limit=0", "?limit=201", "?offset=-1", "?limit=x"} {
		decode[struct{}](t, h, http.MethodGet, "/api/v1/history"+bad, "", http.StatusBadRequest)
	}
	got := decode[historyBody](t, h, http.MethodGet, "/api/v1/history?limit=10", "", http.StatusOK)
	if got.More || len(got.Entries) != 2 {
		t.Fatalf("history = %+v", got)
	}
	// Both in the same second: the later episode first.
	first, second := got.Entries[0], got.Entries[1]
	if first.Entry.Episode != 2 || first.Episode == nil || first.Episode.Title != "Second" || first.Rating != 0 {
		t.Errorf("first = %+v", first)
	}
	if second.Entry.Episode != 1 || !second.Entry.Watched || second.Rating != 7 || len(second.Item.Episodes) != 0 {
		t.Errorf("second = %+v", second)
	}
	got = decode[historyBody](t, h, http.MethodGet, "/api/v1/history?limit=1", "", http.StatusOK)
	if !got.More || len(got.Entries) != 1 {
		t.Fatalf("first page of one = %+v", got)
	}
}

func TestNewEpisodesRoute(t *testing.T) {
	h, id := libraryServer(t)
	type newBody struct {
		Items []watchlist.NewEpisode `json:"items"`
	}
	if got := decode[newBody](t, h, http.MethodGet, "/api/v1/new-episodes", "", http.StatusOK); got.Items == nil || len(got.Items) != 0 {
		t.Fatalf("nothing followed = %+v, want an empty list", got)
	}
	decode[progress.Entry](t, h, http.MethodPut, "/api/v1/progress/"+id,
		`{"season":1,"episode":1,"watched":true}`, http.StatusOK)
	got := decode[newBody](t, h, http.MethodGet, "/api/v1/new-episodes", "", http.StatusOK)
	if len(got.Items) != 1 || got.Items[0].Episode.Number != 2 || got.Items[0].Count != 1 {
		t.Fatalf("new episodes = %+v", got)
	}
}
