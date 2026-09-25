package torrent

import (
	"context"
	"math"
	"net"
	"path/filepath"
	"testing"
	"time"

	atorrent "github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"golang.org/x/time/rate"

	"github.com/eeegoloauq/lumeo/core/internal/sources"
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

// With seeding off, a torrent stops uploading once it has everything it was
// asked for and starts again when seeding is turned back on, while it runs.
// One still fetching keeps trading with its peers either way.
func TestSeedingIsDecidedPerTorrentWhileItRuns(t *testing.T) {
	whole, wholeTorrent := knownTorrent(t, oneFilm(t), true)
	empty, emptyTorrent := knownTorrent(t, oneFilm(t), false)

	waitFor(t, 30*time.Second, "a whole torrent to stop uploading", func() bool { return !wholeTorrent.Seeding() })
	if !emptyTorrent.Seeding() {
		t.Fatal("a torrent still fetching was stopped from uploading")
	}

	whole.SetSeed(true)
	if !wholeTorrent.Seeding() {
		t.Fatal("seeding on did not resume uploading")
	}
	whole.SetSeed(false)
	if wholeTorrent.Seeding() {
		t.Fatal("seeding off did not stop a whole torrent")
	}
	empty.SetSeed(false)
	if !emptyTorrent.Seeding() {
		t.Fatal("seeding off stopped a torrent still fetching")
	}
}

// nobody is a peer that is not there: no DHT, and nothing arrives.
func nobody() []atorrent.PeerInfo {
	return []atorrent.PeerInfo{{
		Addr:   &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 1},
		Source: atorrent.PeerSourceDirect,
	}}
}

// knownTorrent runs the torrent of seedDir in a backend with seeding off. With
// whole, the download goes where the files already are, so every piece checks
// out complete; otherwise it starts empty with nobody to fetch from.
func knownTorrent(t *testing.T, seedDir string, whole bool) (*Backend, *atorrent.Torrent) {
	t.Helper()
	info := metainfo.Info{PieceLength: 256 << 10}
	if err := info.BuildFromFilePath(seedDir); err != nil {
		t.Fatalf("build metainfo: %v", err)
	}
	infoBytes, err := bencode.Marshal(info)
	if err != nil {
		t.Fatalf("marshal metainfo: %v", err)
	}
	meta := metainfo.MetaInfo{InfoBytes: infoBytes}
	backend, err := New(Config{DataDir: t.TempDir(), Seed: false, Peers: nobody()})
	if err != nil {
		t.Fatalf("create backend: %v", err)
	}
	t.Cleanup(func() { _ = backend.Close() })
	// The torrent's files live under its name, which is seedDir's own.
	dir := t.TempDir()
	if whole {
		dir = filepath.Dir(seedDir)
	}
	task, err := backend.Start(context.Background(), sources.Locator{
		Scheme:   "torrent",
		InfoHash: meta.HashInfoBytes().HexString(),
	}, dir)
	if err != nil {
		t.Fatalf("start download: %v", err)
	}
	t.Cleanup(func() { _ = task.Close() })
	tor, _ := backend.client.AddTorrentOpt(atorrent.AddTorrentOpts{InfoHash: meta.HashInfoBytes()})
	if err := tor.SetInfoBytes(infoBytes); err != nil {
		t.Fatalf("hand over the metainfo: %v", err)
	}
	waitForFile(t, task, 30*time.Second)
	waitForPieceCheck(t, tor, 30*time.Second)
	return backend, tor
}
