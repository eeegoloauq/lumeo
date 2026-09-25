package addons_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/addons"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

// fakeAddon serves a manifest that lists the given resources.
func fakeAddon(t *testing.T, id, name string, resources ...string) *httptest.Server {
	t.Helper()
	quoted := make([]string, 0, len(resources))
	for _, r := range resources {
		quoted = append(quoted, fmt.Sprintf("%q", r))
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/manifest.json") {
			http.NotFound(w, r)
			return
		}
		fmt.Fprintf(w, `{"id": %q, "name": %q, "version": "1.0.0", "resources": [%s]}`, id, name, strings.Join(quoted, ","))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func openStore(t *testing.T, path string) *store.DB {
	t.Helper()
	db, err := store.Open(path, "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func testService(t *testing.T, db *store.DB, seed ...addons.Seed) *addons.Service {
	t.Helper()
	s := addons.New(db, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := s.Load(context.Background(), seed); err != nil {
		t.Fatalf("load: %v", err)
	}
	return s
}

func ids(list []addons.Addon) string {
	var out []string
	for _, a := range list {
		out = append(out, a.ID)
	}
	return strings.Join(out, ",")
}

func TestSeedFillsAnEmptyDatabaseAndManifestsSayWhatEachIsFor(t *testing.T) {
	meta := fakeAddon(t, "org.example.meta", "Meta", "catalog", "meta")
	streams := fakeAddon(t, "org.example.streams", "Streams", "stream")
	subs := fakeAddon(t, "org.example.subs", "Subs", "subtitles")
	db := openStore(t, filepath.Join(t.TempDir(), "lumeo.db"))
	s := testService(t, db,
		addons.Seed{ID: "meta", Name: "Meta", URL: meta.URL + "/manifest.json"},
		addons.Seed{ID: "streams", Name: "Streams", URL: streams.URL},
		addons.Seed{ID: "subs", Name: "Subs", URL: subs.URL + "/"},
	)

	// Nothing has been fetched yet; the first ask fetches, and waits for it,
	// so the home screen's first request is not an empty screen.
	if got := s.Sources(); len(got) != 1 || got[0].ID() != "streams" {
		t.Errorf("sources: %v", got)
	}
	if got := s.Metadata(); len(got) != 1 || got[0].ID() != "meta" {
		t.Errorf("metadata: %v", got)
	}
	if got := s.Subtitles(); len(got) != 1 || got[0].ID() != "subs" {
		t.Errorf("subtitles: %v", got)
	}
	list := s.List()
	if ids(list) != "meta,streams,subs" {
		t.Errorf("order: %s", ids(list))
	}
	if list[0].URL != meta.URL || list[2].URL != subs.URL {
		t.Errorf("urls are kept as the protocol client wants them: %q %q", list[0].URL, list[2].URL)
	}
	if list[1].Version != "1.0.0" {
		t.Errorf("manifest facts: %+v", list[1])
	}
}

func TestAStoredListIsNotReseeded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lumeo.db")
	seed := addons.Seed{ID: "one", Name: "One", URL: "http://one.invalid"}
	db := openStore(t, path)
	s := testService(t, db, seed)
	if err := s.Remove(context.Background(), "one"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Add(context.Background(), fakeAddon(t, "org.two", "Two", "stream").URL); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()

	again := testService(t, openStore(t, path), seed)
	if got := ids(again.List()); got != "two" {
		t.Errorf("after a restart the stored list wins over the seed: %s", got)
	}
}

func TestAnEmptiedListStaysEmpty(t *testing.T) {
	path := filepath.Join(t.TempDir(), "lumeo.db")
	seed := addons.Seed{ID: "one", Name: "One", URL: "http://one.invalid"}
	db := openStore(t, path)
	s := testService(t, db, seed)
	if err := s.Remove(context.Background(), "one"); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()

	again := testService(t, openStore(t, path), seed)
	if got := again.List(); len(got) != 0 {
		t.Errorf("the seed is for a new database, not an emptied one: %v", got)
	}
}

func TestSeedsWithTheSameNameGetTheirOwnIDs(t *testing.T) {
	db := openStore(t, filepath.Join(t.TempDir(), "lumeo.db"))
	s := testService(t, db,
		addons.Seed{ID: "addon", Name: "addon", URL: "http://a.invalid"},
		addons.Seed{ID: "addon", Name: "addon", URL: "http://b.invalid"},
	)
	if got := ids(s.List()); got != "addon,addon-2" {
		t.Errorf("ids: %s", got)
	}
}

func TestAManifestSurvivesARestartWithoutTheNetwork(t *testing.T) {
	streams := fakeAddon(t, "org.example.streams", "Streams", "stream")
	path := filepath.Join(t.TempDir(), "lumeo.db")
	db := openStore(t, path)
	s := testService(t, db, addons.Seed{ID: "streams", Name: "Streams", URL: streams.URL})
	s.Refresh(context.Background())
	streams.Close()

	again := testService(t, db)
	if got := again.Sources(); len(got) != 1 {
		t.Errorf("sources from the stored manifest: %v", got)
	}
}

func TestAddRefusesWhatIsNotAnAddon(t *testing.T) {
	db := openStore(t, filepath.Join(t.TempDir(), "lumeo.db"))
	s := testService(t, db)
	dead := httptest.NewServer(http.NotFoundHandler())
	defer dead.Close()

	for _, url := range []string{"", "torrentio.strem.fun", "ftp://x.invalid", dead.URL} {
		_, _, err := s.Add(context.Background(), url)
		if !errors.Is(err, addons.ErrInvalid) {
			t.Errorf("%q: got %v, want ErrInvalid", url, err)
		}
	}
	if got := s.List(); len(got) != 0 {
		t.Errorf("nothing was stored: %v", got)
	}
}

func TestAddInstallsOnceAndReconfiguresAfter(t *testing.T) {
	db := openStore(t, filepath.Join(t.TempDir(), "lumeo.db"))
	s := testService(t, db)
	first := fakeAddon(t, "org.example.streams", "Streams", "stream")
	second := fakeAddon(t, "org.example.streams", "Streams", "stream")

	added, created, err := s.Add(context.Background(), first.URL+"/manifest.json")
	if err != nil || !created {
		t.Fatalf("first add: %v created=%v", err, created)
	}
	if added.ID != "streams" || added.URL != first.URL || !added.Enabled {
		t.Errorf("installed: %+v", added)
	}

	// The /configure page handed back a new URL for the same addon.
	again, created, err := s.Add(context.Background(), second.URL)
	if err != nil || created {
		t.Fatalf("second add: %v created=%v", err, created)
	}
	if again.ID != "streams" || again.URL != second.URL {
		t.Errorf("reconfigured: %+v", again)
	}
	if got := s.List(); len(got) != 1 {
		t.Errorf("one addon, not two: %v", got)
	}
	if got := s.Sources(); len(got) != 1 || got[0].ID() != "streams" {
		t.Errorf("sources: %v", got)
	}

	// A different addon with the same name gets its own id.
	other := fakeAddon(t, "org.other.streams", "Streams", "stream")
	third, created, err := s.Add(context.Background(), other.URL)
	if err != nil || !created || third.ID != "streams-2" {
		t.Errorf("third add: %+v created=%v err=%v", third, created, err)
	}
}

func TestDisabledAndMovedAddonsArePersisted(t *testing.T) {
	a := fakeAddon(t, "org.a", "A", "stream")
	b := fakeAddon(t, "org.b", "B", "stream")
	c := fakeAddon(t, "org.c", "C", "stream")
	path := filepath.Join(t.TempDir(), "lumeo.db")
	db := openStore(t, path)
	s := testService(t, db)
	ctx := context.Background()
	for _, srv := range []*httptest.Server{a, b, c} {
		if _, _, err := s.Add(ctx, srv.URL); err != nil {
			t.Fatal(err)
		}
	}

	off := false
	if _, err := s.Update(ctx, "b", addons.Patch{Enabled: &off}); err != nil {
		t.Fatal(err)
	}
	last := 2
	if _, err := s.Update(ctx, "a", addons.Patch{Position: &last}); err != nil {
		t.Fatal(err)
	}
	if got := ids(s.List()); got != "b,c,a" {
		t.Errorf("order: %s", got)
	}
	if got := s.Sources(); len(got) != 2 || got[0].ID() != "c" || got[1].ID() != "a" {
		t.Errorf("sources skip the disabled one and follow the order: %v", got)
	}

	// Both fields in one patch are one change.
	on, first := true, 0
	if _, err := s.Update(ctx, "b", addons.Patch{Enabled: &on, Position: &first}); err != nil {
		t.Fatal(err)
	}
	if got := s.Sources(); len(got) != 3 || got[0].ID() != "b" {
		t.Errorf("b enabled and first: %v", got)
	}
	if _, err := s.Update(ctx, "b", addons.Patch{Enabled: &off, Position: &first}); err != nil {
		t.Fatal(err)
	}

	beyond := 3
	if _, err := s.Update(ctx, "a", addons.Patch{Position: &beyond}); !errors.Is(err, addons.ErrInvalid) {
		t.Errorf("position past the end: %v", err)
	}
	if _, err := s.Update(ctx, "nobody", addons.Patch{Enabled: &off}); !errors.Is(err, addons.ErrNotFound) {
		t.Errorf("unknown id: %v", err)
	}

	again := testService(t, db)
	if got := ids(again.List()); got != "b,c,a" {
		t.Errorf("order after a restart: %s", got)
	}
	if again.List()[0].Enabled {
		t.Error("b stays disabled after a restart")
	}
}

func TestRemove(t *testing.T) {
	db := openStore(t, filepath.Join(t.TempDir(), "lumeo.db"))
	s := testService(t, db, addons.Seed{ID: "one", Name: "One", URL: "http://one.invalid"})
	ctx := context.Background()
	if err := s.Remove(ctx, "one"); err != nil {
		t.Fatal(err)
	}
	if err := s.Remove(ctx, "one"); !errors.Is(err, addons.ErrNotFound) {
		t.Errorf("second remove: %v", err)
	}
	if got := s.List(); len(got) != 0 {
		t.Errorf("list: %v", got)
	}
}
