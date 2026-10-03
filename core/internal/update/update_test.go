package update

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const notes = `<component><releases><release version="0.1.70"/></releases></component>`

// github answers as GitHub does for a latest release tagged tag, and counts
// what it was asked.
func github(t *testing.T, tag string) (*Checker, *int) {
	t.Helper()
	asked := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked++
		switch r.URL.Path {
		case "/repos/eeegoloauq/lumeo/releases/latest":
			_, _ = w.Write([]byte(`{"tag_name":"` + tag + `","html_url":"https://example.org/` + tag + `"}`))
		case "/eeegoloauq/lumeo/" + tag + "/client/assets/dev.lumeo.lumeo.metainfo.xml":
			_, _ = w.Write([]byte(notes))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	c := New("0.1.68")
	c.API, c.Raw = server.URL, server.URL
	return c, &asked
}

func TestNewerReleaseComesWithItsNotes(t *testing.T) {
	c, _ := github(t, "v0.1.70")
	got, err := c.Newer(context.Background(), time.Now(), false)
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Version != "0.1.70" || got.URL != "https://example.org/v0.1.70" || got.Notes != notes {
		t.Fatalf("release = %+v", got)
	}
}

func TestSameOrOlderIsNothing(t *testing.T) {
	for _, tag := range []string{"v0.1.68", "v0.1.9", "v0.0.99"} {
		c, asked := github(t, tag)
		if got, err := c.Newer(context.Background(), time.Now(), false); err != nil || got != nil {
			t.Fatalf("%s: release = %+v, err = %v", tag, got, err)
		}
		if *asked != 1 {
			t.Fatalf("%s: %d requests, want only the latest release", tag, *asked)
		}
	}
}

func TestAnswerIsKeptForADay(t *testing.T) {
	c, asked := github(t, "v0.1.70")
	now := time.Now()
	for _, at := range []time.Time{now, now.Add(23 * time.Hour)} {
		if got, _ := c.Newer(context.Background(), at, false); got == nil {
			t.Fatal("no release")
		}
	}
	if *asked != 2 {
		t.Fatalf("%d requests within a day, want 2", *asked)
	}
	_, _ = c.Newer(context.Background(), now.Add(25*time.Hour), false)
	if *asked != 4 {
		t.Fatalf("%d requests after a day, want 4", *asked)
	}
}

func TestFailureIsTriedAgainAfterAnHour(t *testing.T) {
	c, asked := github(t, "not-a-version")
	now := time.Now()
	if _, err := c.Newer(context.Background(), now, false); err == nil {
		t.Fatal("no error for a tag that is not a version")
	}
	_, _ = c.Newer(context.Background(), now.Add(30*time.Minute), false)
	if *asked != 1 {
		t.Fatalf("%d requests within the hour, want 1", *asked)
	}
	_, _ = c.Newer(context.Background(), now.Add(61*time.Minute), false)
	if *asked != 2 {
		t.Fatalf("%d requests after the hour, want 2", *asked)
	}
}

func TestCheckoutNeverAsks(t *testing.T) {
	c, asked := github(t, "v0.1.70")
	c.version = "dev"
	if got, err := c.Newer(context.Background(), time.Now(), false); got != nil || err != nil || *asked != 0 {
		t.Fatalf("release = %+v, err = %v, requests = %d", got, err, *asked)
	}
}

func TestBetaIsOfferedItsRelease(t *testing.T) {
	c, _ := github(t, "v0.1.70")
	c.version = "0.1.70-beta.2"
	if got, err := c.Newer(context.Background(), time.Now(), false); err != nil || got == nil || got.Version != "0.1.70" {
		t.Fatalf("release = %+v, err = %v", got, err)
	}

	c, _ = github(t, "v0.1.69")
	c.version = "0.1.70-beta.1"
	if got, err := c.Newer(context.Background(), time.Now(), false); err != nil || got != nil {
		t.Fatalf("older release offered to a beta: %+v, err = %v", got, err)
	}
}

func TestBetasAreOfferedWhenAskedFor(t *testing.T) {
	asked := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		asked = r.URL.Path
		switch r.URL.Path {
		case "/repos/eeegoloauq/lumeo/releases":
			// Newest by date first: a fix to an older line came last.
			_, _ = w.Write([]byte(`[
				{"tag_name":"v0.1.69","html_url":"u69"},
				{"tag_name":"v0.1.70-beta.10","html_url":"u70b10"},
				{"tag_name":"v0.1.70-beta.9","html_url":"u70b9"},
				{"tag_name":"v0.1.71-beta.1","html_url":"draft","draft":true}]`))
		case "/eeegoloauq/lumeo/v0.1.70-beta.10/client/assets/dev.lumeo.lumeo.metainfo.xml":
			_, _ = w.Write([]byte(notes))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(server.Close)
	for _, running := range []string{"0.1.68", "0.1.70-beta.9"} {
		c := New(running)
		c.API, c.Raw = server.URL, server.URL
		got, err := c.Newer(context.Background(), time.Now(), true)
		if err != nil || got == nil || got.Version != "0.1.70-beta.10" || got.URL != "u70b10" {
			t.Fatalf("%s: release = %+v, err = %v (last asked %s)", running, got, err, asked)
		}
	}
	c := New("0.1.70-beta.10")
	c.API, c.Raw = server.URL, server.URL
	if got, err := c.Newer(context.Background(), time.Now(), true); err != nil || got != nil {
		t.Fatalf("the running beta offered: %+v, err = %v", got, err)
	}
}

func TestVersions(t *testing.T) {
	for _, bad := range []string{"0.1", "0.1.2.3", "0.1.2-rc.1", "0.1.2-beta", "dev"} {
		if _, ok := parse(bad); ok {
			t.Errorf("parse(%q) accepted", bad)
		}
	}
	a, _ := parse("0.1.70-beta.2")
	b, _ := parse("0.1.70-beta.10")
	r, _ := parse("v0.1.70")
	if !newer(b, a) || !newer(r, b) {
		t.Fatalf("order: %v %v %v", a, b, r)
	}
	if !IsBeta("0.1.70-beta.2") || IsBeta("v0.1.70") || IsBeta("dev") {
		t.Fatal("IsBeta")
	}
}
