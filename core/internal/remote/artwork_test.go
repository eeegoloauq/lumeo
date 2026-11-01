package remote

import (
	"context"
	"encoding/pem"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
)

// The server's images come over the link: to its own certificate on a
// private address, which the check on addon artwork refuses, and without
// the credential. Nothing but its artwork route goes that way.
func TestTheServersArtworkComesOverTheLink(t *testing.T) {
	const key, fallback = "0123456789abcdef0123456789abcdef", "fedcba9876543210fedcba9876543210"
	cert := certificateFor(t, "127.0.0.1")
	var credential string
	server := startTLS(t, cert, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		credential = r.Header.Get("Authorization")
		if r.URL.Path != "/api/v1/artwork/"+key {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte("\xff\xd8\xff"))
	}))
	s := New(Link{URL: server.URL, Token: "credential",
		Certificate: string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Certificate[0]}))},
		slog.New(slog.DiscardHandler))

	for _, raw := range []string{server.URL + "/api/v1/artwork/" + key, server.URL + "/api/v1/artwork/" + key + "?or=" + fallback} {
		resp, err := s.FetchArtwork(context.Background(), raw)
		if err != nil {
			t.Fatalf("%s: %v", raw, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK || string(body) != "\xff\xd8\xff" {
			t.Fatalf("%s: status %d", raw, resp.StatusCode)
		}
		if credential != "" {
			t.Fatalf("the credential went with an image: %q", credential)
		}
	}

	host := strings.TrimPrefix(server.URL, "https://")
	for _, raw := range []string{
		"https://127.0.0.2:1/api/v1/artwork/" + key,
		"http://" + host + "/api/v1/artwork/" + key,
		"https://user@" + host + "/api/v1/artwork/" + key,
		server.URL + "/api/v1/downloads",
		server.URL + "/api/v1/artwork/../downloads/" + key,
		server.URL + "/api/v1/artwork/%2e%2e/" + key[6:],
		server.URL + "/api/v1/artwork/" + key[1:],
		server.URL + "/api/v1/artwork/" + strings.ToUpper(key),
		server.URL + "/api/v1/artwork/" + key + "/x",
		server.URL + "/api/v1/artwork/" + key + "?or=" + fallback + "&or=" + fallback,
		server.URL + "/api/v1/artwork/" + key + "?or=" + fallback + "&x=1",
		server.URL + "/api/v1/artwork/" + key + "?x=" + fallback,
		server.URL + "/api/v1/artwork/" + key + "?",
		server.URL + "/api/v1/artwork/" + key + "#x",
	} {
		if s.Artwork(raw) {
			t.Errorf("%s taken for the server's artwork", raw)
		}
		if resp, err := s.FetchArtwork(context.Background(), raw); err == nil {
			resp.Body.Close()
			t.Errorf("%s fetched over the link", raw)
		}
	}
}
