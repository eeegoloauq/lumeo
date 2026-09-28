package subtitles

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

type keepDownloads struct {
	row  acquire.Download
	file diskFile
}

func (d *keepDownloads) List(context.Context) []acquire.Download { return []acquire.Download{d.row} }
func (d *keepDownloads) File(context.Context, string, time.Duration) (acquire.File, error) {
	return d.file, nil
}
func (d *keepDownloads) Extras(_ string, fn func(string) error) error {
	if err := os.MkdirAll(d.row.ExtrasDir(), 0o700); err != nil {
		return err
	}
	return fn(d.row.ExtrasDir())
}

type diskFile struct{ path string }

func (f diskFile) Path() string { return f.path }
func (f diskFile) Size() int64 {
	info, _ := os.Stat(f.path)
	return info.Size()
}
func (f diskFile) Head() int64                                     { return f.Size() }
func (f diskFile) Open(context.Context) (io.ReadSeekCloser, error) { return os.Open(f.path) }

type film struct{}

func (film) Item(context.Context, string) (catalog.MediaItem, error) {
	return catalog.MediaItem{ID: "casablanca", Kind: catalog.KindMovie,
		ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt0034583"}}, nil
}

type countingProvider struct {
	stubProvider
	calls int
}

func (p *countingProvider) Subtitles(ctx context.Context, q Query) ([]Subtitle, error) {
	p.calls++
	return p.stubProvider.Subtitles(ctx, q)
}

func testKeeper(t *testing.T, p Provider, languages ...string) (*Keeper, acquire.Download) {
	t.Helper()
	dir := t.TempDir()
	video := filepath.Join(dir, "Casablanca.1942.1080p.BluRay.mkv")
	if err := os.WriteFile(video, make([]byte, 256<<10), 0o600); err != nil {
		t.Fatal(err)
	}
	row := acquire.Download{
		ID: "d1", ItemID: "casablanca", Name: "Casablanca.1942.1080p.BluRay",
		Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"},
		Dir:     dir, FilePath: video, State: acquire.StateDone,
	}
	downloads := &keepDownloads{row: row, file: diskFile{video}}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	service := NewService(func() []Provider { return []Provider{p} }, nil, log)
	return NewKeeper(service, downloads, film{}, func(context.Context, string) []string { return languages }, log), row
}

// A download keeps, once, the best match in each wanted language, found by
// its file's hash; a language nobody has is not asked for again at once.
func TestKeeperKeepsTheBestMatchPerLanguageOnce(t *testing.T) {
	files := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "1\n00:00:01,000 --> 00:00:02,000\n"+r.URL.Path+"\n")
	}))
	defer files.Close()
	p := &countingProvider{stubProvider: stubProvider{id: "os", subs: []Subtitle{
		{ProviderID: "os", ID: "1", Language: "en", SourceURL: files.URL + "/en-title"},
		{ProviderID: "os", ID: "2", Language: "en", HashMatch: true, SourceURL: files.URL + "/en-hash"},
		{ProviderID: "os", ID: "3", Language: "pt-BR", SourceURL: files.URL + "/pt"},
		{ProviderID: "os", ID: "4", Language: "fr", SourceURL: files.URL + "/fr"},
	}}}
	keeper, row := testKeeper(t, p, "pt", "en", "de")

	keeper.Pass(context.Background())
	if p.got.VideoHash == "" || p.got.IMDbID != "tt0034583" {
		t.Fatalf("looked up by %+v, want the file's hash and the film", p.got)
	}
	kept := Kept(row.ExtrasDir(), "/kept/")
	if len(kept) != 2 {
		t.Fatalf("kept %+v, want one Portuguese and one English", kept)
	}
	for i, want := range []struct{ language, id, text string }{{"pt", "3", "/pt"}, {"en", "2", "/en-hash"}} {
		got := kept[i]
		if got.Language != want.language || got.ID != want.id || !got.Kept || got.URL != "/kept/"+filepath.Base(got.URL) {
			t.Fatalf("kept[%d] = %+v, want %s %s", i, got, want.language, want.id)
		}
		path, format, ok := KeptFile(row.ExtrasDir(), filepath.Base(got.URL))
		if !ok || format != "srt" {
			t.Fatalf("kept file %q: %v %q", got.URL, ok, format)
		}
		body, err := os.ReadFile(path)
		if err != nil || !strings.Contains(string(body), want.text) {
			t.Fatalf("kept file %s holds %q, %v", path, body, err)
		}
	}
	if _, _, ok := KeptFile(row.ExtrasDir(), "subtitles.json"); ok {
		t.Fatal("a name the index does not list is served")
	}

	keeper.Pass(context.Background())
	if p.calls != 1 {
		t.Fatalf("asked the provider %d times; what is kept, or was not there, is not asked for again", p.calls)
	}
	keeper.now = func() time.Time { return time.Now().Add(retryNone) }
	keeper.Pass(context.Background())
	if p.calls != 2 || len(p.got.Languages) != 1 || p.got.Languages[0] != "de" {
		t.Fatalf("after a day asked %d times for %v, want German again", p.calls, p.got.Languages)
	}
}

// With no provider answering, offline, nothing is recorded, and passes back
// off before asking again.
func TestKeeperTriesAgainWhenNoProviderAnswers(t *testing.T) {
	p := &countingProvider{stubProvider: stubProvider{id: "os", err: errors.New("no route to host")}}
	keeper, row := testKeeper(t, p, "en")
	now := time.Now()
	keeper.now = func() time.Time { return now }
	keeper.Pass(context.Background())
	keeper.Pass(context.Background())
	if p.calls != 1 {
		t.Fatalf("asked %d times at once, want a pause after a failure", p.calls)
	}
	now = now.Add(time.Hour)
	keeper.Pass(context.Background())
	if p.calls != 2 {
		t.Fatalf("asked %d times, want again after the pause", p.calls)
	}
	if _, err := os.Stat(row.ExtrasDir()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a failed lookup left files behind: %v", err)
	}
}
