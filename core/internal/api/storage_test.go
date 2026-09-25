package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/library"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func storageServer(t *testing.T) (http.Handler, *acquire.Manager, []acquire.Download, string) {
	t.Helper()
	downloadDir := t.TempDir()
	regularDir := filepath.Join(downloadDir, "regular")
	sparseDir := filepath.Join(downloadDir, "sparse")
	emptyDir := filepath.Join(downloadDir, "empty")
	goneDir := filepath.Join(downloadDir, "gone")
	for _, dir := range []string{regularDir, sparseDir, emptyDir, goneDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	if err := os.WriteFile(filepath.Join(regularDir, "episode.mkv"), make([]byte, 8192), 0o600); err != nil {
		t.Fatalf("write regular file: %v", err)
	}
	sparse, err := os.Create(filepath.Join(sparseDir, "episode.mkv"))
	if err != nil {
		t.Fatalf("create sparse file: %v", err)
	}
	if err := sparse.Truncate(32 << 20); err != nil {
		t.Fatalf("truncate sparse file: %v", err)
	}
	if _, err := sparse.WriteAt([]byte{1}, 0); err != nil {
		t.Fatalf("write sparse file: %v", err)
	}
	if err := sparse.Close(); err != nil {
		t.Fatalf("close sparse file: %v", err)
	}
	if err := os.WriteFile(filepath.Join(emptyDir, "film.mkv"), make([]byte, 4096), 0o600); err != nil {
		t.Fatalf("write ungrouped file: %v", err)
	}
	// The episode itself was deleted outside the app; torrent state is left.
	if err := os.WriteFile(filepath.Join(goneDir, ".torrent.db"), make([]byte, 4096), 0o600); err != nil {
		t.Fatalf("write leftover state: %v", err)
	}
	// This belongs to the user-selected directory, not to a known download.
	if err := os.WriteFile(filepath.Join(downloadDir, "unmanaged.mkv"), make([]byte, 16384), 0o600); err != nil {
		t.Fatalf("write unmanaged file: %v", err)
	}

	now := time.Now().UTC()
	rows := []acquire.Download{
		{ID: "regular", ItemID: "series", Season: 1, Episode: 1, Name: "Release one", Dir: regularDir, FilePath: filepath.Join(regularDir, "episode.mkv"), State: acquire.StateDone, CreatedAt: now},
		{ID: "sparse", ItemID: "series", Season: 1, Episode: 2, Name: "Release two", Dir: sparseDir, FilePath: filepath.Join(sparseDir, "episode.mkv"), State: acquire.StatePaused, CreatedAt: now.Add(-time.Second)},
		{ID: "empty", Name: "Loose film", Dir: emptyDir, FilePath: filepath.Join(emptyDir, "film.mkv"), State: acquire.StateFailed, CreatedAt: now.Add(-2 * time.Second)},
		{ID: "gone", ItemID: "series", Season: 1, Episode: 3, Name: "Release three", Dir: goneDir, FilePath: filepath.Join(goneDir, "episode.mkv"), State: acquire.StateDone, CreatedAt: now.Add(-3 * time.Second)},
	}
	store := newFakeStore()
	for _, row := range rows {
		store.rows[row.ID] = row
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	manager := acquire.NewManager(downloadDir, nil, store, log)
	if err := manager.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	item := catalog.MediaItem{ID: "series", Kind: catalog.KindSeries, Title: "The Show", Poster: "https://img.example/poster.jpg"}
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: item}, log)
	handler := New(Deps{Catalog: cat, Downloads: manager, About: About{DownloadDir: downloadDir}, CacheDir: downloadDir}, log).Handler()
	return handler, manager, rows, downloadDir
}

func TestStorageReportsKnownAllocatedBytesAndCatalogMetadata(t *testing.T) {
	h, _, rows, downloadDir := storageServer(t)
	if err := os.MkdirAll(filepath.Join(downloadDir, "artwork"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(downloadDir, "artwork", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), []byte("1234567"), 0o600); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/storage", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	var got storageResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode storage: %v", err)
	}
	if got.Dir != downloadDir || got.Disk == nil || got.Disk.Total == 0 {
		t.Fatalf("storage header = %+v", got)
	}
	if got.Cache != 7 {
		t.Fatalf("artwork cache size = %d", got.Cache)
	}
	if len(got.Titles) != 2 || got.Titles[0].ItemID != "series" {
		t.Fatalf("titles = %+v", got.Titles)
	}
	// The deleted episode is not counted; Free on the title still frees it.
	if len(got.Titles[0].Downloads) != 2 {
		t.Fatalf("series downloads = %+v, want the two with a file", got.Titles[0].Downloads)
	}
	if got.Titles[0].Title != "The Show" || got.Titles[0].Poster != "https://img.example/poster.jpg" || got.Titles[0].Kind != catalog.KindSeries {
		t.Fatalf("catalog metadata = %+v", got.Titles[0])
	}
	var sum int64
	var sparseBytes int64
	for _, title := range got.Titles {
		sum += title.OnDisk
		for _, download := range title.Downloads {
			if download.ID == "sparse" {
				sparseBytes = download.OnDisk
			}
		}
	}
	leftover, err := library.Allocated(rows[3].Dir)
	if err != nil || leftover == 0 {
		t.Fatalf("measure leftover: %d, %v", leftover, err)
	}
	if got.Used != sum+leftover {
		t.Fatalf("used = %d, title sum = %d, leftover = %d", got.Used, sum, leftover)
	}
	var known int64
	for _, row := range rows {
		bytes, err := library.Allocated(row.Dir)
		if err != nil {
			t.Fatalf("measure %s: %v", row.ID, err)
		}
		known += bytes
	}
	if got.Used != known {
		t.Fatalf("used = %d, known downloads = %d", got.Used, known)
	}
	if sparseBytes <= 0 || sparseBytes >= 32<<20 {
		t.Fatalf("sparse onDisk = %d, want allocated bytes below logical size", sparseBytes)
	}
	if got.Titles[1].ItemID != "" || got.Titles[1].Title != "Loose film" {
		t.Fatalf("ungrouped title = %+v", got.Titles[1])
	}
}

func TestClearStorageRemovesOnlyRequestedItem(t *testing.T) {
	h, manager, rows, downloadDir := storageServer(t)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodDelete, "/api/v1/storage?item=series", nil))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	for _, row := range []acquire.Download{rows[0], rows[1], rows[3]} {
		if _, err := os.Stat(row.Dir); !os.IsNotExist(err) {
			t.Fatalf("download dir %s still exists: %v", row.Dir, err)
		}
	}
	if _, err := os.Stat(rows[2].Dir); err != nil {
		t.Fatalf("unrelated download was removed: %v", err)
	}
	if got := manager.List(context.Background()); len(got) != 1 || got[0].ID != "empty" {
		t.Fatalf("remaining downloads = %+v", got)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodDelete, "/api/v1/storage?item=missing", nil))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown item status = %d", rec.Code)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodDelete, "/api/v1/storage", nil))
	if rec.Code != http.StatusNoContent {
		t.Fatalf("clear all status = %d: %s", rec.Code, rec.Body)
	}
	if _, err := os.Stat(filepath.Join(downloadDir, "unmanaged.mkv")); err != nil {
		t.Fatalf("clear all removed unmanaged file: %v", err)
	}
}

// Choosing a keep policy frees what it expires before the answer, so the
// Storage list read next is already the new one.
func TestKeepPolicyFreesBeforeItAnswers(t *testing.T) {
	downloadDir := t.TempDir()
	st := newFakeStore()
	for episode := 1; episode <= 2; episode++ {
		id := "e" + strconv.Itoa(episode)
		dir := filepath.Join(downloadDir, id)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "episode.mkv")
		if err := os.WriteFile(path, make([]byte, 4096), 0o600); err != nil {
			t.Fatal(err)
		}
		st.rows[id] = acquire.Download{ID: id, ItemID: "series", Season: 1, Episode: episode, Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"}, Dir: dir, FilePath: path, Size: 4096, State: acquire.StateDone}
	}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	manager := acquire.NewManager(downloadDir, nil, st, log)
	if err := manager.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	prefs := preferences.New(db, preferences.Preferences{Keep: "forever"})
	watched := true
	if _, err := progress.New(db, nil).Put(context.Background(), "series", progress.Update{Season: 1, Episode: 1, Watched: &watched}); err != nil {
		t.Fatalf("mark watched: %v", err)
	}
	lib := library.New(manager, db, prefs, log)
	h := New(Deps{Downloads: manager, Library: lib, Preferences: prefs, About: About{DownloadDir: downloadDir}, CacheDir: t.TempDir()}, log).Handler()

	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/preferences", `{"keep":"watched"}`); rec.Code != http.StatusOK {
		t.Fatalf("patch status %d: %s", rec.Code, rec.Body)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/storage", nil))
	var got storageResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode storage: %v", err)
	}
	if len(got.Titles) != 1 || len(got.Titles[0].Downloads) != 1 || got.Titles[0].Downloads[0].ID != "e2" {
		t.Fatalf("titles = %+v, want only the unwatched episode", got.Titles)
	}
	if _, err := os.Stat(filepath.Join(downloadDir, "e1")); !os.IsNotExist(err) {
		t.Fatalf("the watched episode is still on disk: %v", err)
	}
}

// A prefetch is started only inside the disk limit; a download somebody asked
// for is started whatever the limit says.
func TestPrefetchStartsOnlyInsideTheDiskLimit(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	backend := &fakeStreamBackend{task: &fakeStreamTask{file: &fakeStreamFile{name: "e.mkv", data: payload()}}}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, newFakeStore(), log)
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	prefs := preferences.New(db, preferences.Preferences{Keep: "forever", DiskLimit: 4096})
	lib := library.New(manager, db, prefs, log)
	h := New(Deps{Downloads: manager, Library: lib, Preferences: prefs}, log).Handler()

	start := func(hash string, size int, prefetch bool) int {
		t.Helper()
		body := fmt.Sprintf(`{"itemId":"series","season":1,"episode":2,"prefetch":%t,"source":{"size":%d,"locator":{"scheme":"torrent","infoHash":%q}}}`, prefetch, size, hash)
		return requestJSON(t, h, http.MethodPost, "/api/v1/downloads", body).Code
	}
	if code := start("big", 4097, true); code != http.StatusInsufficientStorage {
		t.Fatalf("a prefetch over the limit: status %d", code)
	}
	if code := start("unknown", 0, true); code != http.StatusInsufficientStorage {
		t.Fatalf("a prefetch of unknown size: status %d", code)
	}
	if rows := manager.List(context.Background()); len(rows) != 0 {
		t.Fatalf("a refused prefetch started %+v", rows)
	}
	if code := start("fits", 4096, true); code != http.StatusCreated {
		t.Fatalf("a prefetch inside the limit: status %d", code)
	}
	if code := start("asked", 4097, false); code != http.StatusCreated {
		t.Fatalf("a download somebody asked for: status %d", code)
	}
}
