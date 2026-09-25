package api

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func src(res string, seeders int, name string) sources.MediaSource {
	return sources.MediaSource{
		RawName: name,
		Seeders: seeders,
		Release: release.Info{Resolution: res},
	}
}

// The case this ranking exists for: the sharpest copy in the list is a remux
// nobody is seeding, and starting it means watching a stalled progress bar.
func TestPlayableSourceOutranksUnwatchableOne(t *testing.T) {
	all := []sources.MediaSource{
		src("2160p", 3, "remux"),
		src("1080p", 199, "web-dl"),
		src("720p", 40, "webrip"),
	}
	rankSources(all, nil, nil)
	if all[0].RawName != "web-dl" {
		t.Errorf("default is %q, want the one with a swarm behind it", all[0].RawName)
	}
	if all[len(all)-1].RawName != "remux" {
		t.Errorf("the unseeded copy should be last, got %q", all[len(all)-1].RawName)
	}
}

func TestAmongHealthySourcesQualityWins(t *testing.T) {
	all := []sources.MediaSource{
		src("1080p", 300, "1080"),
		src("2160p", 60, "2160"),
	}
	rankSources(all, nil, nil)
	if all[0].RawName != "2160" {
		t.Errorf("default is %q, want the sharper one — both are seeded", all[0].RawName)
	}
}

func TestAmongEquallyUnhealthyOnesTheBestIsStillFirst(t *testing.T) {
	all := []sources.MediaSource{
		src("720p", 2, "720"),
		src("2160p", 1, "2160"),
		src("1080p", 3, "1080"),
	}
	rankSources(all, nil, nil)
	if all[0].RawName != "2160" {
		t.Errorf("got %q — with no swarm anywhere, ordering falls back to quality", all[0].RawName)
	}
}

// The copy that brought this in: a fresh anime episode where the only 1080p
// copy is a raw with no subtitles and the Crunchyroll rip is 720p.
func TestACopyTheViewerCanFollowOutranksASharperOne(t *testing.T) {
	raw := src("1080p", 300, "raw")
	cr := src("720p", 40, "crunchyroll")
	cr.Languages = []string{"en", "ru"}
	all := []sources.MediaSource{raw, cr}
	rankSources(all, []string{"ru"}, nil)
	if all[0].RawName != "crunchyroll" {
		t.Errorf("default is %q, want the copy with the viewer's language", all[0].RawName)
	}
}

func TestMultiSubCountsAsTheViewersLanguage(t *testing.T) {
	multi := src("720p", 40, "multi")
	multi.Release.MultiSub = true
	all := []sources.MediaSource{src("1080p", 300, "raw"), multi}
	rankSources(all, []string{"ru"}, nil)
	if all[0].RawName != "multi" {
		t.Errorf("default is %q, want the Multi Subs copy", all[0].RawName)
	}
}

// "Multi Subs" says nothing about the soundtrack.
func TestMultiSubDoesNotCountForAudioAlone(t *testing.T) {
	multi := src("720p", 40, "multi")
	multi.Release.MultiSub = true
	all := []sources.MediaSource{multi, src("1080p", 300, "sharper")}
	rankSources(all, nil, []string{"ru"})
	if all[0].RawName != "sharper" {
		t.Errorf("default is %q, want the sharper copy", all[0].RawName)
	}
}

// Language never buys a copy out of a stalled swarm.
func TestLanguageDoesNotBeatHealth(t *testing.T) {
	dead := src("1080p", 2, "dead")
	dead.Languages = []string{"ru"}
	all := []sources.MediaSource{dead, src("720p", 50, "alive")}
	rankSources(all, []string{"ru"}, nil)
	if all[0].RawName != "alive" {
		t.Errorf("default is %q, want the seeded one", all[0].RawName)
	}
}

// The preference reaches the ranking through the handler, and a regional
// code matches the bare one providers use.
func TestSourcesRankByTheStoredLanguages(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "lumeo.db"), "test")
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer db.Close()
	prefs := preferences.New(db, preferences.Preferences{SubtitleLanguages: []string{"en"}})
	if _, err := prefs.Patch(context.Background(), []byte(`{"subtitleLanguages":["pt-BR"]}`)); err != nil {
		t.Fatalf("store preferences: %v", err)
	}
	dub := src("720p", 40, "dub")
	dub.Languages = []string{"pt"}
	found := fixedSource{src("1080p", 300, "raw"), dub}
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := New(Deps{
		Sources:     func() []sources.Provider { return []sources.Provider{found} },
		Preferences: prefs,
	}, log).Handler()

	rec := requestJSON(t, h, http.MethodGet, "/api/v1/sources?imdb=tt1375666", "")
	var body struct {
		Sources []sources.MediaSource `json:"sources"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Sources) != 2 || body.Sources[0].RawName != "dub" {
		t.Fatalf("status %d, sources %+v, want dub first", rec.Code, body.Sources)
	}
}
