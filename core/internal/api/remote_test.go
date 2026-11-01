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
	"sync/atomic"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	acquirelocal "github.com/eeegoloauq/lumeo/core/internal/acquire/local"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/library"
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

// linked is a media server and a core linked to it, as a device runs one.
// The server has two devices paired: laptop and tv.
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
	// serverDeps build the server, served is what answers at its address.
	serverDeps  Deps
	served      *atomic.Pointer[http.Handler]
	serverWatch *progress.Service
	log         *slog.Logger
}

const (
	laptopToken = "laptop-token"
	tvToken     = "tv-token"
)

func openStore(t testing.TB) (*store.DB, string) {
	t.Helper()
	dir := t.TempDir()
	db, err := store.Open(filepath.Join(dir, "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db, dir
}

func linkedCores(t testing.TB, found fixedSource, token string) *linked {
	t.Helper()
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	images := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("\xff\xd8\xff"))
	}))
	t.Cleanup(images.Close)
	item := severance()
	item.ID = ""
	item.Poster = images.URL + "/severance.jpg"
	item.Episodes = []catalog.Episode{{Season: 1, Number: 1, Thumbnail: images.URL + "/s1e1.jpg"}, {Season: 1, Number: 2}}
	serverDB, serverDir := openStore(t)
	for id, credential := range map[string]string{"laptop": laptopToken, "tv": tvToken} {
		if err := serverDB.AddDevice(context.Background(), store.Device{ID: id, Name: id, CreatedAt: time.Now()}, credential); err != nil {
			t.Fatal(err)
		}
	}
	serverCatalog := catalog.NewService(catalog.Fixed(shelfMeta{item}), serverDB, log)
	t.Cleanup(serverCatalog.Close)
	backend := &fakeStreamBackend{task: &fakeStreamTask{file: &fakeStreamFile{name: "e.mkv", data: payload()}}}
	theirs := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, newFakeStore(), log)
	t.Cleanup(func() { theirs.Close() })
	serverWatch := progress.New(serverDB, serverCatalog)
	// The keep pass itself never runs here; a release frees through it.
	serverPrefs := preferences.New(serverDB, preferences.Preferences{Keep: "forever", DeviceMaxKeepDays: 30})
	serverLibrary := library.New(theirs, serverDB, serverPrefs, log)
	l := &linked{t: t, theirs: theirs, serverWatch: serverWatch, log: log, served: &atomic.Pointer[http.Handler]{},
		requested: make(chan string, 100)}
	l.serverDeps = Deps{
		Sources:     func() []sources.Provider { return []sources.Provider{found} },
		Catalog:     serverCatalog,
		Downloads:   theirs,
		Progress:    serverWatch,
		Library:     serverLibrary,
		Preferences: serverPrefs,
		Artwork:     serverDB,
		Devices:     serverDB,
		CacheDir:    serverDir,
		Token:       "server-token",
		Mode:        remote.ModeMedia,
	}
	l.serve(l.serverDeps)
	l.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case l.requested <- r.Method + " " + r.URL.Path:
		default:
		}
		(*l.served.Load()).ServeHTTP(w, r)
	}))
	t.Cleanup(l.server.Close)
	l.link(token)
	return l
}

// serve makes the server one built on deps, as a restart with them would.
func (l *linked) serve(deps Deps) {
	server := New(deps, l.log)
	l.t.Cleanup(server.Close)
	handler := server.Handler()
	l.served.Store(&handler)
}

// link sets up this side as a core linked to the server with credential.
func (l *linked) link(credential string) {
	db, dir := openStore(l.t)
	link := remote.New(remote.Link{URL: l.server.URL, Token: credential}, l.log)
	cat := catalog.NewService(catalog.Fixed(link.Provider()), db, l.log)
	l.t.Cleanup(cat.Close)
	l.ours = acquire.NewManager(l.t.TempDir(), []acquire.Backend{acquirelocal.Backend{}}, newFakeStore(), l.log)
	l.t.Cleanup(func() { l.ours.Close() })
	l.watch = progress.New(db, cat)
	l.core = New(Deps{
		Catalog:   cat,
		Downloads: l.ours,
		Progress:  l.watch,
		Preferences: preferences.New(db, preferences.Preferences{
			SubtitleLanguages:     []string{"ru"},
			ServerKeepWatchedDays: acquire.DefaultKeepWatchedDays, ServerKeepUnwatchedDays: acquire.DefaultKeepUnwatchedDays,
		}),
		Artwork:  db,
		CacheDir: dir,
		Remote:   link,
	}, l.log)
	l.t.Cleanup(l.core.Close)
	l.local = l.core.Handler()
}

// another is a second device's core, linked to the same server.
func (l *linked) another(credential string) *linked {
	other := *l
	other.link(credential)
	if l.itemID != "" {
		other.open()
	}
	return &other
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
	l := linkedCores(t, nil, laptopToken)
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

// topMeta is a metadata provider named id whose one row, "top", holds item.
type topMeta struct {
	id   string
	item catalog.MediaItem
}

func (m topMeta) ID() string      { return m.id }
func (m topMeta) Name() string    { return m.id }
func (topMeta) Namespace() string { return catalog.NamespaceIMDb }
func (m topMeta) Rows(context.Context) ([]catalog.Row, error) {
	return []catalog.Row{{ProviderID: m.id, ID: "top", Kind: catalog.KindMovie, Name: m.id}}, nil
}
func (m topMeta) Browse(context.Context, catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	return []catalog.MediaItem{m.item}, nil
}
func (topMeta) Meta(context.Context, catalog.Kind, string) (*catalog.MediaItem, error) {
	return nil, catalog.ErrNotFound
}

// A client picks its shelves by row id, so a linked core answers the
// server's rows as the server does, and two of its providers may both have
// a "top" row whose pages each come from their own.
func TestALinkedCoreAnswersTheServersRowsAsTheServerDoes(t *testing.T) {
	l := linkedCores(t, nil, laptopToken)
	film := func(imdb, title string) catalog.MediaItem {
		return catalog.MediaItem{Kind: catalog.KindMovie, Title: title, ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: imdb}}
	}
	db, _ := openStore(t)
	serverCatalog := catalog.NewService(catalog.Fixed(topMeta{"cinemeta", film("tt0111161", "The Shawshank Redemption")},
		topMeta{"other", film("tt0068646", "The Godfather")}), db, l.log)
	t.Cleanup(serverCatalog.Close)
	deps := l.serverDeps
	deps.Catalog = serverCatalog
	l.serve(deps)

	rec := requestJSON(t, l.local, http.MethodGet, "/api/v1/catalogs", "")
	var rows struct {
		Catalogs []catalog.Row `json:"catalogs"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &rows); err != nil {
		t.Fatalf("catalogs: status %d: %s", rec.Code, rec.Body)
	}
	want := []catalog.Row{{ProviderID: "cinemeta", ID: "top", Kind: catalog.KindMovie, Name: "cinemeta"},
		{ProviderID: "other", ID: "top", Kind: catalog.KindMovie, Name: "other"}}
	if !slices.EqualFunc(rows.Catalogs, want, func(a, b catalog.Row) bool {
		return a.ProviderID == b.ProviderID && a.ID == b.ID && a.Kind == b.Kind
	}) {
		t.Fatalf("catalogs = %+v, want the server's %+v", rows.Catalogs, want)
	}
	for _, row := range rows.Catalogs {
		query := url.Values{"provider": {row.ProviderID}, "kind": {string(row.Kind)}, "id": {row.ID}}
		rec := requestJSON(t, l.local, http.MethodGet, "/api/v1/catalog?"+query.Encode(), "")
		var page struct {
			Items []catalog.MediaItem `json:"items"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil || len(page.Items) != 1 {
			t.Fatalf("%s's row: status %d: %s", row.ProviderID, rec.Code, rec.Body)
		}
		if title := map[string]string{"cinemeta": "The Shawshank Redemption", "other": "The Godfather"}[row.ProviderID]; page.Items[0].Title != title {
			t.Errorf("%s's row holds %q, want %q", row.ProviderID, page.Items[0].Title, title)
		}
	}
}

// A download starts on the server under its id, the pick is kept here, and
// the linked core lists it and plays it under its own.
func TestALinkedCoreDownloadsOnTheServerAndStreamsFromIt(t *testing.T) {
	l := linkedCores(t, nil, laptopToken)
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
	if choice, err := l.serverWatch.Choice(context.Background(), l.theirID); err != nil || choice.Pack != (progress.Pack{}) {
		t.Fatalf("pick kept on the server too: %+v, %v", choice.Pack, err)
	}
	if len(row.Holds) != 1 || row.Holds[0].Device != "laptop" || !slices.Equal(row.Holds[0].SubtitleLanguages, []string{"ru"}) {
		t.Fatalf("holds on the server: %+v; want the laptop's, with its languages", row.Holds)
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
	l := linkedCores(t, found, laptopToken)
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

// The server frees only what was watched, and keeps the subtitles wanted;
// the progress and preferences are kept on each device, so each device's
// core tells the server through its own hold, which the server makes when
// the device starts or plays the download. One device's word never
// overrides another's: the laptop not having watched an episode does not
// take back the TV's mark. None of the viewer's own data goes to the server.
func TestEachDeviceHoldsTheServersDownloadsItself(t *testing.T) {
	laptop := linkedCores(t, nil, laptopToken)
	laptop.open()
	if rec := requestJSON(t, laptop.local, http.MethodPatch, "/api/v1/preferences", `{"serverKeepUnwatchedDays":10}`); rec.Code != http.StatusOK {
		t.Fatalf("preferences: status %d: %s", rec.Code, rec.Body)
	}
	d := laptop.start(torrentSource("Severance.S01E01.1080p", "aaa", 30, "group"))
	tv := laptop.another(tvToken)
	holds := func() map[string]acquire.Hold {
		t.Helper()
		row, err := laptop.theirs.Get(context.Background(), d.ID)
		if err != nil {
			t.Fatal(err)
		}
		out := make(map[string]acquire.Hold)
		for _, h := range row.Holds {
			out[h.Device] = h
		}
		return out
	}
	sync := func(l *linked) {
		t.Helper()
		if err := l.core.syncHolds(context.Background()); err != nil {
			t.Fatalf("sync: %v", err)
		}
	}
	put := func(l *linked, body string) {
		t.Helper()
		if rec := requestJSON(t, l.local, http.MethodPut, "/api/v1/progress/"+l.itemID, body); rec.Code != http.StatusOK {
			t.Fatalf("progress: status %d: %s", rec.Code, rec.Body)
		}
	}
	for len(laptop.requested) > 0 {
		<-laptop.requested
	}

	// Started on the laptop: its hold, with its languages and rules. The TV
	// never played it, so its viewer's progress holds nothing.
	put(tv, `{"season":1,"episode":1,"watched":true}`)
	sync(tv)
	got := holds()
	if len(got) != 1 || !slices.Equal(got["laptop"].SubtitleLanguages, []string{"ru"}) ||
		got["laptop"].KeepWatchedDays != 1 || got["laptop"].KeepUnwatchedDays != 10 {
		t.Fatalf("after the start: %+v; want the laptop's alone, with its rules", got)
	}

	// Playing it on the TV holds it there.
	if rec := requestJSON(t, tv.local, http.MethodGet, "/api/v1/downloads/"+d.ID+"/stream", ""); rec.Code != http.StatusOK {
		t.Fatalf("stream on the TV: status %d: %s", rec.Code, rec.Body)
	}
	put(laptop, `{"season":1,"episode":1,"position":600,"duration":3000}`)
	sync(tv)
	sync(laptop)
	got = holds()
	if got["tv"].WatchedAt.IsZero() || !got["laptop"].WatchedAt.IsZero() {
		t.Fatalf("holds = %+v; want the TV's watched and the laptop's not", got)
	}

	// A rewatch on the TV takes its mark back; a change of the laptop's
	// languages or keep rules reaches its hold.
	put(tv, `{"season":1,"episode":1,"position":600,"duration":3000}`)
	if rec := requestJSON(t, laptop.local, http.MethodPatch, "/api/v1/preferences", `{"subtitleLanguages":["de","en"],"serverKeepWatchedDays":3}`); rec.Code != http.StatusOK {
		t.Fatalf("preferences: status %d: %s", rec.Code, rec.Body)
	}
	sync(tv)
	sync(laptop)
	got = holds()
	if !got["tv"].WatchedAt.IsZero() || !slices.Equal(got["laptop"].SubtitleLanguages, []string{"de", "en"}) || got["laptop"].KeepWatchedDays != 3 {
		t.Fatalf("holds = %+v; want the TV's mark gone and the laptop on German and English, three days", got)
	}

	requestJSON(t, laptop.local, http.MethodPut, "/api/v1/list/"+laptop.itemID, "")
	requestJSON(t, laptop.local, http.MethodPut, "/api/v1/ratings/"+laptop.itemID, `{"rating":8}`)
	requestJSON(t, laptop.local, http.MethodGet, "/api/v1/continue", "")
	close(laptop.requested)
	for path := range laptop.requested {
		for _, personal := range []string{"/progress", "/list", "/ratings", "/continue", "/choices", "/preferences"} {
			if strings.Contains(path, personal) {
				t.Errorf("the server was asked %s", path)
			}
		}
	}

	// Revoking the TV releases its hold, which stays on record until the
	// download goes, and the TV's core does not take it back.
	revoke := httptest.NewRequest(http.MethodDelete, "/api/v1/devices/tv", nil)
	revoke.Header.Set("Authorization", "Bearer server-token")
	rec := httptest.NewRecorder()
	(*laptop.served.Load()).ServeHTTP(rec, revoke)
	if hold, held := holds()["tv"]; rec.Code != http.StatusNoContent || !held || hold.ReleasedAt.IsZero() {
		t.Fatalf("revoking the TV: status %d, holds %+v", rec.Code, holds())
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

	l := linkedCores(t, nil, laptopToken)
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
	l.core.remote = remote.New(remote.Link{URL: l.server.URL, Token: laptopToken}, slog.New(slog.NewTextHandler(io.Discard, nil)))
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
