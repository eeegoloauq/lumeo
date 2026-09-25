package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

type fixedSource []sources.MediaSource

func (fixedSource) ID() string   { return "fixed" }
func (fixedSource) Name() string { return "fixed" }
func (f fixedSource) Find(context.Context, sources.Query) ([]sources.MediaSource, error) {
	return append([]sources.MediaSource(nil), f...), nil
}

func torrentSource(name, hash string, seeders int, binge string) sources.MediaSource {
	return sources.MediaSource{
		RawName:    name,
		Seeders:    seeders,
		Release:    release.Info{Resolution: "1080p"},
		BingeGroup: binge,
		Locator:    sources.Locator{Scheme: "torrent", InfoHash: hash},
	}
}

func choiceServer(t *testing.T, rows []acquire.Download, found fixedSource) (http.Handler, *progress.Service) {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	downloads := newFakeStore()
	for _, row := range rows {
		downloads.rows[row.ID] = row
	}
	// A failed download is started again at boot; this one fails again.
	backend := &fakeStreamBackend{
		task:   &fakeStreamTask{file: &fakeStreamFile{name: "e.mkv", data: payload()}},
		refuse: map[string]bool{"failed": true},
	}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, downloads, log)
	if err := manager.Resume(context.Background()); err != nil {
		t.Fatalf("resume: %v", err)
	}
	cat := catalog.NewService(catalog.Fixed(stubMeta{}), &stubStore{item: severance()}, log)
	watch := progress.New(db, cat)
	h := New(Deps{
		Sources:   func() []sources.Provider { return []sources.Provider{found} },
		Catalog:   cat,
		Downloads: manager,
		Progress:  watch,
	}, log).Handler()
	return h, watch
}

func listSources(t *testing.T, h http.Handler) []listedSource {
	t.Helper()
	rec := requestJSON(t, h, http.MethodGet, "/api/v1/sources?item=abc123&season=1&episode=2", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	var body struct {
		Sources []listedSource `json:"sources"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return body.Sources
}

// sourceNames is each copy as "name local lastUsed".
func sourceNames(t *testing.T, h http.Handler) []string {
	t.Helper()
	var names []string
	for _, s := range listSources(t, h) {
		names = append(names, fmt.Sprint(s.RawName, " ", s.Local, " ", s.LastUsed))
	}
	return names
}

// The report this order answers: leaving the player gave the ranking's best
// again, and an episode already on disk was passed over for a fresh copy.
func TestSourcesPutWhatTheLibraryChoseAheadOfTheRanking(t *testing.T) {
	now := time.Now().UTC()
	onDisk := filepath.Join(t.TempDir(), "e.mkv")
	if err := os.WriteFile(onDisk, []byte("whole"), 0o600); err != nil {
		t.Fatal(err)
	}
	rows := []acquire.Download{
		{ID: "done", ItemID: "abc123", Locator: sources.Locator{Scheme: "torrent", InfoHash: "disk"}, State: acquire.StateDone, FilePath: onDisk, CreatedAt: now},
		{ID: "half", ItemID: "abc123", Locator: sources.Locator{Scheme: "torrent", InfoHash: "half"}, State: acquire.StatePaused, CreatedAt: now},
		{ID: "failed", ItemID: "abc123", Locator: sources.Locator{Scheme: "torrent", InfoHash: "failed"}, State: acquire.StateFailed, CreatedAt: now},
	}
	h, watch := choiceServer(t, rows, fixedSource{
		torrentSource("best", "best", 900, "other"),
		torrentSource("failed", "failed", 800, ""),
		torrentSource("pack", "pack", 10, "group|1080p"),
		torrentSource("half", "half", 20, ""),
		torrentSource("disk", "disk", 5, ""),
	})

	if got := sourceNames(t, h); got[0] != "disk done false" || got[1] != "half partial false" || got[2] != "best  false" {
		t.Fatalf("without a remembered pack: %v", got)
	}
	if err := watch.RememberSource(context.Background(), "abc123", "group|1080p"); err != nil {
		t.Fatalf("remember: %v", err)
	}
	want := []string{"disk done false", "half partial false", "pack  true", "best  false", "failed  false"}
	got := sourceNames(t, h)
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order = %v, want %v", got, want)
		}
	}
}

// Seen 2026-09-23: with Torrentio answering 403, episodes on disk could not
// be opened, because only the provider's list named them.
func TestSourcesListWhatIsOnDiskWhenNoProviderDoes(t *testing.T) {
	now := time.Now().UTC()
	onDisk := filepath.Join(t.TempDir(), "e.mkv")
	if err := os.WriteFile(onDisk, []byte("whole"), 0o600); err != nil {
		t.Fatal(err)
	}
	rows := []acquire.Download{
		{ID: "done", ItemID: "abc123", Season: 1, Episode: 2, Name: "done", Locator: sources.Locator{Scheme: "torrent", InfoHash: "disk"}, State: acquire.StateDone, FilePath: onDisk, CreatedAt: now},
		{ID: "half", ItemID: "abc123", Season: 1, Episode: 2, Name: "half", Locator: sources.Locator{Scheme: "torrent", InfoHash: "half"}, State: acquire.StatePaused, CreatedAt: now},
		{ID: "failed", ItemID: "abc123", Season: 1, Episode: 2, Name: "failed", Locator: sources.Locator{Scheme: "torrent", InfoHash: "failed"}, State: acquire.StateFailed, CreatedAt: now},
		{ID: "other", ItemID: "abc123", Season: 1, Episode: 3, Name: "other", Locator: sources.Locator{Scheme: "torrent", InfoHash: "other"}, State: acquire.StateDone, FilePath: onDisk, CreatedAt: now},
	}
	h, watch := choiceServer(t, rows, fixedSource{torrentSource("half", "half", 20, "")})
	got := sourceNames(t, h)
	if len(got) != 2 || got[0] != "done done false" || got[1] != "half partial false" {
		t.Fatalf("sources = %v", got)
	}

	if err := watch.RememberSource(context.Background(), "abc123", "group|1080p"); err != nil {
		t.Fatalf("remember: %v", err)
	}
	rec := requestJSON(t, h, http.MethodPost, "/api/v1/downloads",
		`{"itemId":"abc123","season":1,"episode":2,"source":{"providerId":"local","locator":{"scheme":"torrent","infoHash":"disk"}}}`)
	if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Fatalf("start: status %d: %s", rec.Code, rec.Body)
	}
	if choice, _ := watch.Choice(context.Background(), "abc123"); choice.BingeGroup != "group|1080p" {
		t.Fatalf("replaying a copy from disk forgot the pack: %+v", choice)
	}
}

func TestStartingADownloadRemembersItsPack(t *testing.T) {
	h, watch := choiceServer(t, nil, nil)
	rec := requestJSON(t, h, http.MethodPost, "/api/v1/downloads",
		`{"itemId":"abc123","season":1,"episode":1,"source":{"bingeGroup":"group|1080p","locator":{"scheme":"torrent","infoHash":"e1"}}}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	choice, err := watch.Choice(context.Background(), "abc123")
	if err != nil || choice.BingeGroup != "group|1080p" {
		t.Fatalf("choice = %+v, %v", choice, err)
	}
}

// Tracks are one record per title with the pack, so a pick in one episode
// holds in the next, and neither half overwrites the other.
func TestChoicePatchKeepsThePackAndTheOtherTrack(t *testing.T) {
	h, watch := choiceServer(t, nil, nil)
	if err := watch.RememberSource(context.Background(), "abc123", "group|1080p"); err != nil {
		t.Fatalf("remember: %v", err)
	}
	for _, body := range []string{
		`{"audio":{"language":"jpn","title":"Japanese"}}`,
		`{"subtitle":{"language":"eng","title":"English Honorifics"}}`,
	} {
		if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/choices/abc123", body); rec.Code != http.StatusOK {
			t.Fatalf("patch %s: status %d: %s", body, rec.Code, rec.Body)
		}
	}
	rec := requestJSON(t, h, http.MethodGet, "/api/v1/choices/abc123", "")
	var got progress.Choice
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.BingeGroup != "group|1080p" ||
		got.Audio == nil || *got.Audio != (progress.Track{Language: "jpn", Title: "Japanese"}) ||
		got.Subtitle == nil || *got.Subtitle != (progress.Track{Language: "eng", Title: "English Honorifics"}) {
		t.Fatalf("choice = %+v audio=%+v subtitle=%+v", got, got.Audio, got.Subtitle)
	}

	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/choices/abc123", `{"subtitle":{"off":true,"language":"eng"}}`); rec.Code != http.StatusOK {
		t.Fatalf("turn off: status %d: %s", rec.Code, rec.Body)
	}
	got, _ = watch.Choice(context.Background(), "abc123")
	if got.Subtitle == nil || *got.Subtitle != (progress.Track{Off: true}) || got.Audio == nil {
		t.Fatalf("after turning off: audio=%+v subtitle=%+v", got.Audio, got.Subtitle)
	}

	if rec := requestJSON(t, h, http.MethodPatch, "/api/v1/choices/abc123", `{"audio":{"off":true}}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("audio off: status %d, want 400", rec.Code)
	}
}
