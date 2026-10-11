package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	acquirelocal "github.com/eeegoloauq/lumeo/core/internal/acquire/local"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/local"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func doneRow(id string, episode int, name, binge, packPath string, loc sources.Locator) acquire.Download {
	return acquire.Download{ID: id, ItemID: "abc123", Season: 1, Episode: episode, Name: name,
		BingeGroup: binge, PackPath: packPath, Locator: loc, State: acquire.StateDone,
		CreatedAt: time.Unix(int64(1000-episode), 0)}
}

func torrent(hash string) sources.Locator {
	return sources.Locator{Scheme: "torrent", InfoHash: hash}
}

// A season on disk is one choice however it arrived: a pack's folder, a run
// of single-episode releases, a folder of files somebody already had.
func TestFoldersGroupTheReleasesOnDisk(t *testing.T) {
	rows := []acquire.Download{
		doneRow("p1", 1, "[Kaizoku] Show S1 [BD 1080p]", "kaizoku", "Season 1/e01.mkv", torrent("pack")),
		doneRow("p2", 2, "[Kaizoku] Show S1 [BD 1080p]", "kaizoku", "Season 1/e02.mkv", torrent("pack")),
		doneRow("dc", 1, "[Kaizoku] Show S1 [BD 1080p]", "kaizoku", "Shin Henshuu-ban/e01.mkv", torrent("pack")),
		doneRow("s3", 3, "[Weekly] Show - 03 [1080p]", "weekly", "", torrent("three")),
		doneRow("s4", 4, "[Weekly] Show - 04 [1080p]", "weekly", "", torrent("four")),
		doneRow("old", 5, "Show.S01E05.1080p", "", "", torrent("old")),
		doneRow("f6", 6, "Show.S01E06.mkv", "", "", sources.Locator{Scheme: "file", Path: "/home/me/Downloads/Show/Show.S01E06.mkv"}),
		{ID: "arriving", ItemID: "abc123", Season: 1, Episode: 7, Locator: torrent("pack"), BingeGroup: "kaizoku", PackPath: "Season 1/e07.mkv", State: acquire.StateActive},
		{ID: "other", ItemID: "else", Season: 1, Episode: 1, Locator: torrent("else"), State: acquire.StateDone},
	}
	got := foldersOf(rows, "abc123", progress.Pack{BingeGroup: "kaizoku", Folder: "Shin Henshuu-ban"})
	if len(got) != 5 {
		t.Fatalf("folders = %+v", got)
	}
	first := got[0]
	if !first.Current || first.Folder != "Shin Henshuu-ban" || !first.DirectorsCut || len(first.Episodes) != 1 {
		t.Fatalf("the chosen folder goes first: %+v", first)
	}
	byFolder := map[string]folder{}
	for _, f := range got[1:] {
		if f.Current {
			t.Fatalf("only one folder is current: %+v", got)
		}
		byFolder[f.Source.RawName+"|"+f.Folder+"|"+f.Dir] = f
	}
	if f := byFolder["[Kaizoku] Show S1 [BD 1080p]|Season 1|"]; len(f.Episodes) != 2 || f.DirectorsCut {
		t.Fatalf("pack folder = %+v", f)
	}
	// Described by the newest of them, episode 3.
	if f := byFolder["[Weekly] Show - 03 [1080p]||"]; len(f.Episodes) != 2 || f.Episodes[0].Episode != 3 || f.Episodes[1].Episode != 4 {
		t.Fatalf("single-episode releases of one group = %+v", byFolder)
	}
	if f := byFolder["Show.S01E05.1080p||"]; len(f.Episodes) != 1 {
		t.Fatalf("a download from before packs were kept = %+v", byFolder)
	}
	if f := byFolder["Show.S01E06.mkv||/home/me/Downloads/Show"]; len(f.Episodes) != 1 {
		t.Fatalf("a folder on this machine = %+v", byFolder)
	}
}

type foldersBody struct {
	Folders []folder `json:"folders"`
	Chosen  bool     `json:"chosen"`
}

func getFolders(t *testing.T, h http.Handler) foldersBody {
	t.Helper()
	rec := requestJSON(t, h, http.MethodGet, "/api/v1/items/abc123/folders", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("folders status %d: %s", rec.Code, rec.Body)
	}
	var body foldersBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return body
}

// Picking a release on the title's page decides what Play continues from
// before anything of it is started, and picking none hands it back to the
// ranking.
func TestChoosingAReleaseWithoutStartingIt(t *testing.T) {
	rows := []acquire.Download{
		doneRow("tv", 2, "[Kaizoku] Show S1", "kaizoku", "Season 1/e02.mkv", torrent("pack")),
		doneRow("dc", 2, "[Kaizoku] Show S1", "kaizoku", "Shin Henshuu-ban/e02.mkv", torrent("pack")),
	}
	// Done is a file that is there.
	for i := range rows {
		rows[i].FilePath = filepath.Join(t.TempDir(), "e02.mkv")
		if err := os.WriteFile(rows[i].FilePath, []byte("whole"), 0o600); err != nil {
			t.Fatal(err)
		}
		rows[i].Locator.FileIndex = new(i)
	}
	h, _ := choiceServer(t, rows, fixedSource{torrentSource("fresh", "fresh", 900, "fresh")})

	before := getFolders(t, h)
	if before.Chosen || len(before.Folders) != 2 {
		t.Fatalf("before = %+v", before)
	}
	var dc folder
	for _, f := range before.Folders {
		if f.Folder == "Shin Henshuu-ban" {
			dc = f
		}
	}
	pick, _ := json.Marshal(map[string]any{"source": dc.Source})
	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/choices/abc123", string(pick)); rec.Code != http.StatusOK {
		t.Fatalf("pick status %d: %s", rec.Code, rec.Body)
	}
	after := getFolders(t, h)
	if !after.Chosen || after.Folders[0].Folder != "Shin Henshuu-ban" || !after.Folders[0].Current {
		t.Fatalf("after = %+v", after)
	}
	listed := listSources(t, h)
	if listed[0].Path != "Shin Henshuu-ban/e02.mkv" || !listed[0].LastUsed {
		t.Fatalf("Play starts the picked folder's copy: %+v", listed)
	}

	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/choices/abc123", `{"source":null}`); rec.Code != http.StatusOK {
		t.Fatalf("clear status %d: %s", rec.Code, rec.Body)
	}
	if cleared := getFolders(t, h); cleared.Chosen || cleared.Folders[0].Current || cleared.Folders[1].Current {
		t.Fatalf("cleared = %+v", cleared)
	}
	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/choices/abc123", `{"source":{"rawName":"x"}}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("a source with no locator: status %d", rec.Code)
	}
}

func linkServer(t *testing.T) http.Handler {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	item := severance()
	item.Episodes = []catalog.Episode{{Season: 1, Number: 1}, {Season: 1, Number: 2}}
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: item}, log)
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{acquirelocal.Backend{}}, newFakeStore(), log)
	t.Cleanup(func() { manager.Close() })
	files := local.New(cat, manager, log)
	t.Cleanup(files.Close)
	return New(Deps{Catalog: cat, Downloads: manager, Local: files, Progress: progress.New(db, cat)}, log).Handler()
}

func TestLinkingAFolderMakesItTheTitlesCopy(t *testing.T) {
	h := linkServer(t)
	dir := t.TempDir()
	for _, name := range []string{"Severance.S01E01.mkv", "Severance.S01E02.mkv"} {
		if err := os.WriteFile(filepath.Join(dir, name), append([]byte("\x1a\x45\xdf\xa3"), make([]byte, 128<<10-4)...), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	body, _ := json.Marshal(map[string]string{"path": dir})
	rec := requestJSON(t, h, http.MethodPost, "/api/v1/items/abc123/folders", string(body))
	if rec.Code != http.StatusOK {
		t.Fatalf("link status %d: %s", rec.Code, rec.Body)
	}
	var got foldersBody
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if !got.Chosen || len(got.Folders) != 1 || got.Folders[0].Dir != dir || !got.Folders[0].Current || len(got.Folders[0].Episodes) != 2 {
		t.Fatalf("linked = %+v", got)
	}

	empty, _ := json.Marshal(map[string]string{"path": t.TempDir()})
	if rec := requestJSON(t, h, http.MethodPost, "/api/v1/items/abc123/folders", string(empty)); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("a folder with none of its episodes: status %d", rec.Code)
	}
	gone, _ := json.Marshal(map[string]string{"path": filepath.Join(dir, "gone")})
	if rec := requestJSON(t, h, http.MethodPost, "/api/v1/items/abc123/folders", string(gone)); rec.Code != http.StatusNotFound {
		t.Fatalf("a missing folder: status %d", rec.Code)
	}
	if rec := requestJSON(t, h, http.MethodPost, "/api/v1/items/abc123/folders", `{"path":"relative"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("a relative path: status %d", rec.Code)
	}
}

// The director's cut is on disk and the broadcast cut is picked by hand: the
// pick plays, from a provider, and starting it keeps it a pick by hand.
func TestAReleasePickedByHandGoesAheadOfAnotherOnDisk(t *testing.T) {
	dc := doneRow("dc", 2, "[Kaizoku] Show S1", "kaizoku", "Shin Henshuu-ban/e02.mkv", torrent("pack"))
	dc.FilePath = filepath.Join(t.TempDir(), "e02.mkv")
	if err := os.WriteFile(dc.FilePath, []byte("whole"), 0o600); err != nil {
		t.Fatal(err)
	}
	broadcast := torrentSource("broadcast", "tv", 900, "weekly")
	h, watch := choiceServer(t, []acquire.Download{dc}, fixedSource{broadcast})

	if listed := listSources(t, h); listed[0].Local != "done" {
		t.Fatalf("before a pick the copy on disk goes first: %+v", listed)
	}
	pick, _ := json.Marshal(map[string]any{"source": broadcast})
	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/choices/abc123", string(pick)); rec.Code != http.StatusOK {
		t.Fatalf("pick status %d: %s", rec.Code, rec.Body)
	}
	if listed := listSources(t, h); listed[0].RawName != "broadcast" || !listed[0].LastUsed {
		t.Fatalf("the pick goes ahead of the other release on disk: %+v", listed)
	}

	start, _ := json.Marshal(map[string]any{"itemId": "abc123", "season": 1, "episode": 2, "source": broadcast})
	if rec := requestJSON(t, h, http.MethodPost, "/api/v1/downloads", string(start)); rec.Code != http.StatusCreated {
		t.Fatalf("start status %d: %s", rec.Code, rec.Body)
	}
	if choice, err := watch.Choice(context.Background(), "abc123"); err != nil || !choice.Picked || choice.BingeGroup != "weekly" {
		t.Fatalf("after starting it: %+v err=%v", choice, err)
	}
}
