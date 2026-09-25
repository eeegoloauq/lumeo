package main

import (
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/config"
	"github.com/eeegoloauq/lumeo/core/internal/token"
)

// The app that starts the core holds its stdin; whatever way the app ends,
// the pipe closes and the core has to go with it.
func TestCoreStopsWhenStdinCloses(t *testing.T) {
	core := startCore(t, testConfig(t, t.TempDir(), true))
	core.waitListening(t)
	core.stop(t)
}

// A window closed and opened again at once: the new app's core waits for the
// old one to finish instead of sharing its downloads, and a core started by
// hand beside a running one says so instead of waiting.
func TestOneCorePerDataDir(t *testing.T) {
	dir := t.TempDir()
	first := startCore(t, testConfig(t, dir, true))
	first.waitListening(t)

	err := serve(testConfig(t, dir, false), nil, quiet())
	if !errors.Is(err, errDataDirBusy) {
		t.Fatalf("second core by hand: got %v, want %v", err, errDataDirBusy)
	}

	gaveUp := startCore(t, testConfig(t, dir, true))
	next := startCore(t, testConfig(t, dir, true))
	time.Sleep(2*lockPoll + 50*time.Millisecond)
	if next.listening() {
		t.Fatal("a second core listened while the first held the data directory")
	}
	// An app gone before its core got the lock takes the waiting core along.
	gaveUp.stop(t)

	first.stop(t)
	next.waitListening(t)
	next.stop(t)
}

// The core answers only a request that carries the token it wrote to the
// data directory, and writes it before it listens.
func TestCoreRequiresItsToken(t *testing.T) {
	cfg := testConfig(t, t.TempDir(), true)
	core := startCore(t, cfg)
	core.waitListening(t)
	defer core.stop(t)

	if got := core.get(t, ""); got != http.StatusUnauthorized {
		t.Fatalf("without the token: %d", got)
	}
	secret, err := os.ReadFile(filepath.Join(cfg.DataDir, token.FileName))
	if err != nil {
		t.Fatal(err)
	}
	if got := core.get(t, strings.TrimSpace(string(secret))); got != http.StatusOK {
		t.Fatalf("with the token: %d", got)
	}
}

type testCore struct {
	addr  string
	stdin *io.PipeWriter
	done  chan error
}

func startCore(t *testing.T, cfg config.Config) *testCore {
	t.Helper()
	stdin, parent := io.Pipe()
	c := &testCore{addr: cfg.Addr, stdin: parent, done: make(chan error, 1)}
	go func() { c.done <- serve(cfg, stdin, quiet()) }()
	t.Cleanup(func() { parent.Close() })
	return c
}

func (c *testCore) listening() bool {
	resp, err := http.Get("http://" + c.addr + "/healthz")
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

// get asks for /healthz with the token given, and returns the status.
func (c *testCore) get(t *testing.T, secret string) int {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, "http://"+c.addr+"/healthz", nil)
	if err != nil {
		t.Fatal(err)
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

func (c *testCore) waitListening(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !c.listening() {
		select {
		case err := <-c.done:
			t.Fatalf("core stopped before it listened: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("core did not start")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// stop closes the core's stdin, as the app's end does when the app ends.
func (c *testCore) stop(t *testing.T) {
	t.Helper()
	c.stdin.Close()
	select {
	case err := <-c.done:
		if err != nil {
			t.Fatalf("core stopped with %v", err)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("core kept running after its stdin closed")
	}
}

func testConfig(t *testing.T, dir string, owned bool) config.Config {
	return config.Config{
		Addr:           freeAddr(t),
		DataDir:        filepath.Join(dir, "data"),
		CacheDir:       filepath.Join(dir, "cache"),
		EpisodeArtwork: "blur",
		ExitOnStdinEOF: owned,
	}
}

func quiet() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func freeAddr(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().String()
}
