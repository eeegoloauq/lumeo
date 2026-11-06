package stremio

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/egress"
)

// Installing a local addon permits that origin, not every other service
// reachable from the core. An addon controls its redirect responses.
func TestAddonCannotRedirectIntoAnotherLocalService(t *testing.T) {
	var hits atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		io.WriteString(w, `{"id":"private-service"}`)
	}))
	defer target.Close()
	addon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+"/manifest.json", http.StatusFound)
	}))
	defer addon.Close()
	_, err := New("test", "Test", addon.URL).RefreshManifest(context.Background())
	if !errors.Is(err, egress.ErrPrivateAddress) || hits.Load() != 0 {
		t.Fatalf("redirect reached a private service: hits=%d, err=%v", hits.Load(), err)
	}
}

func TestAddonCanRedirectWithinItsConfiguredOrigin(t *testing.T) {
	addon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/manifest.json" {
			http.Redirect(w, r, "/moved/manifest.json", http.StatusFound)
			return
		}
		io.WriteString(w, `{"id":"local-addon"}`)
	}))
	defer addon.Close()
	manifest, err := New("test", "Test", addon.URL).RefreshManifest(context.Background())
	if err != nil || manifest.ID != "local-addon" {
		t.Fatalf("same-origin manifest: %+v, %v", manifest, err)
	}
}

type redirectRoundTrip func(*http.Request) (*http.Response, error)

func (f redirectRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// CDN/public redirects remain usable; the protected transport makes the
// public-address decision, including DNS, rather than the addon transport.
func TestAddonRedirectUsesPublicTransportForAnotherOrigin(t *testing.T) {
	old := egress.Addressed
	t.Cleanup(func() { egress.Addressed = old })
	var hits atomic.Int32
	egress.Addressed = redirectRoundTrip(func(r *http.Request) (*http.Response, error) {
		hits.Add(1)
		if r.URL.String() != "https://cdn.example/manifest.json" {
			t.Errorf("public destination: %s", r.URL)
		}
		return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader(`{"id":"public-addon"}`)), Request: r}, nil
	})
	addon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "https://cdn.example/manifest.json", http.StatusFound)
	}))
	defer addon.Close()
	manifest, err := New("test", "Test", addon.URL).RefreshManifest(context.Background())
	if err != nil || manifest.ID != "public-addon" || hits.Load() != 1 {
		t.Fatalf("public redirect: %+v, %v, hits=%d", manifest, err, hits.Load())
	}
}
