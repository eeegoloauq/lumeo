package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	acquirelocal "github.com/eeegoloauq/lumeo/core/internal/acquire/local"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

// shelfMeta is a metadata provider with one row and one series in it.
type shelfMeta struct{ item catalog.MediaItem }

func (shelfMeta) ID() string        { return "meta" }
func (shelfMeta) Name() string      { return "Meta" }
func (shelfMeta) Namespace() string { return catalog.NamespaceIMDb }
func (shelfMeta) Rows(context.Context) ([]catalog.Row, error) {
	return []catalog.Row{{ProviderID: "meta", ID: "top/picks", Kind: catalog.KindSeries, Name: "Top", Searchable: true}}, nil
}
func (m shelfMeta) Browse(context.Context, catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	item := m.item
	item.Episodes = nil
	return []catalog.MediaItem{item}, nil
}
func (m shelfMeta) Meta(_ context.Context, _ catalog.Kind, id string) (*catalog.MediaItem, error) {
	if id != m.item.IMDbID() {
		return nil, catalog.ErrNotFound
	}
	item := m.item
	return &item, nil
}

// linked is a full core as the server and a core linked to it, as a device
// runs one.
type linked struct {
	t         testing.TB
	server    *httptest.Server
	local     http.Handler
	core      *Server
	theirs    *acquire.Manager
	ours      *acquire.Manager
	watch     *progress.Service
	requested chan string
	// itemID is the series' id on the linked core, theirID on the server.
	itemID, theirID string
}

func linkedCores(t testing.TB, found fixedSource, token string) *linked {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	open := func() (*store.DB, string) {
		dir := t.TempDir()
		db, err := store.Open(filepath.Join(dir, "lumeo.db"), "test")
		if err != nil {
			t.Fatalf("open store: %v", err)
		}
		t.Cleanup(func() { _ = db.Close() })
		return db, dir
	}

	images := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("\xff\xd8\xff"))
	}))
	t.Cleanup(images.Close)
	item := severance()
	item.ID = ""
	item.Poster = images.URL + "/severance.jpg"
	item.Episodes = []catalog.Episode{{Season: 1, Number: 1, Thumbnail: images.URL + "/s1e1.jpg"}, {Season: 1, Number: 2}}
	serverDB, serverDir := open()
	serverCatalog := catalog.NewService(catalog.Fixed(shelfMeta{item}), serverDB, log)
	t.Cleanup(serverCatalog.Close)
	backend := &fakeStreamBackend{task: &fakeStreamTask{file: &fakeStreamFile{name: "e.mkv", data: payload()}}}
	theirs := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, newFakeStore(), log)
	t.Cleanup(func() { theirs.Close() })
	server := New(Deps{
		Sources:   func() []sources.Provider { return []sources.Provider{found} },
		Catalog:   serverCatalog,
		Downloads: theirs,
		Progress:  progress.New(serverDB, serverCatalog),
		Artwork:   serverDB,
		CacheDir:  serverDir,
		Token:     "server-token",
	}, log)
	t.Cleanup(server.Close)
	requested := make(chan string, 100)
	handler := server.Handler()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case requested <- r.Method + " " + r.URL.Path:
		default:
		}
		handler.ServeHTTP(w, r)
	}))
	t.Cleanup(ts.Close)

	db, dir := open()
	link := remote.New(remote.Link{URL: ts.URL, Token: token}, log)
	cat := catalog.NewService(catalog.Fixed(link.Provider()), db, log)
	t.Cleanup(cat.Close)
	ours := acquire.NewManager(t.TempDir(), []acquire.Backend{acquirelocal.Backend{}}, newFakeStore(), log)
	t.Cleanup(func() { ours.Close() })
	watch := progress.New(db, cat)
	core := New(Deps{
		Catalog:     cat,
		Downloads:   ours,
		Progress:    watch,
		Preferences: preferences.New(db, preferences.Preferences{SubtitleLanguages: []string{"ru"}}),
		Artwork:     db,
		CacheDir:    dir,
		Remote:      link,
	}, log)
	t.Cleanup(core.Close)
	return &linked{t: t, server: ts, local: core.Handler(), core: core, theirs: theirs, ours: ours, watch: watch, requested: requested}
}

// open finds the series through the linked core's catalogue, which mints
// its own id for it, and learns the server's.
func (l *linked) open() {
	l.t.Helper()
	rec := requestJSON(l.t, l.local, http.MethodGet, "/api/v1/find?imdb=tt11280740&kind=series", "")
	if rec.Code != http.StatusOK {
		l.t.Fatalf("find: status %d: %s", rec.Code, rec.Body)
	}
	var item catalog.MediaItem
	if err := json.Unmarshal(rec.Body.Bytes(), &item); err != nil {
		l.t.Fatal(err)
	}
	l.itemID = item.ID
	req, _ := http.NewRequest(http.MethodGet, l.server.URL+"/api/v1/find?imdb=tt11280740&kind=series", nil)
	req.Header.Set("Authorization", "Bearer server-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		l.t.Fatal(err)
	}
	defer resp.Body.Close()
	var theirs catalog.MediaItem
	if err := json.NewDecoder(resp.Body).Decode(&theirs); err != nil {
		l.t.Fatal(err)
	}
	l.theirID = theirs.ID
	if l.itemID == "" || l.theirID == "" || l.itemID == l.theirID {
		l.t.Fatalf("ids: ours %q, theirs %q; each core mints its own", l.itemID, l.theirID)
	}
}

func (l *linked) start(src sources.MediaSource) acquire.Download {
	l.t.Helper()
	body, _ := json.Marshal(startDownloadRequest{ItemID: l.itemID, Season: 1, Episode: 1, Source: src})
	rec := requestJSON(l.t, l.local, http.MethodPost, "/api/v1/downloads", string(body))
	if rec.Code != http.StatusCreated {
		l.t.Fatalf("start: status %d: %s", rec.Code, rec.Body)
	}
	var d acquire.Download
	if err := json.Unmarshal(rec.Body.Bytes(), &d); err != nil {
		l.t.Fatal(err)
	}
	return d
}

// The server's catalogue under the linked core's ids, its artwork loaded from
// the server, which needs no credential for it.
func TestALinkedCoreShowsTheServersTitles(t *testing.T) {
	l := linkedCores(t, nil, "server-token")
	rec := requestJSON(t, l.local, http.MethodGet, "/api/v1/catalogs", "")
	var rows struct {
		Catalogs []catalog.Row `json:"catalogs"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &rows); err != nil || len(rows.Catalogs) != 1 {
		t.Fatalf("catalogs: %s", rec.Body)
	}
	row := rows.Catalogs[0]
	query := url.Values{"provider": {row.ProviderID}, "kind": {"series"}, "id": {row.ID}}
	rec = requestJSON(t, l.local, http.MethodGet, "/api/v1/catalog?"+query.Encode(), "")
	var page struct {
		Items []catalog.MediaItem `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil || len(page.Items) != 1 {
		t.Fatalf("catalog: status %d: %s", rec.Code, rec.Body)
	}
	l.open()
	if page.Items[0].ID != l.itemID {
		t.Fatalf("row's item %q, found as %q", page.Items[0].ID, l.itemID)
	}
	rec = requestJSON(t, l.local, http.MethodGet, "/api/v1/search?kind=series&q=sev", "")
	if !strings.Contains(rec.Body.String(), l.itemID) {
		t.Fatalf("search: %s", rec.Body)
	}

	rec = requestJSON(t, l.local, http.MethodGet, "/api/v1/items/"+l.itemID, "")
	var item catalog.MediaItem
	if err := json.Unmarshal(rec.Body.Bytes(), &item); err != nil {
		t.Fatal(err)
	}
	artwork := l.server.URL + "/api/v1/artwork/"
	if !strings.HasPrefix(item.Poster, artwork) || len(item.Episodes) != 2 || !strings.HasPrefix(item.Episodes[0].Thumbnail, artwork) {
		t.Fatalf("item = %+v; want the server's artwork and episodes", item)
	}
	resp, err := http.Get(item.Poster)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("the poster from the server: status %d", resp.StatusCode)
	}
}

// A download starts on the server under its id, the pick is kept here, and
// the linked core lists it and plays it under its own.
func TestALinkedCoreDownloadsOnTheServerAndStreamsFromIt(t *testing.T) {
	l := linkedCores(t, nil, "server-token")
	l.open()
	src := torrentSource("Severance.S01E01.1080p", "aaa", 30, "group")
	d := l.start(src)
	if d.ItemID != l.itemID {
		t.Fatalf("started under %q, want ours %q", d.ItemID, l.itemID)
	}
	row, err := l.theirs.Get(context.Background(), d.ID)
	if err != nil || row.ItemID != l.theirID {
		t.Fatalf("on the server: %+v, %v; want under %q", row, err, l.theirID)
	}
	if rows := l.ours.List(context.Background()); len(rows) != 0 {
		t.Fatalf("started here too: %+v", rows)
	}
	if choice, err := l.watch.Choice(context.Background(), l.itemID); err != nil || choice.Pack.InfoHash != "aaa" {
		t.Fatalf("pick kept here = %+v, %v", choice.Pack, err)
	}

	rec := requestJSON(t, l.local, http.MethodGet, "/api/v1/downloads", "")
	var list struct {
		Downloads []acquire.Download `json:"downloads"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil || len(list.Downloads) != 1 || list.Downloads[0].ItemID != l.itemID {
		t.Fatalf("downloads: %s", rec.Body)
	}
	rec = requestJSON(t, l.local, http.MethodGet, "/api/v1/downloads/"+d.ID, "")
	if !strings.Contains(rec.Body.String(), `"itemId":"`+l.itemID+`"`) {
		t.Fatalf("download: %s", rec.Body)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+d.ID+"/stream", nil)
	req.Header.Set("Range", "bytes=3-7")
	stream := httptest.NewRecorder()
	l.local.ServeHTTP(stream, req)
	if stream.Code != http.StatusPartialContent || stream.Body.String() != string(payload()[3:8]) {
		t.Fatalf("stream: status %d, body %q", stream.Code, stream.Body)
	}
	if got := stream.Header().Get("Content-Range"); got != "bytes 3-7/36" {
		t.Fatalf("Content-Range = %q", got)
	}
}

// The server's copies in this core's order: the pack picked here first, then
// a file on this machine the server has never seen, which the server's fits
// do not concern.
func TestALinkedCoreRanksTheServersCopiesByItsOwnChoice(t *testing.T) {
	found := fixedSource{
		torrentSource("Severance.S01E01.2160p", "aaa", 80, "big"),
		torrentSource("Severance.S01E01.720p", "bbb", 10, "small"),
	}
	l := linkedCores(t, found, "server-token")
	l.open()
	if err := l.watch.RememberSource(context.Background(), l.itemID, progress.Pack{BingeGroup: "small", InfoHash: "bbb", Picked: true}); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "Severance.S01E01.mkv")
	if err := os.WriteFile(path, matroska(), 0o600); err != nil {
		t.Fatal(err)
	}
	mine, err := l.ours.OpenLocal(context.Background(), acquire.Request{
		ItemID: l.itemID, Season: 1, Episode: 1,
		Source: sources.MediaSource{RawName: "Severance.S01E01.mkv", Locator: sources.Locator{Scheme: "file", Path: path}},
	})
	if err != nil {
		t.Fatal(err)
	}

	rec := requestJSON(t, l.local, http.MethodGet, "/api/v1/sources?item="+l.itemID+"&season=1&episode=1", "")
	var body struct {
		Sources   []listedSource `json:"sources"`
		Providers int            `json:"providers"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, s := range body.Sources {
		names = append(names, s.RawName+" "+s.Local)
	}
	want := []string{"Severance.S01E01.720p ", "Severance.S01E01.mkv done", "Severance.S01E01.2160p "}
	if !slices.Equal(names, want) || body.Providers != 1 {
		t.Fatalf("sources = %q, providers %d; want %q", names, body.Providers, want)
	}

	// Playing the file stays here: the server cannot open it.
	rec = requestJSON(t, l.local, http.MethodGet, "/api/v1/downloads/"+mine.ID+"/stream", "")
	if rec.Code != http.StatusOK || rec.Body.Len() != len(matroska()) {
		t.Fatalf("local stream: status %d", rec.Code)
	}
}

// The server frees only what was watched; the progress is kept here, so the
// linked core marks the server's downloads, and takes the mark back for a
// rewatch. None of the viewer's own data goes to the server.
func TestALinkedCoreMarksWhatWasWatchedOnTheServer(t *testing.T) {
	l := linkedCores(t, nil, "server-token")
	l.open()
	d := l.start(torrentSource("Severance.S01E01.1080p", "aaa", 30, "group"))
	marked := func() bool {
		row, err := l.theirs.Get(context.Background(), d.ID)
		if err != nil {
			t.Fatal(err)
		}
		return !row.WatchedAt.IsZero()
	}
	sync := func() {
		if err := l.core.syncWatched(context.Background()); err != nil {
			t.Fatalf("sync: %v", err)
		}
	}
	for len(l.requested) > 0 {
		<-l.requested
	}

	put := func(body string) {
		if rec := requestJSON(t, l.local, http.MethodPut, "/api/v1/progress/"+l.itemID, body); rec.Code != http.StatusOK {
			t.Fatalf("progress: status %d: %s", rec.Code, rec.Body)
		}
	}
	put(`{"season":1,"episode":1,"position":600,"duration":3000}`)
	sync()
	if marked() {
		t.Fatal("marked part way through")
	}
	put(`{"season":1,"episode":1,"watched":true}`)
	sync()
	if !marked() {
		t.Fatal("not marked once watched")
	}
	put(`{"season":1,"episode":1,"position":600,"duration":3000}`)
	sync()
	if marked() {
		t.Fatal("still marked through a rewatch")
	}
	requestJSON(t, l.local, http.MethodPut, "/api/v1/list/"+l.itemID, "")
	requestJSON(t, l.local, http.MethodPut, "/api/v1/ratings/"+l.itemID, `{"rating":8}`)
	requestJSON(t, l.local, http.MethodGet, "/api/v1/continue", "")

	close(l.requested)
	for path := range l.requested {
		for _, personal := range []string{"/progress", "/list", "/ratings", "/continue", "/choices", "/preferences"} {
			if strings.Contains(path, personal) {
				t.Errorf("the server was asked %s", path)
			}
		}
	}
}

// A server that cannot be asked leaves the copies on this machine playable,
// and names itself as the provider that failed; one that refuses the device
// is never passed on as a 401, which the client reads as its own token
// being wrong.
func TestALinkedCoreWithoutItsServer(t *testing.T) {
	refused := linkedCores(t, nil, "revoked")
	for _, path := range []string{"/api/v1/addons", "/api/v1/downloads/x/stream", "/api/v1/storage"} {
		rec := requestJSON(t, refused.local, http.MethodGet, path, "")
		if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), remote.RefusedMessage) {
			t.Errorf("%s with a revoked device: status %d: %s", path, rec.Code, rec.Body)
		}
	}

	l := linkedCores(t, nil, "server-token")
	l.open()
	path := filepath.Join(t.TempDir(), "Severance.S01E01.mkv")
	if err := os.WriteFile(path, matroska(), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := l.ours.OpenLocal(context.Background(), acquire.Request{
		ItemID: l.itemID, Season: 1, Episode: 1,
		Source: sources.MediaSource{RawName: "Severance.S01E01.mkv", Locator: sources.Locator{Scheme: "file", Path: path}},
	}); err != nil {
		t.Fatal(err)
	}
	l.server.Close()
	l.core.remote = remote.New(remote.Link{URL: l.server.URL, Token: "server-token"}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	local := l.core.Handler()

	rec := requestJSON(t, local, http.MethodGet, "/api/v1/sources?item="+l.itemID+"&season=1&episode=1", "")
	var body struct {
		Sources   []listedSource   `json:"sources"`
		Failed    []failedProvider `json:"failed"`
		Providers int              `json:"providers"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if len(body.Sources) != 1 || body.Sources[0].Locator.Path != path || body.Providers != 1 ||
		len(body.Failed) != 1 || body.Failed[0].Provider != "Server" {
		t.Fatalf("sources without the server: %s", rec.Body)
	}
	if rec := requestJSON(t, local, http.MethodGet, "/api/v1/addons", ""); rec.Code != http.StatusBadGateway {
		t.Fatalf("addons without the server: status %d", rec.Code)
	}
}

// matroska is enough of a Matroska file for a file on this machine to open.
func matroska() []byte { return append([]byte("\x1a\x45\xdf\xa3"), make([]byte, 128<<10-4)...) }
