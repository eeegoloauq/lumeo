package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
)

func authRequest(t *testing.T, h http.Handler, path, authorization string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	req.Host = "localhost:7666"
	if authorization != "" {
		req.Header.Set("Authorization", authorization)
	}
	h.ServeHTTP(rec, req)
	return rec
}

// Another account on the machine reaches the loopback port; without the
// token it gets nothing but the pictures it cannot find the addresses of.
func TestEveryRouteButArtworkNeedsTheToken(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write([]byte("\x89PNG\r\n\x1a\nart"))
	}))
	defer upstream.Close()
	item := catalog.MediaItem{Kind: catalog.KindMovie, Title: "Film", ExternalIDs: catalog.ExternalIDs{catalog.NamespaceIMDb: "tt1"}, Poster: upstream.URL + "/poster"}
	h, _, _ := artworkServerWithToken(t, item, "secret")

	for _, path := range []string{"/healthz", "/api/v1/catalog?id=top", "/api/v1/downloads/x/stream", "/api/v1/nothing"} {
		for _, auth := range []string{"", "Bearer wrong", "secret", "Bearer secret2"} {
			got := authRequest(t, h, path, auth)
			if got.Code != http.StatusUnauthorized || got.Header().Get("WWW-Authenticate") != "Bearer" {
				t.Fatalf("%s with %q: %d %v", path, auth, got.Code, got.Header())
			}
		}
	}

	page := authRequest(t, h, "/api/v1/catalog?id=top", "Bearer secret")
	if page.Code != http.StatusOK {
		t.Fatalf("with the token: %d %s", page.Code, page.Body)
	}
	var body struct {
		Items []catalog.MediaItem `json:"items"`
	}
	if err := json.Unmarshal(page.Body.Bytes(), &body); err != nil || len(body.Items) != 1 {
		t.Fatalf("catalog body: %v %s", err, page.Body)
	}
	poster := body.Items[0].Poster
	if got := authRequest(t, h, poster, "").Code; got != http.StatusOK {
		t.Fatalf("artwork without the token: %d", got)
	}

	// The same poster under another token lives at another address.
	other, _, _ := artworkServerWithToken(t, item, "another")
	page = authRequest(t, other, "/api/v1/catalog?id=top", "Bearer another")
	if err := json.Unmarshal(page.Body.Bytes(), &body); err != nil || len(body.Items) != 1 {
		t.Fatalf("catalog body: %v %s", err, page.Body)
	}
	if body.Items[0].Poster == poster || !strings.Contains(poster, "/api/v1/artwork/") {
		t.Fatalf("artwork keys do not depend on the token: %s, %s", poster, body.Items[0].Poster)
	}
}
