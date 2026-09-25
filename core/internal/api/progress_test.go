package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func progressServer(t *testing.T) http.Handler {
	t.Helper()
	return progressServerFor(t, catalog.MediaItem{
		ID: "series", Kind: catalog.KindSeries, Title: "Series",
		Episodes: []catalog.Episode{{Season: 1, Number: 1}, {Season: 1, Number: 2}},
	})
}

// progressServerFor is the same server over one catalogue item of the caller's
// choosing: the episode routes answer about what the catalogue says, so what
// it says is what the test has to be able to write.
func progressServerFor(t *testing.T, item catalog.MediaItem) http.Handler {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: item}, log)
	service := progress.New(db, cat)
	return New(Deps{Catalog: cat, Progress: service}, log).Handler()
}

// nextOf reads the one field the episode route answers with.
func nextOf(t *testing.T, h http.Handler, path string) *catalog.Episode {
	t.Helper()
	rec := requestJSON(t, h, http.MethodGet, path, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("%s: status %d: %s", path, rec.Code, rec.Body)
	}
	var body struct {
		Next *catalog.Episode `json:"next"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("%s: decode: %v", path, err)
	}
	return body.Next
}

func TestProgressRoutesAndContinue(t *testing.T) {
	h := progressServer(t)
	rec := requestJSON(t, h, http.MethodPut, "/api/v1/progress/series", `{"season":1,"episode":1,"position":50,"duration":100}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("put status %d: %s", rec.Code, rec.Body)
	}
	var entry progress.Entry
	if err := json.Unmarshal(rec.Body.Bytes(), &entry); err != nil {
		t.Fatalf("decode put: %v", err)
	}
	if entry.Watched || entry.Position != 50 || entry.UpdatedAt.IsZero() {
		t.Fatalf("put entry = %+v", entry)
	}

	rec = requestJSON(t, h, http.MethodPut, "/api/v1/progress/series", `{"season":1,"episode":1,"position":95,"duration":100}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("watched put status %d: %s", rec.Code, rec.Body)
	}
	rec = requestJSON(t, h, http.MethodGet, "/api/v1/progress/series", "")
	var body struct {
		Entries []progress.Entry `json:"entries"`
		Next    *progress.Entry  `json:"next"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode get: %v", err)
	}
	if len(body.Entries) != 1 || !body.Entries[0].Watched || body.Next == nil || body.Next.Episode != 2 {
		t.Fatalf("progress body = %+v", body)
	}

	rec = requestJSON(t, h, http.MethodGet, "/api/v1/continue?limit=1", "")
	var continuing []progress.ContinueItem
	if err := json.Unmarshal(rec.Body.Bytes(), &continuing); err != nil {
		t.Fatalf("decode continue: %v", err)
	}
	if len(continuing) != 1 || continuing[0].Item.ID != "series" || continuing[0].Next.Episode != 2 {
		t.Fatalf("continue = %+v", continuing)
	}
	if len(continuing[0].Item.Episodes) != 0 {
		t.Fatalf("continue leaked episodes: %+v", continuing[0].Item.Episodes)
	}

	rec = requestJSON(t, h, http.MethodDelete, "/api/v1/progress/series?season=1&episode=1", "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete status %d: %s", rec.Code, rec.Body)
	}
}

func TestProgressRejectsInvalidPosition(t *testing.T) {
	h := progressServer(t)
	for _, body := range []string{
		`{"position":-1,"duration":100}`,
		`{"position":101,"duration":100}`,
		`{"duration":-1}`,
	} {
		rec := requestJSON(t, h, http.MethodPut, "/api/v1/progress/series", body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("body %s: status %d: %s", body, rec.Code, rec.Body)
		}
	}
}

// Watched is a latch, and a rewatch left half way is what Continue watching
// opens: the finished pass leaves no position, the rewatch leaves its own.
func TestProgressWatchedLatchRewatchAndExplicitReset(t *testing.T) {
	h := progressServer(t)
	put := func(body string) progress.Entry {
		t.Helper()
		rec := requestJSON(t, h, http.MethodPut, "/api/v1/progress/series", body)
		var entry progress.Entry
		if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &entry) != nil {
			t.Fatalf("put %s: status %d: %s", body, rec.Code, rec.Body)
		}
		return entry
	}
	continuing := func() progress.Entry {
		t.Helper()
		var rows []progress.ContinueItem
		rec := requestJSON(t, h, http.MethodGet, "/api/v1/continue?limit=5", "")
		if json.Unmarshal(rec.Body.Bytes(), &rows) != nil || len(rows) != 1 {
			t.Fatalf("continue: %s", rec.Body)
		}
		return rows[0].Next
	}

	if e := put(`{"season":1,"episode":1,"position":95,"duration":100}`); !e.Watched || e.Position != 0 {
		t.Fatalf("finished entry = %+v", e)
	}
	if next := continuing(); next.Episode != 2 {
		t.Fatalf("after finishing, continue = %+v", next)
	}
	if e := put(`{"season":1,"episode":1,"position":40,"duration":100}`); !e.Watched || e.Position != 40 {
		t.Fatalf("rewatch entry = %+v", e)
	}
	if next := continuing(); next.Episode != 1 || next.Position != 40 || !next.Watched {
		t.Fatalf("during a rewatch, continue = %+v", next)
	}
	if e := put(`{"season":1,"episode":1,"position":50,"duration":100,"watched":true}`); !e.Watched || e.Position != 0 {
		t.Fatalf("marked watched = %+v", e)
	}
	if e := put(`{"season":1,"episode":1,"position":10,"duration":100,"watched":false}`); e.Watched || e.Position != 0 {
		t.Fatalf("reset entry = %+v", e)
	}
}

func TestProgressRoutesWithoutServiceSaySo(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New(Deps{}, log).Handler()
	for _, request := range []struct{ method, path string }{
		{http.MethodGet, "/api/v1/progress/item"},
		{http.MethodGet, "/api/v1/continue"},
	} {
		rec := requestJSON(t, h, request.method, request.path, "")
		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s: status %d", request.path, rec.Code)
		}
	}
}

func TestEpisodeAfterAnswersAboutTheEpisodeItWasAsked(t *testing.T) {
	h := progressServer(t)
	// Nothing has been reported for this series at all: the answer is about
	// the episode named in the query, not about what a player told the core.
	next := nextOf(t, h, "/api/v1/items/series/after?season=1&episode=1")
	if next == nil || next.Season != 1 || next.Number != 2 {
		t.Fatalf("next = %+v, want S1E2", next)
	}
	if next := nextOf(t, h, "/api/v1/items/series/after?season=1&episode=2"); next != nil {
		t.Fatalf("next after the finale = %+v, want none", next)
	}
}

func TestEpisodeAfterDoesNotOfferWhatHasNotAired(t *testing.T) {
	h := progressServerFor(t, catalog.MediaItem{
		ID: "series", Kind: catalog.KindSeries, Title: "Series",
		Episodes: []catalog.Episode{
			{Season: 1, Number: 1, Released: time.Now().Add(-48 * time.Hour)},
			{Season: 1, Number: 2, Released: time.Now().Add(48 * time.Hour)},
		},
	})
	if next := nextOf(t, h, "/api/v1/items/series/after?season=1&episode=1"); next != nil {
		t.Fatalf("next = %+v, want none while it is unaired", next)
	}

	// A film has nothing after it, and saying so is an answer rather than an
	// error: the player asks before it knows what it is playing.
	film := progressServerFor(t, catalog.MediaItem{ID: "series", Kind: catalog.KindMovie, Title: "Film"})
	if next := nextOf(t, film, "/api/v1/items/series/after?season=0&episode=0"); next != nil {
		t.Fatalf("next of a film = %+v, want none", next)
	}
}

func TestEpisodeAfterValidatesItsQuery(t *testing.T) {
	h := progressServer(t)
	for _, path := range []string{
		"/api/v1/items/series/after",
		"/api/v1/items/series/after?season=1",
		"/api/v1/items/series/after?season=one&episode=2",
		"/api/v1/items/series/after?season=1&episode=-2",
	} {
		if rec := requestJSON(t, h, http.MethodGet, path, ""); rec.Code != http.StatusBadRequest {
			t.Fatalf("%s: status %d, want 400", path, rec.Code)
		}
	}
	rec := requestJSON(t, h, http.MethodGet, "/api/v1/items/nothing/after?season=1&episode=1", "")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown item status %d, want 404: %s", rec.Code, rec.Body)
	}
}

func TestEpisodeAfterWithoutACatalogueSaysSo(t *testing.T) {
	// A core with nowhere to look up episodes must say that rather than
	// answer "there is no next episode", which is a statement about a series.
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	h := New(Deps{Progress: progress.New(db, nil)}, log).Handler()
	rec := requestJSON(t, h, http.MethodGet, "/api/v1/items/series/after?season=1&episode=1", "")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d, want 503: %s", rec.Code, rec.Body)
	}
	// And one with no progress service either refuses in the same way.
	h = New(Deps{}, log).Handler()
	rec = requestJSON(t, h, http.MethodGet, "/api/v1/items/series/after?season=1&episode=1", "")
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d, want 503: %s", rec.Code, rec.Body)
	}
}
