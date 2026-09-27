package torrent

import (
	"math"
	"net"
	"testing"
	"time"

	atorrent "github.com/anacrolix/torrent"
	"golang.org/x/time/rate"
)

// A limit holds from the next block on, and so does taking it away, however
// fast the changes come: a change at the instant of the one before, while
// there is no limit, used to leave the limiter with NaN tokens, which never
// run out.
func TestLimitsApplyWhileTheClientRuns(t *testing.T) {
	backend, err := New(Config{DataDir: t.TempDir(), UploadLimit: 500_000, Peers: nobody()})
	if err != nil {
		t.Fatalf("create backend: %v", err)
	}
	t.Cleanup(func() { _ = backend.Close() })
	if got := backend.upload.rate.Limit(); got != 500_000 {
		t.Fatalf("upload limit from the config = %v, want 500000", got)
	}
	if got := backend.download.rate.Limit(); got != rate.Inf {
		t.Fatalf("download limit from the config = %v, want none", got)
	}

	for _, step := range []struct {
		upload, download int64
	}{
		{0, 0}, {0, 0}, {2_000, 3 << 20}, {0, 0}, {2_000, 3 << 20}, {2_000, 3 << 20},
	} {
		backend.SetLimits(step.upload, step.download)
	}
	for _, l := range []struct {
		name  string
		rate  *rate.Limiter
		limit rate.Limit
		burst int
	}{
		{"upload", backend.upload.rate, 2_000, minBurst},
		{"download", backend.download.rate, 3 << 20, 3 << 20},
	} {
		if l.rate.Limit() != l.limit || l.rate.Burst() != l.burst {
			t.Errorf("%s: limit %v burst %d, want %v and %d", l.name, l.rate.Limit(), l.rate.Burst(), l.limit, l.burst)
		}
		if tokens := l.rate.Tokens(); math.IsNaN(tokens) {
			t.Errorf("%s: tokens are NaN", l.name)
		}
		// A burst spent, the next block waits for the rate.
		now := time.Now()
		l.rate.ReserveN(now, l.burst)
		if wait := l.rate.ReserveN(now, l.burst).DelayFrom(now); wait < time.Second/2 {
			t.Errorf("%s: a second burst waits %v, want the limit to hold it back", l.name, wait)
		}
	}

	backend.SetLimits(0, 0)
	if backend.upload.rate.Limit() != rate.Inf || backend.download.rate.Limit() != rate.Inf {
		t.Fatal("limits stayed after being taken away")
	}
}

// nobody is a peer that is not there: no DHT, and nothing arrives.
func nobody() []atorrent.PeerInfo {
	return []atorrent.PeerInfo{{
		Addr:   &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 1},
		Source: atorrent.PeerSourceDirect,
	}}
}
