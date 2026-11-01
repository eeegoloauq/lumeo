package remote

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/selfsigned"
)

const testCode = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

// tlsServer is a media server with its own certificate for host, pairing as
// the real one does: by a proof of the code over that certificate. It keeps
// every request body it was sent.
type tlsServer struct {
	*httptest.Server
	cert tls.Certificate

	mu     sync.Mutex
	bodies []string
}

func certificateFor(t *testing.T, host string) tls.Certificate {
	t.Helper()
	cert, _, err := selfsigned.Load(filepath.Join(t.TempDir(), "tls"), host)
	if err != nil {
		t.Fatal(err)
	}
	return cert
}

func startTLS(t *testing.T, cert tls.Certificate, handler http.Handler) *httptest.Server {
	t.Helper()
	server := httptest.NewUnstartedServer(handler)
	server.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	server.StartTLS()
	t.Cleanup(server.Close)
	return server
}

func newTLSServer(t *testing.T, host string) *tlsServer {
	s := &tlsServer{cert: certificateFor(t, host)}
	s.Server = startTLS(t, s.cert, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.bodies = append(s.bodies, string(body))
		s.mu.Unlock()
		w.Header().Set(ModeHeader, ModeMedia)
		switch {
		case r.URL.Path == "/healthz" && r.Header.Get("Authorization") == "Bearer credential":
			w.WriteHeader(http.StatusOK)
		case r.URL.Path == "/api/v1/pair":
			var sent struct{ Proof string }
			_ = json.Unmarshal(body, &sent)
			if !ProofHolds(DeviceProof(testCode, s.cert.Certificate[0]), sent.Proof) {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			w.WriteHeader(http.StatusCreated)
			_ = json.NewEncoder(w).Encode(map[string]string{"token": "credential", "mode": ModeMedia,
				"proof": ServerProof(testCode, s.cert.Certificate[0])})
		default:
			w.WriteHeader(http.StatusUnauthorized)
		}
	}))
	return s
}

func (s *tlsServer) sent(t *testing.T, text string) bool {
	t.Helper()
	s.mu.Lock()
	defer s.mu.Unlock()
	return strings.Contains(strings.Join(s.bodies, "\n"), text)
}

// A server whose certificate no authority vouches for is paired by proof:
// the code itself never leaves this machine, and the link pins the
// certificate, which is all it trusts from then on.
func TestPairPinsTheServersOwnCertificate(t *testing.T) {
	server := newTLSServer(t, "127.0.0.1")
	link, err := Pair(context.Background(), server.URL, testCode, "laptop")
	if err != nil {
		t.Fatal(err)
	}
	if server.sent(t, testCode) {
		t.Fatal("the code was sent")
	}
	block, _ := pem.Decode([]byte(link.Certificate))
	if link.Token != "credential" || block == nil || !bytes.Equal(block.Bytes, server.cert.Certificate[0]) {
		t.Fatalf("link %+v does not pin the server's certificate", link)
	}
	dir := t.TempDir()
	if err := Save(dir, link); err != nil {
		t.Fatal(err)
	}
	if loaded, _, err := Load(dir); err != nil || loaded != link {
		t.Fatalf("loaded %+v, %v", loaded, err)
	}
	if err := Verify(context.Background(), link); err != nil {
		t.Fatalf("the pinned link does not reach its server: %v", err)
	}
	// Another server at the same address, with a certificate of its own, is
	// not the one pinned.
	impostor := newTLSServer(t, "127.0.0.1")
	moved := link
	moved.URL = impostor.URL
	if err := Verify(context.Background(), moved); err == nil {
		t.Fatal("a pinned link took another certificate")
	}
}

// Something in between that shows its own certificate and passes everything
// on gets a proof over its certificate, which the server turns down, and
// never the code.
func TestPairingThroughSomethingInBetweenFails(t *testing.T) {
	server := newTLSServer(t, "127.0.0.1")
	target, _ := url.Parse(server.URL)
	relay := httputil.NewSingleHostReverseProxy(target)
	relay.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	var seen bytes.Buffer
	between := startTLS(t, certificateFor(t, "127.0.0.1"), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		seen.Write(body)
		r.Body = io.NopCloser(bytes.NewReader(body))
		relay.ServeHTTP(w, r)
	}))
	if _, err := Pair(context.Background(), between.URL, testCode, "laptop"); err == nil {
		t.Fatal("paired through a certificate in between")
	}
	if strings.Contains(seen.String(), testCode) {
		t.Fatal("the code reached what was in between")
	}
}

// A server that answers a pairing without having issued the code cannot
// prove it, and its certificate is not kept.
func TestPairNeedsTheServersProof(t *testing.T) {
	impostor := startTLS(t, certificateFor(t, "127.0.0.1"), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(ModeHeader, ModeMedia)
		if r.URL.Path != "/api/v1/pair" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusCreated)
		_ = json.NewEncoder(w).Encode(map[string]string{"token": "credential", "mode": ModeMedia, "proof": "made up"})
	}))
	if _, err := Pair(context.Background(), impostor.URL, testCode, "laptop"); err == nil {
		t.Fatal("linked to a server that did not prove the code")
	}
}

// A certificate for another name would pair and then play nothing: the
// player checks the name as well.
func TestPairRefusesACertificateForAnotherName(t *testing.T) {
	server := startTLS(t, certificateFor(t, "lumeo.lan"), http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("asked for something past the certificate")
	}))
	_, err := Pair(context.Background(), server.URL, testCode, "laptop")
	if err == nil || !strings.Contains(err.Error(), "LUMEO_PUBLIC_URL") {
		t.Fatalf("err = %v", err)
	}
}
