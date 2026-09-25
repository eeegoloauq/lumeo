package subtitles

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/release"
)

type stubProvider struct {
	id   string
	got  Query
	subs []Subtitle
	err  error
}

func (p *stubProvider) ID() string   { return p.id }
func (p *stubProvider) Name() string { return p.id }
func (p *stubProvider) Subtitles(_ context.Context, q Query) ([]Subtitle, error) {
	p.got = q
	return p.subs, p.err
}

func testService(providers ...Provider) *Service {
	return NewService(func() []Provider { return providers }, []string{"en"}, slog.New(slog.NewTextHandler(io.Discard, nil)))
}

// The viewer's languages come first, in the order they asked for them, and
// what is left keeps the provider's own order — which for a hash-aware
// database is the matching copies first.
func TestFindRanksByLanguagePreference(t *testing.T) {
	p := &stubProvider{id: "os", subs: []Subtitle{
		{ProviderID: "os", Language: "fr", SourceURL: "https://x/fr.srt"},
		{ProviderID: "os", Language: "en", SourceURL: "https://x/en.srt"},
		{ProviderID: "os", Language: "ru", SourceURL: "https://x/ru.srt"},
	}}
	got := testService(p).Find(context.Background(), Query{Languages: []string{"ru", "en"}})

	want := []string{"ru", "en", "fr"}
	if len(got) != len(want) {
		t.Fatalf("got %d subtitles, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Language != want[i] {
			t.Fatalf("order: got %v, want %v", languagesOf(got), want)
		}
	}
}

// Inside one language, the copy that names the release being played wins:
// subtitles are timed to an encode, not to a film.
func TestFindPrefersTheReleaseBeingPlayed(t *testing.T) {
	p := &stubProvider{id: "os", subs: []Subtitle{
		{ProviderID: "os", Language: "en", Name: "Dune.Part.Two.2024.720p.WEBRip", SourceURL: "https://x/1.srt"},
		{ProviderID: "os", Language: "en", Name: "Dune.Part.Two.2024.2160p.BluRay-CINEPHILES", SourceURL: "https://x/2.srt"},
	}}
	got := testService(p).Find(context.Background(), Query{
		Languages: []string{"en"},
		Release:   release.Parse("Dune.Part.Two.2024.2160p.BluRay.x265-CINEPHILES"),
	})
	if len(got) != 2 || !strings.Contains(got[0].Name, "CINEPHILES") {
		t.Fatalf("got %v", namesOf(got))
	}
}

// Inside a language a hash match is certainty and a name is a guess, so it
// goes first — but it never jumps ahead of the language the viewer reads.
func TestFindPutsHashMatchesFirstWithinALanguage(t *testing.T) {
	p := &stubProvider{id: "os", subs: []Subtitle{
		{Language: "en", Name: "Dune.Part.Two.2024.2160p.BluRay-CINEPHILES", SourceURL: "https://x/1.srt"},
		{Language: "en", Name: "Dune.Part.Two.2024.720p.WEBRip", SourceURL: "https://x/2.srt", HashMatch: true},
		{Language: "ru", Name: "Dune.Part.Two.2024.2160p.BluRay-CINEPHILES", SourceURL: "https://x/3.srt", HashMatch: true},
	}}
	got := testService(p).Find(context.Background(), Query{
		Languages: []string{"en"},
		Release:   release.Parse("Dune.Part.Two.2024.2160p.BluRay.x265-CINEPHILES"),
	})
	if len(got) != 3 {
		t.Fatalf("got %d subtitles", len(got))
	}
	if !got[0].HashMatch || got[0].Language != "en" {
		t.Errorf("first: got %+v", got[0])
	}
	if got[2].Language != "ru" {
		t.Errorf("a hash match in a language nobody asked for still ranks last: got %v", languagesOf(got))
	}
}

// The same upload under several ids is what OpenSubtitles actually returns,
// and a picker showing one file five times is unusable.
func TestFindDropsTheSameUploadUnderDifferentIDs(t *testing.T) {
	p := &stubProvider{id: "os", subs: []Subtitle{
		{ProviderID: "os", Language: "en", Name: "breakdance2.srt", SourceURL: "https://x/file/1"},
		{ProviderID: "os", Language: "en", Name: "breakdance2.srt", SourceURL: "https://x/file/2"},
	}}
	if got := testService(p).Find(context.Background(), Query{}); len(got) != 1 {
		t.Fatalf("got %d subtitles, want 1", len(got))
	}
}

// A dead provider costs its own results. Subtitles arrive after playback has
// started, so there is nothing here worth failing a request over.
func TestFindSurvivesAFailingProvider(t *testing.T) {
	dead := &stubProvider{id: "dead", err: errors.New("502")}
	live := &stubProvider{id: "live", subs: []Subtitle{{Language: "en", SourceURL: "https://x/en.srt"}}}
	if got := testService(dead, live).Find(context.Background(), Query{}); len(got) != 1 {
		t.Fatalf("got %d subtitles, want 1", len(got))
	}
}

// Two providers indexing the same database is the normal case, and the same
// file twice in a picker is noise.
func TestFindDropsDuplicatesAndUnplayables(t *testing.T) {
	a := &stubProvider{id: "a", subs: []Subtitle{{Language: "en", SourceURL: "https://x/en.srt"}}}
	b := &stubProvider{id: "b", subs: []Subtitle{
		{Language: "en", SourceURL: "https://x/en.srt"},
		{Language: "en"}, // no url: nothing to play
	}}
	if got := testService(a, b).Find(context.Background(), Query{}); len(got) != 1 {
		t.Fatalf("got %d subtitles, want 1", len(got))
	}
}

// The provider's URL must never reach the client: what it gets back is an id
// of ours, and that id is the only thing the fetch endpoint accepts.
func TestFindHandsOutCoreURLsOnly(t *testing.T) {
	p := &stubProvider{id: "os", subs: []Subtitle{{Language: "en", SourceURL: "https://opensubtitles/1.srt"}}}
	got := testService(p).Find(context.Background(), Query{})
	if len(got) != 1 {
		t.Fatalf("got %d subtitles", len(got))
	}
	if !strings.HasPrefix(got[0].URL, "/api/v1/subtitles/") || strings.Contains(got[0].URL, "opensubtitles") {
		t.Errorf("url: got %q", got[0].URL)
	}
}

func TestFetchConvertsToUTF8(t *testing.T) {
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte{0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2}) // windows-1251
	}))
	defer origin.Close()

	p := &stubProvider{id: "os", subs: []Subtitle{
		{Language: "ru", SourceURL: origin.URL + "/1.srt", Encoding: "CP1251"},
	}}
	s := testService(p)
	found := s.Find(context.Background(), Query{})
	token := strings.TrimPrefix(found[0].URL, "/api/v1/subtitles/")

	text, err := s.Fetch(context.Background(), token)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if string(text.Body) != "Привет" {
		t.Errorf("body: got %q", text.Body)
	}
	if text.Format != "srt" {
		t.Errorf("format: got %q", text.Format)
	}
}

func TestFetchRefusesAnythingItDidNotHandOut(t *testing.T) {
	s := testService()
	if _, err := s.Fetch(context.Background(), "0123456789abcdef"); !errors.Is(err, ErrUnknownToken) {
		t.Errorf("got %v, want ErrUnknownToken", err)
	}
}

func languagesOf(subs []Subtitle) []string {
	out := make([]string, len(subs))
	for i, s := range subs {
		out[i] = s.Language
	}
	return out
}

func namesOf(subs []Subtitle) []string {
	out := make([]string, len(subs))
	for i, s := range subs {
		out[i] = s.Name
	}
	return out
}
