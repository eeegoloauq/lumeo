//go:build unix

package api

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"syscall"
	"testing"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// BenchmarkStream measures what a linked core adds to a film: the same file
// read straight from the server, and through the core that forwards to it,
// both over loopback connections. cpu-s/GiB is the process's CPU time, both
// cores included; the difference between the two is the forwarding's.
//
//	go test ./internal/api -run '^$' -bench Stream -benchtime 4x
func BenchmarkStream(b *testing.B) {
	l := linkedCores(b, nil, laptopToken)
	data := make([]byte, 256<<20)
	backend := &fakeStreamBackend{task: &fakeStreamTask{file: &fakeStreamFile{name: "remux.mkv", data: data}}}
	manager := acquire.NewManager(b.TempDir(), []acquire.Backend{backend}, newFakeStore(), l.core.log)
	defer manager.Close()
	d, err := manager.Start(context.Background(), acquire.Request{Source: sources.MediaSource{Locator: sources.Locator{Scheme: "torrent", InfoHash: "big"}}})
	if err != nil {
		b.Fatal(err)
	}
	server := httptest.NewServer(New(Deps{Downloads: manager, Token: "server-token"}, l.core.log).Handler())
	defer server.Close()
	l.core.remote = remote.New(remote.Link{URL: server.URL, Token: "server-token"}, l.core.log)
	core := httptest.NewServer(l.core.Handler())
	defer core.Close()

	for _, tc := range []struct{ name, base, token string }{
		{"direct", server.URL, "server-token"},
		{"forwarded", core.URL, ""},
	} {
		b.Run(tc.name, func(b *testing.B) {
			b.SetBytes(int64(len(data)))
			before, wall := cpu(), time.Now()
			for b.Loop() {
				req, _ := http.NewRequest(http.MethodGet, tc.base+"/api/v1/downloads/"+d.ID+"/stream", nil)
				if tc.token != "" {
					req.Header.Set("Authorization", "Bearer "+tc.token)
				}
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					b.Fatal(err)
				}
				n, _ := io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
				if n != int64(len(data)) {
					b.Fatalf("read %d of %d bytes: status %d", n, len(data), resp.StatusCode)
				}
			}
			gib := float64(b.N) * float64(len(data)) / (1 << 30)
			b.ReportMetric((cpu()-before).Seconds()/gib, "cpu-s/GiB")
			b.ReportMetric(time.Since(wall).Seconds()/gib, "wall-s/GiB")
		})
	}
}

func cpu() time.Duration {
	var usage syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &usage)
	return time.Duration(usage.Utime.Nano() + usage.Stime.Nano())
}
