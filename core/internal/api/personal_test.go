package api

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/personal"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func personalServer(t *testing.T) (http.Handler, *preferences.Service) {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	prefs := preferences.New(db, preferences.Preferences{})
	return New(Deps{Preferences: prefs, Personal: personal.New(db, prefs)}, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler(), prefs
}

func TestPersonalDataTravelsAsAFile(t *testing.T) {
	from, fromPrefs := personalServer(t)
	to, toPrefs := personalServer(t)
	if _, err := fromPrefs.Patch(context.Background(), []byte(`{"accent":"teal"}`)); err != nil {
		t.Fatal(err)
	}

	rec := requestJSON(t, from, http.MethodGet, "/api/v1/personal", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("export: %d %s", rec.Code, rec.Body)
	}
	if d := rec.Header().Get("Content-Disposition"); !strings.HasPrefix(d, `attachment; filename="lumeo-`) {
		t.Fatalf("Content-Disposition %q", d)
	}
	file := rec.Body.String()

	rec = requestJSON(t, to, http.MethodPost, "/api/v1/personal", file)
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"preferences":1`) {
		t.Fatalf("import: %d %s", rec.Code, rec.Body)
	}
	if got, _ := toPrefs.Get(context.Background()); got.Accent != "teal" {
		t.Fatalf("accent %q after import", got.Accent)
	}
}

func TestPersonalImportRefusals(t *testing.T) {
	h, _ := personalServer(t)
	for name, c := range map[string]struct {
		body, contentType string
		code              int
	}{
		"not JSON":       {"title,rating", "text/csv", http.StatusUnsupportedMediaType},
		"not a document": {`[1, 2]`, "application/json", http.StatusBadRequest},
		"two documents":  {`{"format":"lumeo-personal","version":1} {}`, "application/json", http.StatusBadRequest},
		"other format":   {`{"format":"trakt","version":1}`, "application/json", http.StatusBadRequest},
		"too large":      {`{"format":"` + strings.Repeat("x", maxPersonal) + `"}`, "application/json", http.StatusRequestEntityTooLarge},
	} {
		t.Run(name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodPost, "/api/v1/personal", strings.NewReader(c.body))
			req.Header.Set("Content-Type", c.contentType)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			if rec.Code != c.code {
				t.Fatalf("%d %s, want %d", rec.Code, rec.Body, c.code)
			}
		})
	}
}
