package api

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/remote"
)

// localCore is a device's own core, with its data in dir and a device of its
// own paired, whose credential it returns.
func localCore(t *testing.T, mode string, link *remote.Server) (h http.Handler, dir, device string) {
	t.Helper()
	db, dir := openStore(t)
	s := New(Deps{Devices: db, Token: "owner", DataDir: dir, Mode: mode, Remote: link}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(s.Close)
	h = s.Handler()
	w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"code":"`+pairingCode(t, h)+`","name":"Phone"}`)
	var paired struct {
		Token string `json:"token"`
	}
	if w.Code != http.StatusCreated || json.Unmarshal(w.Body.Bytes(), &paired) != nil {
		t.Fatalf("pair: %d %s", w.Code, w.Body)
	}
	return h, dir, paired.Token
}

func readLink(t *testing.T, w *httptest.ResponseRecorder) linkView {
	t.Helper()
	var view linkView
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &view) != nil {
		t.Fatalf("link: %d %s", w.Code, w.Body)
	}
	return view
}

func linkBody(url, token string) string {
	body, _ := json.Marshal(map[string]string{"url": url, "token": token})
	return string(body)
}

// A client paired with a media server hands the device credential to its own
// core, which keeps it only once the server took it and said it is a media
// server. The link is used from the core's next start.
func TestACoreKeepsALinkTheMediaServerTook(t *testing.T) {
	media, credential := modeServer(t, remote.ModeMedia)
	server := httptest.NewServer(media)
	t.Cleanup(server.Close)
	full, fullCredential := modeServer(t, "full")
	fullServer := httptest.NewServer(full)
	t.Cleanup(fullServer.Close)

	h, dir, _ := localCore(t, "", nil)
	if view := readLink(t, deviceRequest(h, "GET", "/api/v1/link", "owner", "")); view != (linkView{}) {
		t.Fatalf("an unlinked core says %+v", view)
	}
	refused := []struct {
		name, body string
		code       int
	}{
		{"a full server", linkBody(fullServer.URL, fullCredential), http.StatusConflict},
		{"a credential the server does not know", linkBody(server.URL, "someone-else"), http.StatusUnprocessableEntity},
		{"an address that is not HTTPS", linkBody("http://lumeo.example.com", credential), http.StatusBadRequest},
	}
	for _, c := range refused {
		if w := deviceRequest(h, "PUT", "/api/v1/link", "owner", c.body); w.Code != c.code {
			t.Errorf("%s: %d %s, want %d", c.name, w.Code, w.Body, c.code)
		}
		if _, err := os.Stat(filepath.Join(dir, remote.FileName)); !os.IsNotExist(err) {
			t.Fatalf("%s was kept: %v", c.name, err)
		}
	}

	view := readLink(t, deviceRequest(h, "PUT", "/api/v1/link", "owner", linkBody(server.URL+"/", credential)))
	if view != (linkView{URL: server.URL}) {
		t.Fatalf("linked: %+v; want the server from the next start, nothing now", view)
	}
	saved, ok, err := remote.Load(dir)
	if err != nil || !ok || saved != (remote.Link{URL: server.URL, Token: credential}) {
		t.Fatalf("saved %+v %v %v", saved, ok, err)
	}
	if strings.Contains(deviceRequest(h, "GET", "/api/v1/link", "owner", "").Body.String(), credential) {
		t.Fatal("the credential is given back")
	}
	if view := readLink(t, deviceRequest(h, "DELETE", "/api/v1/link", "owner", "")); view != (linkView{}) {
		t.Fatalf("unlinked: %+v", view)
	}
	if _, ok, _ := remote.Load(dir); ok {
		t.Fatal("the link outlived unlinking")
	}
}

// The link is the owner's: a device paired with this core cannot point it at
// a server of its choosing, nor learn where it forwards.
func TestOnlyTheOwnerLinksACore(t *testing.T) {
	media, credential := modeServer(t, remote.ModeMedia)
	server := httptest.NewServer(media)
	t.Cleanup(server.Close)
	h, dir, device := localCore(t, "", nil)
	for _, method := range []string{"GET", "PUT", "DELETE"} {
		if w := deviceRequest(h, method, "/api/v1/link", device, linkBody(server.URL, credential)); w.Code != http.StatusForbidden {
			t.Errorf("%s from a device: %d %s", method, w.Code, w.Body)
		}
	}
	if _, ok, _ := remote.Load(dir); ok {
		t.Fatal("a device linked the core")
	}
}

// A media server holds files for its devices; forwarding on to another server
// would make them that one's.
func TestAMediaServerIsNotLinked(t *testing.T) {
	media, credential := modeServer(t, remote.ModeMedia)
	server := httptest.NewServer(media)
	t.Cleanup(server.Close)
	h, dir, _ := localCore(t, remote.ModeMedia, nil)
	if w := deviceRequest(h, "PUT", "/api/v1/link", "owner", linkBody(server.URL, credential)); w.Code != http.StatusConflict {
		t.Fatalf("linking a media server: %d %s", w.Code, w.Body)
	}
	if _, ok, _ := remote.Load(dir); ok {
		t.Fatal("a media server was linked")
	}
}

// What the core forwards to now and what it will after a restart are told
// apart, so the client knows a restart is due.
func TestALinkedCoreSaysWhereItForwards(t *testing.T) {
	running := remote.New(remote.Link{URL: "https://media.example.com", Token: "credential"}, slog.New(slog.DiscardHandler))
	h, dir, _ := localCore(t, "", running)
	if view := readLink(t, deviceRequest(h, "GET", "/api/v1/link", "owner", "")); view != (linkView{Running: "https://media.example.com"}) {
		t.Fatalf("a running link without a saved one: %+v", view)
	}
	if err := remote.Save(dir, remote.Link{URL: "https://media.example.com", Token: "credential"}); err != nil {
		t.Fatal(err)
	}
	if view := readLink(t, deviceRequest(h, "GET", "/api/v1/link", "owner", "")); view.URL != view.Running {
		t.Fatalf("the same link: %+v", view)
	}
}
