package stremio

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

// What the file is, not what the film is: hash, size and name go into the
// request, because that is the difference between subtitles in sync and a
// list of everything ever uploaded for the title.
func TestSubtitlesSendsTheFileBeingPlayed(t *testing.T) {
	var path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.EscapedPath()
		// Shape taken from a real OpenSubtitles v3 response.
		_, _ = w.Write([]byte(`{"subtitles":[
			{"id":"1","url":"https://subs5.strem.io/ru/download/file/1","SubEncoding":"CP1251","lang":"rus","m":"i","g":"6",
			 "subtitleFileName":"Severance.S02E03.WEBRip.srt","movieReleaseName":"Severance.S02E03.WEBRip","releaseGroup":"","fpsMilli":25000,"season":2,"episode":3},
			{"id":"2","url":"https://subs5.strem.io/en/download/file/2","SubEncoding":"UTF-8","lang":"eng","m":"h","g":"8",
			 "subtitleFileName":"Severance.S02E03.1080p.WEB.H264-SuccessfulCrab.srt","movieReleaseName":"Severance.S02E03.1080p.WEB.H264-SuccessfulCrab","releaseGroup":"SuccessfulCrab","fpsMilli":23976,"season":2,"episode":3}
		]}`))
	}))
	defer srv.Close()

	got, err := New("os", "OpenSubtitles", srv.URL).Subtitles(context.Background(), subtitles.Query{
		Kind:      catalog.KindSeries,
		IMDbID:    "tt11280740",
		Season:    2,
		Episode:   3,
		VideoHash: "8e245d9679d31e12",
		VideoSize: 1467265246,
		Filename:  "Severance S02E03.mkv",
	})
	if err != nil {
		t.Fatalf("subtitles: %v", err)
	}

	want := "/subtitles/series/tt11280740:2:3/videoHash=8e245d9679d31e12&videoSize=1467265246&filename=Severance%20S02E03.mkv.json"
	if path != want {
		t.Errorf("path:\n got %q\nwant %q", path, want)
	}
	if len(got) != 2 {
		t.Fatalf("got %d subtitles, want 2", len(got))
	}
	if got[0].Language != "ru" || got[0].Encoding != "CP1251" || got[0].Format != "srt" {
		t.Errorf("first: %+v", got[0])
	}
	if got[0].HashMatch || got[0].FPS != 25 {
		t.Errorf("first: matched by title at 25 fps, got %+v", got[0])
	}
	if got[1].Language != "en" || got[1].LanguageName != "English" {
		t.Errorf("second: %+v", got[1])
	}
	// "m":"h" is the addon saying the video hash matched — the one fact that
	// makes a subtitle certainly in sync, and it is not in the protocol.
	if !got[1].HashMatch || got[1].FPS != 23.976 {
		t.Errorf("second: hash match at 23.976 fps, got %+v", got[1])
	}
	if got[1].Name != "Severance.S02E03.1080p.WEB.H264-SuccessfulCrab" {
		t.Errorf("name: %q", got[1].Name)
	}
	if got[0].SourceURL != "https://subs5.strem.io/ru/download/file/1" {
		t.Errorf("source url: %q", got[0].SourceURL)
	}
}

// A film has no episode, and a core that has not started downloading yet has
// no hash — the lookup still has to work on the id alone.
func TestSubtitlesWithoutAFileAsksByIDAlone(t *testing.T) {
	var path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.EscapedPath()
		_, _ = w.Write([]byte(`{"subtitles":[]}`))
	}))
	defer srv.Close()

	if _, err := New("os", "OpenSubtitles", srv.URL).Subtitles(context.Background(), subtitles.Query{
		Kind:   catalog.KindMovie,
		IMDbID: "tt15239678",
	}); err != nil {
		t.Fatalf("subtitles: %v", err)
	}
	if want := "/subtitles/movie/tt15239678.json"; path != want {
		t.Errorf("path: got %q, want %q", path, want)
	}
}
