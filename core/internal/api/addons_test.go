package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/addons"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func addonServer(t *testing.T) http.Handler {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	installed := addons.New(db, log)
	if err := installed.Load(context.Background(), nil); err != nil {
		t.Fatalf("load addons: %v", err)
	}
	return New(Deps{Sources: installed.Sources, Addons: installed}, log).Handler()
}

func fakeManifest(t *testing.T, id string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"id": %q, "name": "Streams", "resources": ["stream"]}`, id)
	}))
	t.Cleanup(srv.Close)
	return srv
}

func decodeAddon(t *testing.T, rec *httptest.ResponseRecorder) addons.Addon {
	t.Helper()
	var got addons.Addon
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode addon: %v: %s", err, rec.Body.String())
	}
	return got
}

func TestAddonsRoundTrip(t *testing.T) {
	h := addonServer(t)
	first := fakeManifest(t, "org.example.streams")

	rec := requestJSON(t, h, http.MethodPost, "/api/v1/addons", fmt.Sprintf(`{"url": %q}`, first.URL))
	if rec.Code != http.StatusCreated {
		t.Fatalf("install: %d %s", rec.Code, rec.Body.String())
	}
	if got := decodeAddon(t, rec); got.ID != "streams" || len(got.Resources) != 1 || got.Resources[0] != "stream" {
		t.Errorf("installed: %+v", got)
	}

	// The same addon from a new URL is the same addon.
	second := fakeManifest(t, "org.example.streams")
	rec = requestJSON(t, h, http.MethodPost, "/api/v1/addons", fmt.Sprintf(`{"url": %q}`, second.URL))
	if rec.Code != http.StatusOK || decodeAddon(t, rec).URL != second.URL {
		t.Errorf("reconfigure: %d %s", rec.Code, rec.Body.String())
	}

	rec = requestJSON(t, h, http.MethodGet, "/healthz", "")
	if body := rec.Body.String(); body != `{"providers":1,"status":"ok"}`+"\n" {
		t.Errorf("healthz counts the sources the list provides: %s", body)
	}

	rec = requestJSON(t, h, http.MethodPatch, "/api/v1/addons/streams", `{"enabled": false}`)
	if rec.Code != http.StatusOK || decodeAddon(t, rec).Enabled {
		t.Errorf("disable: %d %s", rec.Code, rec.Body.String())
	}
	rec = requestJSON(t, h, http.MethodGet, "/api/v1/addons", "")
	var list struct{ Addons []addons.Addon }
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil || len(list.Addons) != 1 || list.Addons[0].Enabled {
		t.Errorf("list: %s", rec.Body.String())
	}

	rec = requestJSON(t, h, http.MethodDelete, "/api/v1/addons/streams", "")
	if rec.Code != http.StatusNoContent {
		t.Errorf("remove: %d %s", rec.Code, rec.Body.String())
	}
	rec = requestJSON(t, h, http.MethodDelete, "/api/v1/addons/streams", "")
	if rec.Code != http.StatusNotFound {
		t.Errorf("remove again: %d", rec.Code)
	}
}

func TestAddonsRefuseBadInput(t *testing.T) {
	h := addonServer(t)
	dead := httptest.NewServer(http.NotFoundHandler())
	defer dead.Close()

	for _, tc := range []struct {
		method, path, body string
		want               int
	}{
		{http.MethodPost, "/api/v1/addons", `{"url": "not a url"}`, http.StatusBadRequest},
		{http.MethodPost, "/api/v1/addons", fmt.Sprintf(`{"url": %q}`, dead.URL), http.StatusBadRequest},
		{http.MethodPost, "/api/v1/addons", `[]`, http.StatusBadRequest},
		{http.MethodPost, "/api/v1/addons", ``, http.StatusUnsupportedMediaType},
		{http.MethodPatch, "/api/v1/addons/nobody", `{"enabled": true}`, http.StatusNotFound},
	} {
		rec := requestJSON(t, h, tc.method, tc.path, tc.body)
		if rec.Code != tc.want {
			t.Errorf("%s %s %s: %d %s", tc.method, tc.path, tc.body, rec.Code, rec.Body.String())
		}
	}
	if body := requestJSON(t, h, http.MethodGet, "/api/v1/addons", "").Body.String(); body != `{"addons":[]}`+"\n" {
		t.Errorf("nothing was installed: %s", body)
	}
}

func TestAddonRoutesWithoutServiceSaySo(t *testing.T) {
	h := New(Deps{}, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler()
	if rec := requestJSON(t, h, http.MethodGet, "/api/v1/addons", ""); rec.Code != http.StatusServiceUnavailable {
		t.Errorf("got %d", rec.Code)
	}
}
