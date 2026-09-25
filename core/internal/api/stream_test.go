package api

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// The streaming handler is tested against a real acquire.Manager over a fake
// backend: what matters is the HTTP contract, not where the bytes came from.
type fakeStore struct {
	mu   sync.Mutex
	rows map[string]acquire.Download
}

func newFakeStore() *fakeStore { return &fakeStore{rows: map[string]acquire.Download{}} }

func (f *fakeStore) SaveDownload(_ context.Context, d acquire.Download) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.rows[d.ID] = d
	return nil
}

func (f *fakeStore) Downloads(context.Context) ([]acquire.Download, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]acquire.Download, 0, len(f.rows))
	for _, d := range f.rows {
		out = append(out, d)
	}
	return out, nil
}

func (f *fakeStore) Download(_ context.Context, id string) (acquire.Download, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	d, ok := f.rows[id]
	return d, ok, nil
}

func (f *fakeStore) DeleteDownload(_ context.Context, id string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.rows, id)
	return nil
}

type fakeStreamFile struct {
	name string
	data []byte
	cut  error // what a read past half the file fails with
}

func (f fakeStreamFile) Path() string { return "/downloads/" + f.name }
func (f fakeStreamFile) Size() int64  { return int64(len(f.data)) }
func (f fakeStreamFile) Head() int64  { return int64(len(f.data)) }
func (f fakeStreamFile) Open(context.Context) (io.ReadSeekCloser, error) {
	if f.cut != nil {
		return nopSeekCloser{cutReader{bytes.NewReader(f.data), int64(len(f.data) / 2), f.cut}}, nil
	}
	return nopSeekCloser{bytes.NewReader(f.data)}, nil
}

// cutReader reads like the file up to cut, then fails with err.
type cutReader struct {
	*bytes.Reader
	cut int64
	err error
}

func (c cutReader) Read(p []byte) (int, error) {
	pos, _ := c.Seek(0, io.SeekCurrent)
	if pos >= c.cut {
		return 0, c.err
	}
	return c.Reader.Read(p[:min(int64(len(p)), c.cut-pos)])
}

type nopSeekCloser struct{ io.ReadSeeker }

func (nopSeekCloser) Close() error { return nil }

type fakeStreamTask struct {
	mu   sync.Mutex
	file *fakeStreamFile
}

func (t *fakeStreamTask) Progress() acquire.Progress { return acquire.Progress{} }
func (t *fakeStreamTask) File() (acquire.File, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.file == nil {
		return nil, false
	}
	return *t.file, true
}
func (t *fakeStreamTask) Close() error { return nil }

type fakeStreamBackend struct {
	task *fakeStreamTask
	// refuse names the info hashes Start fails for.
	refuse map[string]bool
}

func (b *fakeStreamBackend) Scheme() string { return "torrent" }
func (b *fakeStreamBackend) Start(_ context.Context, loc sources.Locator, _ string) (acquire.Task, error) {
	if b.refuse[loc.InfoHash] {
		return nil, errors.New("refused")
	}
	return b.task, nil
}
func (b *fakeStreamBackend) Close() error { return nil }

func streamServer(t *testing.T, file *fakeStreamFile) (http.Handler, string) {
	t.Helper()
	return streamServerLogging(t, file, io.Discard)
}

func streamServerLogging(t *testing.T, file *fakeStreamFile, logs io.Writer) (http.Handler, string) {
	t.Helper()
	log := slog.New(slog.NewTextHandler(logs, nil))
	backend := &fakeStreamBackend{task: &fakeStreamTask{file: file}}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, newFakeStore(), log)
	d, err := manager.Start(context.Background(), acquire.Request{
		Source: sources.MediaSource{
			RawName: "movie",
			Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"},
		},
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	return New(Deps{Downloads: manager}, log).Handler(), d.ID
}

func payload() []byte { return []byte("0123456789abcdefghijklmnopqrstuvwxyz") }

func TestStreamWholeFile(t *testing.T) {
	body := payload()
	h, id := streamServer(t, &fakeStreamFile{name: "movie.mkv", data: body})

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+id+"/stream", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body)
	}
	if !bytes.Equal(rec.Body.Bytes(), body) {
		t.Errorf("body %q", rec.Body.String())
	}
	if got := rec.Header().Get("Accept-Ranges"); got != "bytes" {
		t.Errorf("Accept-Ranges %q — a player needs to know it can seek", got)
	}
	if got := rec.Header().Get("Content-Type"); got != "video/x-matroska" {
		t.Errorf("Content-Type %q", got)
	}
	if rec.Header().Get("ETag") == "" {
		t.Error("no ETag, so If-Range on seek cannot work")
	}
}

func TestStreamCutShortIsLogged(t *testing.T) {
	for _, cut := range []error{nil, io.ErrUnexpectedEOF, io.EOF} {
		var logs bytes.Buffer
		h, id := streamServerLogging(t, &fakeStreamFile{name: "movie.mkv", data: payload(), cut: cut}, &logs)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+id+"/stream", nil))
		logged := strings.Contains(logs.String(), "stream cut short")
		if logged != (cut != nil) {
			t.Errorf("read failing with %v: logged %v:\n%s", cut, logged, logs.String())
		}
	}
}

func TestStreamRange(t *testing.T) {
	body := payload()
	h, id := streamServer(t, &fakeStreamFile{name: "movie.mkv", data: body})

	for _, c := range []struct {
		name       string
		header     string
		wantCode   int
		wantBody   string
		wantRange  string
		wantLength string
	}{
		{"middle", "bytes=10-19", http.StatusPartialContent, "abcdefghij", "bytes 10-19/36", "10"},
		{"open ended", "bytes=30-", http.StatusPartialContent, "uvwxyz", "bytes 30-35/36", "6"},
		{"suffix", "bytes=-6", http.StatusPartialContent, "uvwxyz", "bytes 30-35/36", "6"},
		{"first byte", "bytes=0-0", http.StatusPartialContent, "0", "bytes 0-0/36", "1"},
	} {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+id+"/stream", nil)
			req.Header.Set("Range", c.header)
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)

			if rec.Code != c.wantCode {
				t.Fatalf("status %d, want %d: %s", rec.Code, c.wantCode, rec.Body)
			}
			if rec.Body.String() != c.wantBody {
				t.Errorf("body %q, want %q", rec.Body.String(), c.wantBody)
			}
			if got := rec.Header().Get("Content-Range"); got != c.wantRange {
				t.Errorf("Content-Range %q, want %q", got, c.wantRange)
			}
			if got := rec.Header().Get("Content-Length"); got != c.wantLength {
				t.Errorf("Content-Length %q, want %q", got, c.wantLength)
			}
		})
	}
}

func TestStreamUnsatisfiableRange(t *testing.T) {
	h, id := streamServer(t, &fakeStreamFile{name: "movie.mkv", data: payload()})
	req := httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+id+"/stream", nil)
	req.Header.Set("Range", "bytes=9999-")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("status %d, want 416", rec.Code)
	}
	if got := rec.Header().Get("Content-Range"); got != "bytes */36" {
		t.Errorf("Content-Range %q, want the total size", got)
	}
}

func TestStreamHeadDoesNotReadTheFile(t *testing.T) {
	h, id := streamServer(t, &fakeStreamFile{name: "movie.mkv", data: payload()})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodHead, "/api/v1/downloads/"+id+"/stream", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status %d", rec.Code)
	}
	if got := rec.Header().Get("Content-Length"); got != "36" {
		t.Errorf("Content-Length %q", got)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("HEAD returned %d bytes of body", rec.Body.Len())
	}
}

func TestStreamUnknownDownload(t *testing.T) {
	h, _ := streamServer(t, &fakeStreamFile{name: "movie.mkv", data: payload()})
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/downloads/nope/stream", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("status %d, want 404", rec.Code)
	}
}

// While a magnet link is still fetching its metadata there is nothing to
// serve, and that is a "come back shortly", not a failure.
func TestStreamBeforeMetadataArrives(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	backend := &fakeStreamBackend{task: &fakeStreamTask{}}
	manager := acquire.NewManager(t.TempDir(), []acquire.Backend{backend}, newFakeStore(), log)
	d, err := manager.Start(context.Background(), acquire.Request{
		Source: sources.MediaSource{Locator: sources.Locator{Scheme: "torrent", InfoHash: "abc"}},
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	h := New(Deps{Downloads: manager}, log).Handler()

	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/downloads/"+d.ID+"/stream", nil).WithContext(ctx)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	// The wait is bounded by the request: a player that walks away is not
	// left holding a connection, and neither are we.
	if rec.Code != 200 && rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d, want 503 or a cancelled request", rec.Code)
	}
	if rec.Code == http.StatusServiceUnavailable && rec.Header().Get("Retry-After") == "" {
		t.Error("503 without Retry-After leaves the client guessing")
	}
	if strings.Contains(rec.Body.String(), "panic") {
		t.Error("unexpected body")
	}
}
