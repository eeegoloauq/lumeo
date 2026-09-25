package local

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	acquirelocal "github.com/eeegoloauq/lumeo/core/internal/acquire/local"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

type provider struct{ items []catalog.MediaItem }

func (provider) ID() string        { return "test" }
func (provider) Name() string      { return "test" }
func (provider) Namespace() string { return catalog.NamespaceIMDb }
func (provider) Rows(context.Context) ([]catalog.Row, error) {
	return []catalog.Row{{ID: "search", Kind: catalog.KindMovie, Searchable: true}, {ID: "series", Kind: catalog.KindSeries, Searchable: true}}, nil
}
func (p provider) Browse(_ context.Context, req catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	var out []catalog.MediaItem
	for _, item := range p.items {
		if item.Kind == req.Kind {
			out = append(out, item)
		}
	}
	return out, nil
}
func (p provider) Meta(_ context.Context, _ catalog.Kind, id string) (*catalog.MediaItem, error) {
	for _, item := range p.items {
		if item.IMDbID() == id {
			return &item, nil
		}
	}
	return nil, catalog.ErrNotFound
}
func makeService(t *testing.T, items []catalog.MediaItem) (*Service, *acquire.Manager, *store.DB) {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	cat := catalog.NewService(catalog.Fixed(provider{items}), db, log)
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{acquirelocal.Backend{}}, db, log)
	t.Cleanup(func() { manager.Close() })
	return New(cat, manager, log), manager, db
}

// open is Open with the identification behind it done.
func open(s *Service, path string) (acquire.Download, error) {
	d, err := s.Open(context.Background(), path)
	if err != nil {
		return d, err
	}
	s.running.Wait()
	return s.downloads.Get(context.Background(), d.ID)
}

func writeVideo(t *testing.T, dir, name string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	// A Matroska header: the core opens nothing by path that is not a video.
	if err := os.WriteFile(path, append([]byte("\x1a\x45\xdf\xa3"), make([]byte, 128<<10-4)...), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func TestOpenIdentifiesMovieYear(t *testing.T) {
	items := []catalog.MediaItem{{ID: "old", Kind: catalog.KindMovie, Title: "Dune", Year: 1984, ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt1"}}, {ID: "new", Kind: catalog.KindMovie, Title: "Dune", Year: 2021, ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt2"}}}
	s, m, _ := makeService(t, items)
	path := writeVideo(t, t.TempDir(), "Dune.2021.mkv")
	d, err := open(s, path)
	if err != nil {
		t.Fatalf("download=%+v err=%v", d, err)
	}
	matched, err := s.catalog.Item(context.Background(), d.ItemID)
	if err != nil || matched.Year != 2021 {
		t.Fatalf("matched=%+v err=%v", matched, err)
	}
	again, err := open(s, path)
	if err != nil || again.ID != d.ID || len(m.List(context.Background())) != 1 {
		t.Fatalf("again=%+v err=%v", again, err)
	}
}
func TestOpenSeriesRegistersSiblings(t *testing.T) {
	item := catalog.MediaItem{ID: "show", Kind: catalog.KindSeries, Title: "Show", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt3"}, Episodes: []catalog.Episode{{Season: 2, Number: 1}, {Season: 2, Number: 2}}}
	s, m, _ := makeService(t, []catalog.MediaItem{item})
	dir := filepath.Join(t.TempDir(), "Show", "Season 2")
	path := writeVideo(t, dir, "S02E01.mkv")
	writeVideo(t, dir, "S02E02.mkv")
	writeVideo(t, dir, "Other.S02E03.mkv")
	d, err := open(s, path)
	if err != nil || d.Season != 2 || d.Episode != 1 {
		t.Fatalf("opened=%+v err=%v", d, err)
	}
	matched, err := s.catalog.Item(context.Background(), d.ItemID)
	if err != nil || matched.Title != "Show" {
		t.Fatalf("matched=%+v err=%v", matched, err)
	}
	rows := m.List(context.Background())
	if len(rows) != 2 {
		t.Fatalf("siblings=%+v", rows)
	}
	for _, r := range rows {
		if r.ItemID != d.ItemID || r.Season != 2 || r.Episode < 1 || r.Episode > 2 {
			t.Fatalf("row=%+v", r)
		}
	}
}
func TestOpenUnknownAndValidation(t *testing.T) {
	s, _, _ := makeService(t, nil)
	dir := t.TempDir()
	path := writeVideo(t, dir, "Unknown.2020.mkv")
	d, err := open(s, path)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	hash, err := subtitles.Hash(f, 128<<10)
	f.Close()
	if err != nil || d.ItemID != "local:"+hash || d.Season != 0 || d.Episode != 0 {
		t.Fatalf("download=%+v hash=%s err=%v", d, hash, err)
	}
	for _, p := range []string{filepath.Join(dir, "note.txt"), dir, "relative.mkv"} {
		if _, err := open(s, p); !errors.Is(err, ErrNotVideo) {
			t.Fatalf("%s: %v", p, err)
		}
	}
	if _, err := open(s, filepath.Join(dir, "gone.mkv")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing: %v", err)
	}
	small := filepath.Join(dir, "Tiny.S01E01.mkv")
	if err := os.WriteFile(small, []byte("\x1a\x45\xdf\xa3"), 0o600); err != nil {
		t.Fatal(err)
	}
	short, err := open(s, small)
	if err != nil || short.ItemID != "" || short.Season != 0 || short.Episode != 0 || short.State != acquire.StateDone {
		t.Fatalf("small=%+v err=%v", short, err)
	}
}
func TestOpenExistingDownloadPath(t *testing.T) {
	s, m, db := makeService(t, nil)
	path := writeVideo(t, t.TempDir(), "film.mkv")
	original := acquire.Download{ID: "existing", Name: "existing", Locator: sources.Locator{Scheme: "torrent", InfoHash: "hash"}, FilePath: path, Size: 128 << 10, State: acquire.StateDone}
	if err := db.SaveDownload(context.Background(), original); err != nil {
		t.Fatal(err)
	}
	if err := m.Resume(context.Background()); err != nil {
		t.Fatal(err)
	}
	got, err := open(s, path)
	if err != nil || got.ID != original.ID {
		t.Fatalf("got=%+v err=%v", got, err)
	}
}

// The search answers with whatever it has; a rip named by its disc track is
// not whichever title came back first.
func TestOpenRefusesALooseMatch(t *testing.T) {
	items := []catalog.MediaItem{
		{ID: "toilet", Kind: catalog.KindMovie, Title: "Skibidi Toilet", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt9"}},
		{ID: "track", Kind: catalog.KindMovie, Title: "Title Track", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt10"}},
	}
	s, _, _ := makeService(t, items)
	d, err := open(s, writeVideo(t, t.TempDir(), "title_t00.mkv"))
	if err != nil || !strings.HasPrefix(d.ItemID, "local:") {
		t.Fatalf("download=%+v err=%v", d, err)
	}
}

// Fansubs number episodes through the whole show: "- 12" with no season is
// the twelfth regular episode, and so is its sibling's number.
func TestOpenCountsAbsoluteEpisodes(t *testing.T) {
	item := catalog.MediaItem{ID: "frieren", Kind: catalog.KindSeries, Title: "Frieren: Beyond Journey's End", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt4"},
		Episodes: []catalog.Episode{{Season: 0, Number: 1}, {Season: 2, Number: 1}, {Season: 1, Number: 2}, {Season: 1, Number: 1}}}
	s, m, _ := makeService(t, []catalog.MediaItem{item})
	dir := t.TempDir()
	path := writeVideo(t, dir, "[SubsPlease] Sousou no Frieren - 02 (1080p) [8C4B3F9A].mkv")
	writeVideo(t, dir, "[SubsPlease] Sousou no Frieren - 03 (1080p) [0D1E2F3A].mkv")
	d, err := open(s, path)
	if err != nil || d.Season != 1 || d.Episode != 2 {
		t.Fatalf("opened=%+v err=%v", d, err)
	}
	for _, r := range m.List(context.Background()) {
		if r.ID != d.ID && (r.Season != 2 || r.Episode != 1) {
			t.Fatalf("sibling=%+v", r)
		}
	}
}

// Two shows share a word and the episode; the one named like the file wins,
// whatever order the search answered in.
func TestOpenPrefersTheExactShow(t *testing.T) {
	episodes := []catalog.Episode{{Season: 1, Number: 1}}
	items := []catalog.MediaItem{
		{ID: "uk", Kind: catalog.KindSeries, Title: "The Office Christmas Specials", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt5"}, Episodes: episodes},
		{ID: "us", Kind: catalog.KindSeries, Title: "The Office", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt6"}, Episodes: episodes},
	}
	s, _, _ := makeService(t, items)
	d, err := open(s, writeVideo(t, t.TempDir(), "The.Office.S01E01.mkv"))
	if err != nil {
		t.Fatal(err)
	}
	if matched, err := s.catalog.Item(context.Background(), d.ItemID); err != nil || matched.Title != "The Office" {
		t.Fatalf("matched=%+v err=%v", matched, err)
	}
}

// Holds every search until released, as a provider nobody reaches does.
type stalled struct {
	provider
	release chan struct{}
}

func (p stalled) Browse(ctx context.Context, req catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	select {
	case <-p.release:
		return p.provider.Browse(ctx, req)
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// The file plays while the catalogue is asked what it is, and is named when
// it answers.
func TestOpenDoesNotWaitForTheCatalogue(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	p := stalled{provider{[]catalog.MediaItem{{ID: "dune", Kind: catalog.KindMovie, Title: "Dune", Year: 2021, ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt2"}}}}, make(chan struct{})}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{acquirelocal.Backend{}}, db, log)
	defer manager.Close()
	s := New(catalog.NewService(catalog.Fixed(p), db, log), manager, log)
	defer s.Close()

	d, err := s.Open(context.Background(), writeVideo(t, t.TempDir(), "Dune.2021.mkv"))
	if err != nil || d.ItemID != "" || d.State != acquire.StateDone {
		t.Fatalf("opened=%+v err=%v; want a playable download with no title yet", d, err)
	}
	close(p.release)
	s.running.Wait()
	named, err := manager.Get(context.Background(), d.ID)
	if err != nil || named.ItemID == "" || strings.HasPrefix(named.ItemID, "local:") {
		t.Fatalf("named=%+v err=%v", named, err)
	}
}

// Stopping the core does not wait on a catalogue that never answers, and
// leaves the file to be identified when it is next opened.
func TestCloseStopsAnIdentification(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "test.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	p := stalled{provider{}, make(chan struct{})}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{acquirelocal.Backend{}}, db, log)
	defer manager.Close()
	s := New(catalog.NewService(catalog.Fixed(p), db, log), manager, log)
	d, err := s.Open(context.Background(), writeVideo(t, t.TempDir(), "Dune.2021.mkv"))
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	if got, err := manager.Get(context.Background(), d.ID); err != nil || got.ItemID != "" {
		t.Fatalf("after close=%+v err=%v; want no title", got, err)
	}
}
