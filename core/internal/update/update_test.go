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
	got, err := c.Newer(context.Background(), time.Now())
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
		if got, err := c.Newer(context.Background(), time.Now()); err != nil || got != nil {
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
		if got, _ := c.Newer(context.Background(), at); got == nil {
			t.Fatal("no release")
		}
	}
	if *asked != 2 {
		t.Fatalf("%d requests within a day, want 2", *asked)
	}
	_, _ = c.Newer(context.Background(), now.Add(25*time.Hour))
	if *asked != 4 {
		t.Fatalf("%d requests after a day, want 4", *asked)
	}
}

func TestFailureIsTriedAgainAfterAnHour(t *testing.T) {
	c, asked := github(t, "not-a-version")
	now := time.Now()
	if _, err := c.Newer(context.Background(), now); err == nil {
		t.Fatal("no error for a tag that is not a version")
	}
	_, _ = c.Newer(context.Background(), now.Add(30*time.Minute))
	if *asked != 1 {
		t.Fatalf("%d requests within the hour, want 1", *asked)
	}
	_, _ = c.Newer(context.Background(), now.Add(61*time.Minute))
	if *asked != 2 {
		t.Fatalf("%d requests after the hour, want 2", *asked)
	}
}

func TestCheckoutNeverAsks(t *testing.T) {
	c, asked := github(t, "v0.1.70")
	c.version = "dev"
	if got, err := c.Newer(context.Background(), time.Now()); got != nil || err != nil || *asked != 0 {
		t.Fatalf("release = %+v, err = %v, requests = %d", got, err, *asked)
	}
}

func TestBetaIsOfferedItsRelease(t *testing.T) {
	c, _ := github(t, "v0.1.70")
	c.version = "0.1.70-beta.2"
	if got, err := c.Newer(context.Background(), time.Now()); err != nil || got == nil || got.Version != "0.1.70" {
		t.Fatalf("release = %+v, err = %v", got, err)
	}

	c, _ = github(t, "v0.1.69")
	c.version = "0.1.70-beta.1"
	if got, err := c.Newer(context.Background(), time.Now()); err != nil || got != nil {
		t.Fatalf("older release offered to a beta: %+v, err = %v", got, err)
	}
}
