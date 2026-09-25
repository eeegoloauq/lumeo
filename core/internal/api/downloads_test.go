package api

import (
	"encoding/json"
	"net/http"
	"testing"
	"time"
)

// decodeDownload is the download JSON as a client reads it, key by key, so a
// field left out is told from one sent empty.
func decodeDownload(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var got map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode download: %v: %s", err, body)
	}
	return got
}

func TestPatchDownloadPausesAndResumes(t *testing.T) {
	h, id := streamServer(t, &fakeStreamFile{name: "movie.mkv", data: payload()})
	path := "/api/v1/downloads/" + id

	// Running with no peers: waiting since it started, and no ETA.
	rec := requestJSON(t, h, http.MethodGet, path, "")
	got := decodeDownload(t, rec.Body.Bytes())
	if since, ok := got["waitingSince"].(string); !ok {
		t.Fatalf("a download with no peers has no waitingSince: %s", rec.Body)
	} else if _, err := time.Parse(time.RFC3339, since); err != nil {
		t.Fatalf("waitingSince %q is not RFC 3339", since)
	}
	if _, ok := got["progress"].(map[string]any)["eta"]; ok {
		t.Fatalf("an ETA while nothing arrives: %s", rec.Body)
	}
	if _, ok := got["pausedByUser"]; ok {
		t.Fatalf("pausedByUser on a running download: %s", rec.Body)
	}

	rec = requestJSON(t, h, http.MethodPatch, path, `{"paused":true}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("pause: status %d: %s", rec.Code, rec.Body)
	}
	got = decodeDownload(t, rec.Body.Bytes())
	if got["state"] != "paused" || got["pausedByUser"] != true {
		t.Fatalf("paused = %s", rec.Body)
	}
	if _, ok := got["waitingSince"]; ok {
		t.Fatalf("a paused download is waiting: %s", rec.Body)
	}
	if got = decodeDownload(t, requestJSON(t, h, http.MethodGet, path, "").Body.Bytes()); got["state"] != "paused" {
		t.Fatalf("read back as %v", got["state"])
	}

	rec = requestJSON(t, h, http.MethodPatch, path, `{"paused": false}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("resume: status %d: %s", rec.Code, rec.Body)
	}
	got = decodeDownload(t, rec.Body.Bytes())
	if got["state"] != "active" {
		t.Fatalf("resumed = %s", rec.Body)
	}
	if _, ok := got["pausedByUser"]; ok {
		t.Fatalf("pausedByUser outlived the resume: %s", rec.Body)
	}
}

func TestPatchDownloadRefusals(t *testing.T) {
	h, id := streamServer(t, &fakeStreamFile{name: "movie.mkv", data: payload()})
	storage, _, _, _ := storageServer(t)
	for _, tt := range []struct {
		name    string
		handler http.Handler
		id      string
		body    string
		want    int
	}{
		{name: "unknown download", handler: h, id: "nope", body: `{"paused":true}`, want: http.StatusNotFound},
		{name: "finished download", handler: storage, id: "regular", body: `{"paused":true}`, want: http.StatusBadRequest},
		{name: "finished download resumed", handler: storage, id: "regular", body: `{"paused":false}`, want: http.StatusBadRequest},
		{name: "empty object", handler: h, id: id, body: `{}`, want: http.StatusBadRequest},
		{name: "null", handler: h, id: id, body: `{"paused":null}`, want: http.StatusBadRequest},
		{name: "not a boolean", handler: h, id: id, body: `{"paused":"yes"}`, want: http.StatusBadRequest},
		{name: "another key beside it", handler: h, id: id, body: `{"paused":true,"name":"x"}`, want: http.StatusBadRequest},
		{name: "another key", handler: h, id: id, body: `{"state":"paused"}`, want: http.StatusBadRequest},
		{name: "array", handler: h, id: id, body: `[true]`, want: http.StatusBadRequest},
		{name: "not an object", handler: h, id: id, body: `null`, want: http.StatusBadRequest},
	} {
		t.Run(tt.name, func(t *testing.T) {
			rec := requestJSON(t, tt.handler, http.MethodPatch, "/api/v1/downloads/"+tt.id, tt.body)
			if rec.Code != tt.want {
				t.Fatalf("status %d, want %d: %s", rec.Code, tt.want, rec.Body)
			}
		})
	}
	// None of them paused anything.
	if got := decodeDownload(t, requestJSON(t, h, http.MethodGet, "/api/v1/downloads/"+id, "").Body.Bytes()); got["state"] != "active" {
		t.Fatalf("state %v after refusals, want active", got["state"])
	}
}
