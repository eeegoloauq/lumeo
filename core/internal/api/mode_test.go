package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
)

// modeServer is a core in mode with one device paired, and that device's
// credential.
func modeServer(t *testing.T, mode string) (http.Handler, string) {
	t.Helper()
	db, _ := openStore(t)
	s := New(Deps{Devices: db, Token: "owner", Mode: mode}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	t.Cleanup(s.Close)
	h := s.Handler()
	w := deviceRequest(h, "POST", "/api/v1/pair", "", `{"code":"`+pairingCode(t, h)+`","name":"Laptop"}`)
	var paired struct {
		Token string `json:"token"`
		Mode  string `json:"mode"`
	}
	if w.Code != http.StatusCreated || json.Unmarshal(w.Body.Bytes(), &paired) != nil {
		t.Fatalf("pair: %d %s", w.Code, w.Body)
	}
	if want := cmpOr(mode, "full"); paired.Mode != want || w.Header().Get(remote.ModeHeader) != want {
		t.Fatalf("paired with mode %q, header %q; want %q", paired.Mode, w.Header().Get(remote.ModeHeader), want)
	}
	return h, paired.Token
}

func cmpOr(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

// A media server keeps none of its devices' personal data, and refuses it
// rather than keeping some. The owner, whose token never leaves the machine,
// still has a full core there, and a full server keeps its devices' data.
func TestAMediaServerRefusesPersonalDataFromDevices(t *testing.T) {
	personal := []struct{ method, path string }{
		{"GET", "/api/v1/progress/x"}, {"PUT", "/api/v1/progress/x"}, {"DELETE", "/api/v1/progress/x"},
		{"GET", "/api/v1/continue"}, {"GET", "/api/v1/history"},
		{"GET", "/api/v1/personal"}, {"POST", "/api/v1/personal"},
		{"GET", "/api/v1/list"}, {"GET", "/api/v1/list/x"}, {"PUT", "/api/v1/list/x"}, {"DELETE", "/api/v1/list/x"},
		{"GET", "/api/v1/new-episodes"}, {"GET", "/api/v1/coming-up"},
		{"GET", "/api/v1/ratings/x"}, {"PUT", "/api/v1/ratings/x"}, {"DELETE", "/api/v1/ratings/x"},
		{"GET", "/api/v1/choices/x"}, {"PATCH", "/api/v1/choices/x"},
		{"GET", "/api/v1/searches"}, {"POST", "/api/v1/searches"}, {"DELETE", "/api/v1/searches"},
		{"GET", "/api/v1/preferences"}, {"PATCH", "/api/v1/preferences"}, {"DELETE", "/api/v1/preferences"},
		{"POST", "/api/v1/items/x/folders"},
	}
	media, device := modeServer(t, remote.ModeMedia)
	full, fullDevice := modeServer(t, "full")
	for _, route := range personal {
		if w := deviceRequest(media, route.method, route.path, device, "{}"); w.Code != http.StatusForbidden || !strings.Contains(w.Body.String(), "media server") {
			t.Errorf("%s %s from a device of a media server: %d %s", route.method, route.path, w.Code, w.Body)
		}
		if w := deviceRequest(media, route.method, route.path, "owner", "{}"); w.Code == http.StatusForbidden {
			t.Errorf("%s %s refused the owner of a media server", route.method, route.path)
		}
		if w := deviceRequest(full, route.method, route.path, fullDevice, "{}"); w.Code == http.StatusForbidden {
			t.Errorf("%s %s refused a device of a full server", route.method, route.path)
		}
	}
	// What is not the viewer's stays open to a device.
	for _, path := range []string{"/healthz", "/api/v1/catalogs", "/api/v1/downloads"} {
		if w := deviceRequest(media, "GET", path, device, ""); w.Code == http.StatusForbidden {
			t.Errorf("%s refused a device of a media server", path)
		}
	}
	// Every answer says the mode, a refused credential too.
	if w := deviceRequest(media, "GET", "/healthz", "", ""); w.Code != http.StatusUnauthorized || w.Header().Get(remote.ModeHeader) != remote.ModeMedia {
		t.Errorf("without a credential: %d, mode %q", w.Code, w.Header().Get(remote.ModeHeader))
	}
}

// Only a device of a media server holds a download: the owner, and a device
// of a full server, keep their progress where the keep policy reads it.
func TestOnlyADeviceOfAMediaServerHoldsADownload(t *testing.T) {
	l := linkedCores(t, nil, laptopToken)
	l.open()
	d := l.start(torrentSource("Severance.S01E01.1080p", "aaa", 30, "group"))
	server := *l.served.Load()
	path := "/api/v1/downloads/" + d.ID + "/hold"
	if w := deviceRequest(server, "PUT", path, "server-token", `{"watched":true,"subtitleLanguages":[]}`); w.Code != http.StatusForbidden {
		t.Errorf("the owner held a download: %d %s", w.Code, w.Body)
	}
	for _, body := range []string{`{"subtitleLanguages":[]}`, `{"watched":true}`, `{"watched":true,"subtitleLanguages":["not a language"]}`} {
		if w := deviceRequest(server, "PUT", path, laptopToken, body); w.Code != http.StatusBadRequest {
			t.Errorf("%s: %d %s", body, w.Code, w.Body)
		}
	}
	if w := deviceRequest(server, "PUT", "/api/v1/downloads/missing/hold", laptopToken, `{"watched":true,"subtitleLanguages":[]}`); w.Code != http.StatusNotFound {
		t.Errorf("hold on a missing download: %d", w.Code)
	}
	if w := deviceRequest(server, "GET", "/api/v1/downloads/"+d.ID, laptopToken, ""); !strings.Contains(w.Body.String(), `"hold":{"subtitleLanguages":["ru"]}`) {
		t.Errorf("a device does not see its hold: %s", w.Body)
	}
	if w := deviceRequest(server, "GET", "/api/v1/downloads/"+d.ID, tvToken, ""); strings.Contains(w.Body.String(), `"hold"`) {
		t.Errorf("a device sees another's hold: %s", w.Body)
	}

	full := l.serverDeps
	full.Mode = "full"
	l.serve(full)
	if w := deviceRequest(*l.served.Load(), "PUT", path, laptopToken, `{"watched":true,"subtitleLanguages":[]}`); w.Code != http.StatusForbidden {
		t.Errorf("a device of a full server held a download: %d %s", w.Code, w.Body)
	}
}

// What a device of a media server is answered reads nothing of the owner's
// data: its core ranks the copies and keeps the choice itself.
func TestAMediaServerAnswersADeviceWithoutItsOwnersChoice(t *testing.T) {
	found := fixedSource{
		torrentSource("Severance.S01E01.2160p", "aaa", 80, "big"),
		torrentSource("Severance.S01E01.720p", "bbb", 10, "small"),
	}
	l := linkedCores(t, found, laptopToken)
	l.open()
	l.start(found[1])
	if err := l.serverWatch.RememberSource(context.Background(), l.theirID, progress.Pack{BingeGroup: "small", InfoHash: "bbb", Picked: true}); err != nil {
		t.Fatal(err)
	}
	server := *l.served.Load()
	for _, tc := range []struct {
		credential string
		chosen     bool
	}{{"server-token", true}, {laptopToken, false}} {
		w := deviceRequest(server, "GET", "/api/v1/sources?item="+l.theirID+"&season=1&episode=1", tc.credential, "")
		var answer struct {
			Sources []listedSource `json:"sources"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &answer); err != nil || len(answer.Sources) != 2 {
			t.Fatalf("sources for %s: %d %s", tc.credential, w.Code, w.Body)
		}
		lastUsed := answer.Sources[0].LastUsed || answer.Sources[1].LastUsed
		if lastUsed != tc.chosen || tc.chosen && answer.Sources[0].RawName != found[1].RawName {
			t.Errorf("sources for %s: %+v; want the owner's choice first only for the owner", tc.credential, answer.Sources)
		}
		w = deviceRequest(server, "GET", "/api/v1/items/"+l.theirID+"/folders", tc.credential, "")
		if chosen := strings.Contains(w.Body.String(), `"chosen":true`); chosen != tc.chosen {
			t.Errorf("folders for %s: %s", tc.credential, w.Body)
		}
	}
}

// A server that stops being a media server is noticed on its next answer:
// nothing more is forwarded, and the client is told why, not that it was
// unreachable. The copies on this machine stay playable.
func TestALinkedCoreRefusesAServerThatBecameFull(t *testing.T) {
	l := linkedCores(t, nil, laptopToken)
	l.open()
	full := l.serverDeps
	full.Mode = "full"
	l.serve(full)

	for _, path := range []string{"/api/v1/addons", "/api/v1/storage", "/api/v1/downloads/x/stream"} {
		rec := requestJSON(t, l.local, http.MethodGet, path, "")
		if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "not a media server") {
			t.Errorf("%s: status %d: %s", path, rec.Code, rec.Body)
		}
	}
	rec := requestJSON(t, l.local, http.MethodGet, "/api/v1/sources?item="+l.itemID+"&season=1&episode=1", "")
	var body struct {
		Failed []failedProvider `json:"failed"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || len(body.Failed) != 1 || !strings.Contains(body.Failed[0].Reason, "not a media server") {
		t.Errorf("sources: status %d: %s", rec.Code, rec.Body)
	}
	if err := l.core.syncHolds(context.Background()); !errors.Is(err, remote.ErrNotMedia) {
		t.Errorf("sync: %v", err)
	}
}
