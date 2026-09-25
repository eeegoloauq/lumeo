package api

import (
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/searches"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func TestSearchHistoryRoundTrip(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	h := New(Deps{Searches: searches.New(db)}, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()

	recent := func() []string {
		t.Helper()
		return decode[struct {
			Searches []string `json:"searches"`
		}](t, h, http.MethodGet, "/api/v1/searches", "", http.StatusOK).Searches
	}
	if got := recent(); got == nil || len(got) != 0 {
		t.Fatalf("empty history is %#v, want an empty list", got)
	}
	for _, q := range []string{"fargo", "dune", " Fargo "} {
		if rec := requestJSON(t, h, http.MethodPost, "/api/v1/searches", `{"query":"`+q+`"}`); rec.Code != http.StatusNoContent {
			t.Fatalf("record %q: %d %s", q, rec.Code, rec.Body)
		}
	}
	if got, want := recent(), []string{"Fargo", "dune"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("history %q, want %q", got, want)
	}
	if rec := requestJSON(t, h, http.MethodPost, "/api/v1/searches", `{"query":"  "}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("blank query: %d", rec.Code)
	}
	if rec := requestJSON(t, h, http.MethodDelete, "/api/v1/searches?q=FARGO", ""); rec.Code != http.StatusNoContent {
		t.Fatalf("forget: %d %s", rec.Code, rec.Body)
	}
	if got, want := recent(), []string{"dune"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("after forget %q, want %q", got, want)
	}
	if rec := requestJSON(t, h, http.MethodDelete, "/api/v1/searches", ""); rec.Code != http.StatusNoContent {
		t.Fatalf("clear: %d %s", rec.Code, rec.Body)
	}
	if got := recent(); len(got) != 0 {
		t.Fatalf("after clear %q", got)
	}
}
