package api

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/update"
)

func TestUpdateFollowsThePreference(t *testing.T) {
	asked := 0
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked++
		if r.URL.Path == "/repos/eeegoloauq/lumeo/releases/latest" {
			_, _ = w.Write([]byte(`{"tag_name":"v9.0.0","html_url":"https://example.org/v9.0.0"}`))
			return
		}
		_, _ = w.Write([]byte(`<component/>`))
	}))
	defer github.Close()
	checker := update.New("0.1.68")
	checker.API, checker.Raw = github.URL, github.URL
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	h := New(Deps{
		Preferences: preferences.New(db, preferences.Preferences{CheckUpdates: true}),
		Updates:     checker,
	}, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()

	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"checkUpdates":false}`); rec.Code != http.StatusOK {
		t.Fatalf("patch: status %d: %s", rec.Code, rec.Body)
	}
	if rec := requestJSON(t, h, http.MethodGet, "/api/v1/update", ""); rec.Code != http.StatusNoContent || asked != 0 {
		t.Fatalf("turned off: status %d, %d requests to GitHub", rec.Code, asked)
	}

	requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"checkUpdates":true}`)
	if got := decode[update.Release](t, h, http.MethodGet, "/api/v1/update", "", http.StatusOK); got.Version != "9.0.0" || got.Notes != "<component/>" {
		t.Fatalf("release = %+v", got)
	}
}
