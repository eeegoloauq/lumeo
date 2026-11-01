package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/store"
)

func deviceRequest(h http.Handler, method, path, credential, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Content-Type", "application/json")
	if credential != "" {
		r.Header.Set("Authorization", "Bearer "+credential)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func deviceServer(t *testing.T) *Server {
	t.Helper()
	db, err := store.Open(filepath.Join(t.TempDir(), "core.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	s := New(Deps{Devices: db, Token: "owner"}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(s.Close)
	return s
}

func pairingCode(t *testing.T, h http.Handler) string {
	t.Helper()
	w := deviceRequest(h, "POST", "/api/v1/pairings", "owner", "{}")
	var result struct {
		Code string `json:"code"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &result) != nil || len(result.Code) < 26 {
		t.Fatalf("pairing: %d %s", w.Code, w.Body)
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("pairing code may be cached")
	}
	return result.Code
}

func TestDevicePairingAndRevocation(t *testing.T) {
	h := deviceServer(t).Handler()
	if w := deviceRequest(h, "POST", "/api/v1/pairings", "", "{}"); w.Code != 401 {
		t.Fatal(w.Code)
	}
	code := pairingCode(t, h)
	if w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"code":"wrong","name":"Laptop"}`); w.Code != 401 {
		t.Fatal(w.Code)
	}
	body := `{"code":"` + code + `","name":"Laptop"}`
	w := deviceRequest(h, "POST", "/api/v1/pair", "", body)
	var paired struct {
		Token  string       `json:"token"`
		Device store.Device `json:"device"`
	}
	if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &paired) != nil || paired.Token == "" {
		t.Fatalf("pair: %d %s", w.Code, w.Body)
	}
	if w.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("credential may be cached")
	}
	if w := deviceRequest(h, "POST", "/api/v1/pair", "", body); w.Code != 401 {
		t.Fatal("code was reused")
	}
	if w := deviceRequest(h, "GET", "/healthz", paired.Token, ""); w.Code != 200 {
		t.Fatal("device refused", w.Code)
	}
	for _, route := range []struct{ method, path string }{{"POST", "/api/v1/pairings"}, {"GET", "/api/v1/devices"}, {"DELETE", "/api/v1/devices/" + paired.Device.ID}} {
		if w := deviceRequest(h, route.method, route.path, paired.Token, "{}"); w.Code != 403 {
			t.Fatal("device became administrator", w.Code)
		}
	}
	list := deviceRequest(h, "GET", "/api/v1/devices", "owner", "")
	if list.Code != 200 || !strings.Contains(list.Body.String(), "Laptop") || strings.Contains(list.Body.String(), paired.Token) {
		t.Fatalf("device list: %d %s", list.Code, list.Body)
	}
	if w := deviceRequest(h, "DELETE", "/api/v1/devices/"+paired.Device.ID, "owner", ""); w.Code != 204 {
		t.Fatal(w.Code)
	}
	if w := deviceRequest(h, "GET", "/healthz", paired.Token, ""); w.Code != 401 {
		t.Fatal("revoked device accepted")
	}
	if w := deviceRequest(h, "GET", "/healthz", "owner", ""); w.Code != 200 {
		t.Fatal("owner lost access")
	}
}

func TestPairingExpiresAndOnlyOneConcurrentClientWins(t *testing.T) {
	s := deviceServer(t)
	h := s.Handler()
	code := pairingCode(t, h)
	s.pairUntil = time.Now().Add(-time.Second)
	if w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"code":"`+code+`","name":"Laptop"}`); w.Code != 401 {
		t.Fatal("expired code accepted")
	}
	code = pairingCode(t, h)
	var wg sync.WaitGroup
	statuses := make(chan int, 2)
	for range 2 {
		wg.Go(func() {
			statuses <- deviceRequest(h, "POST", "/api/v1/pair", "", `{"code":"`+code+`","name":"Laptop"}`).Code
		})
	}
	wg.Wait()
	close(statuses)
	successes := 0
	for status := range statuses {
		if status == 201 {
			successes++
		} else if status != 401 {
			t.Fatal(status)
		}
	}
	if successes != 1 {
		t.Fatalf("%d clients used the same code", successes)
	}
}

// Over its own certificate the core takes a proof of the code bound to that
// certificate, and answers with its own: a proof over any other certificate,
// one a connection in between would show, pairs nothing.
func TestPairingWithAProofOverTheCoresCertificate(t *testing.T) {
	db, err := store.Open(filepath.Join(t.TempDir(), "core.db"), "test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	certificate := []byte("the core's certificate")
	s := New(Deps{Devices: db, Token: "owner", Certificate: certificate}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(s.Close)
	h := s.Handler()

	code := pairingCode(t, h)
	other := remote.DeviceProof(code, []byte("a certificate in between"))
	if w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"proof":"`+other+`","name":"Laptop"}`); w.Code != 401 {
		t.Fatalf("a proof over another certificate: %d %s", w.Code, w.Body)
	}
	if w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"code":"`+code+`","proof":"x","name":"Laptop"}`); w.Code != 400 {
		t.Fatalf("code and proof: %d", w.Code)
	}
	w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"proof":"`+remote.DeviceProof(code, certificate)+`","name":"Laptop"}`)
	var paired struct {
		Token string `json:"token"`
		Proof string `json:"proof"`
	}
	if w.Code != 201 || json.Unmarshal(w.Body.Bytes(), &paired) != nil || paired.Token == "" {
		t.Fatalf("pair with a proof: %d %s", w.Code, w.Body)
	}
	if paired.Proof != remote.ServerProof(code, certificate) {
		t.Fatal("the core did not prove it holds the code")
	}
	if w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"proof":"`+remote.DeviceProof(code, certificate)+`","name":"Again"}`); w.Code != 401 {
		t.Fatalf("a used code paired again: %d", w.Code)
	}
}

// A core serving plain HTTP has no certificate to bind a code to.
func TestAProofNeedsTheCoresOwnCertificate(t *testing.T) {
	h := deviceServer(t).Handler()
	code := pairingCode(t, h)
	if w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"proof":"`+remote.DeviceProof(code, nil)+`","name":"Laptop"}`); w.Code != 400 {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
}
