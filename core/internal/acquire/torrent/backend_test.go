package torrent

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"math/rand"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	atorrent "github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/bencode"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

func TestBackendStreamsFromLocalPeer(t *testing.T) {
	// The seeder's writer can miss a wakeup and sit on served requests until
	// its one-minute keepalive; fixed on anacrolix master, not yet released.
	t.Skip("anacrolix/torrent#1070: remove with the anacrolix update past v1.61.0")
	const contentSize = 6 << 20
	const transferTimeout = 60 * time.Second

	seedDir := t.TempDir()
	content := make([]byte, contentSize)
	if _, err := rand.New(rand.NewSource(1)).Read(content); err != nil {
		t.Fatalf("generate content: %v", err)
	}
	seedPath := filepath.Join(seedDir, "feature.mkv")
	if err := os.WriteFile(seedPath, content, 0o644); err != nil {
		t.Fatalf("write seed file: %v", err)
	}

	info := metainfo.Info{PieceLength: 256 << 10}
	if err := info.BuildFromFilePath(seedPath); err != nil {
		t.Fatalf("build metainfo: %v", err)
	}
	infoBytes, err := bencode.Marshal(info)
	if err != nil {
		t.Fatalf("marshal metainfo: %v", err)
	}
	meta := metainfo.MetaInfo{InfoBytes: infoBytes}

	seedStorage := storage.NewFile(seedDir)
	defer func() {
		if err := seedStorage.Close(); err != nil {
			t.Errorf("close seeder storage: %v", err)
		}
	}()
	seedConfig := atorrent.NewDefaultClientConfig()
	seedConfig.DataDir = t.TempDir()
	seedConfig.ListenHost = func(string) string { return "127.0.0.1" }
	seedConfig.ListenPort = 0
	seedConfig.Seed = true
	seedConfig.NoDHT = true
	seedConfig.DisableTrackers = true
	seedConfig.NoDefaultPortForwarding = true
	seedConfig.DisableUTP = true
	seedConfig.DisableIPv6 = true
	seedConfig.Slogger = slog.New(slog.NewTextHandler(io.Discard, nil))
	seedClient, err := atorrent.NewClient(seedConfig)
	if err != nil {
		t.Fatalf("create seeder: %v", err)
	}
	defer seedClient.Close()

	seedTorrent, added := seedClient.AddTorrentOpt(atorrent.AddTorrentOpts{
		InfoHash:  meta.HashInfoBytes(),
		InfoBytes: meta.InfoBytes,
		Storage:   seedStorage,
	})
	if !added {
		t.Fatal("seeder did not add torrent")
	}
	select {
	case <-seedTorrent.Complete().On():
	case <-time.After(transferTimeout):
		t.Fatal("seeder did not verify source data")
	}

	backend, err := New(Config{
		DataDir: t.TempDir(),
		Peers: []atorrent.PeerInfo{{
			Addr:    &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: seedClient.LocalPort()},
			Source:  atorrent.PeerSourceDirect,
			Trusted: true,
		}},
	})
	if err != nil {
		t.Fatalf("create backend: %v", err)
	}
	defer func() {
		if err := backend.Close(); err != nil {
			t.Errorf("close backend: %v", err)
		}
	}()

	task, err := backend.Start(context.Background(), sources.Locator{
		Scheme:   "torrent",
		InfoHash: meta.HashInfoBytes().HexString(),
	}, t.TempDir())
	if err != nil {
		t.Fatalf("start download: %v", err)
	}
	defer func() {
		if err := task.Close(); err != nil {
			t.Errorf("close task: %v", err)
		}
	}()

	file := waitForFile(t, task, transferTimeout)
	if !filepath.IsAbs(file.Path()) {
		t.Fatalf("file path is not absolute: %q", file.Path())
	}
	if got := file.Size(); got != contentSize {
		t.Fatalf("file size = %d, want %d", got, contentSize)
	}

	reader, err := file.Open(context.Background())
	if err != nil {
		t.Fatalf("open downloaded file: %v", err)
	}
	defer reader.Close()
	readResult := make(chan struct {
		data []byte
		err  error
	}, 1)
	go func() {
		data, readErr := io.ReadAll(reader)
		readResult <- struct {
			data []byte
			err  error
		}{data, readErr}
	}()

	var downloaded []byte
	select {
	case result := <-readResult:
		if result.err != nil {
			t.Fatalf("read downloaded file: %v", result.err)
		}
		downloaded = result.data
	case <-time.After(transferTimeout):
		_ = task.Close()
		t.Fatal("timed out reading downloaded file")
	}
	if !bytes.Equal(downloaded, content) {
		t.Fatal("downloaded content differs from source")
	}

	// The other half of what Head answers: a file that has arrived offers all
	// of itself, and the player is told it can start.
	select {
	case <-torrentOf(task).Complete().On():
	case <-time.After(transferTimeout):
		t.Fatal("the file read in full was never verified")
	}
	if head := file.Head(); head != contentSize {
		t.Errorf("head = %d bytes of a file of %d that is entirely here", head, contentSize)
	}

	progress := task.Progress()
	if progress.Completed == 0 {
		t.Fatal("completed progress is zero after reading the file")
	}
	if progress.Total != contentSize {
		t.Fatalf("progress total = %d, want %d", progress.Total, contentSize)
	}
}

func torrentOf(t acquire.Task) *atorrent.Torrent { return t.(*task).torrent }

func waitForFile(t *testing.T, task acquire.Task, timeout time.Duration) acquire.File {
	t.Helper()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		if file, ok := task.File(); ok {
			return file
		}
		select {
		case <-ticker.C:
		case <-timer.C:
			t.Fatal("timed out waiting for torrent metadata")
		}
	}
}

// A season pack is one torrent and many episodes: two downloads share the
// infohash, differ only in file index, and neither may kill the other.
func TestBackendSharesOneTorrentAcrossFiles(t *testing.T) {
	const transferTimeout = 60 * time.Second

	seedDir := t.TempDir()
	packDir := filepath.Join(seedDir, "pack")
	if err := os.MkdirAll(packDir, 0o755); err != nil {
		t.Fatalf("create pack dir: %v", err)
	}
	// Not whole numbers of pieces: the episodes then share the piece where one
	// ends and the other begins, which is the arrangement every off-by-one in
	// here has come from.
	first := randomBytes(2<<20+1000, 7)
	second := randomBytes(3<<20+500, 9)
	if err := os.WriteFile(filepath.Join(packDir, "S02E01.mkv"), first, 0o644); err != nil {
		t.Fatalf("write episode: %v", err)
	}
	if err := os.WriteFile(filepath.Join(packDir, "S02E02.mkv"), second, 0o644); err != nil {
		t.Fatalf("write episode: %v", err)
	}

	info := metainfo.Info{PieceLength: 256 << 10}
	if err := info.BuildFromFilePath(packDir); err != nil {
		t.Fatalf("build metainfo: %v", err)
	}
	infoBytes, err := bencode.Marshal(info)
	if err != nil {
		t.Fatalf("marshal metainfo: %v", err)
	}
	meta := metainfo.MetaInfo{InfoBytes: infoBytes}
	seedClient := startSeeder(t, seedDir, meta, transferTimeout)

	backend, err := New(Config{DataDir: t.TempDir(), Peers: localPeers(seedClient)})
	if err != nil {
		t.Fatalf("create backend: %v", err)
	}
	defer func() {
		if err := backend.Close(); err != nil {
			t.Errorf("close backend: %v", err)
		}
	}()

	firstDir, secondDir := t.TempDir(), t.TempDir()
	episode := func(index int, dir string) acquire.Task {
		t.Helper()
		task, err := backend.Start(context.Background(), sources.Locator{
			Scheme:    "torrent",
			InfoHash:  meta.HashInfoBytes().HexString(),
			FileIndex: &index,
		}, dir)
		if err != nil {
			t.Fatalf("start episode %d: %v", index, err)
		}
		return task
	}
	taskOne := episode(0, firstDir)
	taskTwo := episode(1, secondDir)

	fileOne := waitForFile(t, taskOne, transferTimeout)
	fileTwo := waitForFile(t, taskTwo, transferTimeout)
	if filepath.Base(fileOne.Path()) != "S02E01.mkv" || filepath.Base(fileTwo.Path()) != "S02E02.mkv" {
		t.Fatalf("file index picked %q and %q", fileOne.Path(), fileTwo.Path())
	}
	// Both episodes live where the first download put the torrent, whatever
	// directory the second one asked for.
	if !strings.HasPrefix(fileTwo.Path(), firstDir) {
		t.Errorf("second episode is at %q, want it under %q", fileTwo.Path(), firstDir)
	}
	if fileOne.Size() != int64(len(first)) || fileTwo.Size() != int64(len(second)) {
		t.Fatalf("sizes %d and %d", fileOne.Size(), fileTwo.Size())
	}

	assertSame(t, "first episode", readAll(t, fileOne, transferTimeout), first)
	// Closing one episode must not drop the torrent the other is reading.
	if err := taskOne.Close(); err != nil {
		t.Fatalf("close first episode: %v", err)
	}
	assertSame(t, "second episode after the first was closed", readAll(t, fileTwo, transferTimeout), second)

	// Everything is here now, and each episode answers for its own length and
	// no further: the first ends inside a piece and the second begins inside
	// one, which is where an off-by-a-piece would show. Waited for rather than
	// read straight away, because a piece is counted here once it has been
	// verified and a reader hands over its bytes before that.
	waitFor(t, transferTimeout, "both episodes to be whole", func() bool {
		return fileOne.Head() == int64(len(first)) &&
			fileTwo.Head() == int64(len(second))
	})

	if err := taskTwo.Close(); err != nil {
		t.Fatalf("close second episode: %v", err)
	}
}

// waitFor gives a condition until the timeout to become true, and says what it
// was waiting for when it does not.
func waitFor(t *testing.T, timeout time.Duration, what string, done func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for !done() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func assertSame(t *testing.T, what string, got, want []byte) {
	t.Helper()
	if bytes.Equal(got, want) {
		return
	}
	if len(got) != len(want) {
		t.Errorf("%s: read %d bytes, want %d", what, len(got), len(want))
		return
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("%s: differs at byte %d of %d", what, i, len(want))
			return
		}
	}
}

func randomBytes(n int, seed int64) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(seed)).Read(b)
	return b
}

func localPeers(seeder *atorrent.Client) []atorrent.PeerInfo {
	return []atorrent.PeerInfo{{
		Addr:    &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: seeder.LocalPort()},
		Source:  atorrent.PeerSourceDirect,
		Trusted: true,
	}}
}

// startSeeder serves the given metainfo out of dir until the test ends.
func startSeeder(t *testing.T, dir string, meta metainfo.MetaInfo, timeout time.Duration) *atorrent.Client {
	t.Helper()
	seedStorage := storage.NewFile(dir)
	cfg := atorrent.NewDefaultClientConfig()
	cfg.DataDir = t.TempDir()
	cfg.ListenHost = func(string) string { return "127.0.0.1" }
	cfg.ListenPort = 0
	cfg.Seed = true
	cfg.NoDHT = true
	cfg.DisableTrackers = true
	cfg.NoDefaultPortForwarding = true
	cfg.DisableUTP = true
	cfg.DisableIPv6 = true
	cfg.Slogger = slog.New(slog.NewTextHandler(io.Discard, nil))
	client, err := atorrent.NewClient(cfg)
	if err != nil {
		t.Fatalf("create seeder: %v", err)
	}
	t.Cleanup(func() {
		client.Close()
		if err := seedStorage.Close(); err != nil {
			t.Errorf("close seeder storage: %v", err)
		}
	})

	tor, added := client.AddTorrentOpt(atorrent.AddTorrentOpts{
		InfoHash:  meta.HashInfoBytes(),
		InfoBytes: meta.InfoBytes,
		Storage:   seedStorage,
	})
	if !added {
		t.Fatal("seeder did not add torrent")
	}
	select {
	case <-tor.Complete().On():
	case <-time.After(timeout):
		t.Fatal("seeder did not verify source data")
	}
	return client
}

func readAll(t *testing.T, file acquire.File, timeout time.Duration) []byte {
	t.Helper()
	reader, err := file.Open(context.Background())
	if err != nil {
		t.Fatalf("open %q: %v", file.Path(), err)
	}
	defer reader.Close()

	type result struct {
		data []byte
		err  error
	}
	done := make(chan result, 1)
	go func() {
		data, err := io.ReadAll(reader)
		done <- result{data, err}
	}()
	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("read %q: %v", file.Path(), r.err)
		}
		return r.data
	case <-time.After(timeout):
		t.Fatalf("timed out reading %q", file.Path())
		return nil
	}
}

// The demuxer reads the container's index before it shows a frame, and in
// Matroska that index sits at the end of the file as often as at the front. A
// file whose last piece is queued behind everything else is a file the player
// waits minutes to start and then declares broken, which is what an episode at
// 3% with two peers looked like on screen.
//
// Checked without a seeder: the metainfo goes straight into the client, so the
// torrent knows its file and nothing ever completes — the moment a piece
// arrives its priority is answered and gone, and there would be nothing left
// to read.
func TestBackendAsksForBothEndsOfTheFileFirst(t *testing.T) {
	_, tor := knownButEmpty(t, oneFilm(t))

	last := tor.NumPieces() - 1
	if last < 2 {
		t.Fatalf("torrent has %d pieces, too few to tell an end from a middle", tor.NumPieces())
	}
	for _, piece := range []struct {
		what  string
		index int
		want  atorrent.PiecePriority
	}{
		{"the first piece", 0, atorrent.PiecePriorityNext},
		{"the last piece", last, atorrent.PiecePriorityNext},
		{"a piece in the middle", last / 2, atorrent.PiecePriorityNormal},
	} {
		if got := tor.PieceState(piece.index).Priority; got != piece.want {
			t.Errorf("%s has priority %v, want %v", piece.what, got, piece.want)
		}
	}
}

// The name of a file is not a byte of it. A download whose metadata has just
// arrived knows what it is downloading and has nothing to play, and a player
// told otherwise opens a stream whose first read blocks until the swarm gets
// round to it.
func TestBackendHeadIsEmptyUntilTheFileStartsArriving(t *testing.T) {
	tasks, _ := knownButEmpty(t, oneFilm(t))
	file, ok := tasks[0].File()
	if !ok {
		t.Fatal("the file is not known")
	}
	if got := file.Head(); got != 0 {
		t.Errorf("head = %d bytes, want none of the file to be readable yet", got)
	}
	if file.Size() == 0 {
		t.Error("size is unknown, and it is what the bar measures against")
	}
}

// A pack outlives the episode that opened it: two episodes are one torrent, and
// stopping one of them cannot drop it. What the stopped one asked the swarm for
// has to go all the same — left behind, it competes for the same few peers with
// the episode still on screen — except where the two meet, which is one piece
// that belongs to both.
func TestBackendStopsWantingAStoppedEpisode(t *testing.T) {
	tasks, tor := knownButEmpty(t, oneSeason(t), 0, 1)
	first, second := tor.Files()[0], tor.Files()[1]
	shared := second.BeginPieceIndex()
	if shared != first.EndPieceIndex()-1 {
		t.Fatalf("the episodes share no piece: %d and %d",
			first.EndPieceIndex(), shared)
	}

	if err := tasks[0].Close(); err != nil {
		t.Fatalf("stop the first episode: %v", err)
	}

	for _, piece := range []struct {
		what  string
		index int
		want  atorrent.PiecePriority
	}{
		{"the first piece of the stopped episode", first.BeginPieceIndex(), atorrent.PiecePriorityNone},
		{"the middle of the stopped episode", first.EndPieceIndex() / 2, atorrent.PiecePriorityNone},
		{"the piece both episodes hold", shared, atorrent.PiecePriorityNext},
		{"the middle of the episode still running", (shared + second.EndPieceIndex()) / 2, atorrent.PiecePriorityNormal},
		{"the last piece of the episode still running", second.EndPieceIndex() - 1, atorrent.PiecePriorityNext},
	} {
		if got := tor.PieceState(piece.index).Priority; got != piece.want {
			t.Errorf("%s has priority %v, want %v", piece.what, got, piece.want)
		}
	}
}

// oneFilm is a directory holding one film, big enough to have a middle.
func oneFilm(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "feature.mkv"), randomBytes(6<<20, 11), 0o644); err != nil {
		t.Fatalf("write seed file: %v", err)
	}
	return dir
}

// oneSeason is a pack of two episodes. The first is deliberately not a whole
// number of pieces long, so the two of them share the piece where one ends and
// the other begins — which is the case the priorities have to get right.
func oneSeason(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "season")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("create pack dir: %v", err)
	}
	for name, size := range map[string]int{
		"S02E01.mkv": 2<<20 + 1000,
		"S02E02.mkv": 3 << 20,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), randomBytes(size, 13), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return dir
}

// knownButEmpty is a download that knows exactly what it is downloading and has
// not received a byte of it: the metainfo is handed to the client directly and
// the only peer it is given is not there, so nothing arrives and nothing is
// left to the timing of a swarm. One task per file index asked for, or a single
// one over whatever the torrent's own rule picks.
func knownButEmpty(t *testing.T, seedDir string, indices ...int) ([]acquire.Task, *atorrent.Torrent) {
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

	nobody := []atorrent.PeerInfo{{
		Addr:   &net.TCPAddr{IP: net.ParseIP("127.0.0.1"), Port: 1},
		Source: atorrent.PeerSourceDirect,
	}}
	backend, err := New(Config{DataDir: t.TempDir(), Peers: nobody})
	if err != nil {
		t.Fatalf("create backend: %v", err)
	}
	t.Cleanup(func() {
		if err := backend.Close(); err != nil {
			t.Errorf("close backend: %v", err)
		}
	})

	start := func(index *int) acquire.Task {
		t.Helper()
		task, err := backend.Start(context.Background(), sources.Locator{
			Scheme:    "torrent",
			InfoHash:  meta.HashInfoBytes().HexString(),
			FileIndex: index,
		}, t.TempDir())
		if err != nil {
			t.Fatalf("start download: %v", err)
		}
		t.Cleanup(func() {
			if err := task.Close(); err != nil {
				t.Errorf("close task: %v", err)
			}
		})
		return task
	}
	var tasks []acquire.Task
	if len(indices) == 0 {
		tasks = append(tasks, start(nil))
	}
	for _, index := range indices {
		tasks = append(tasks, start(&index))
	}

	// What a swarm would have handed over, handed over directly.
	tor, _ := backend.client.AddTorrentOpt(atorrent.AddTorrentOpts{
		InfoHash: meta.HashInfoBytes(),
	})
	if err := tor.SetInfoBytes(infoBytes); err != nil {
		t.Fatalf("hand over the metainfo: %v", err)
	}
	for _, task := range tasks {
		waitForFile(t, task, 30*time.Second)
	}
	// Pieces read as neither wanted nor present while the client is still
	// deciding what it has on disk, and an unchecked piece says nothing about
	// what was set here.
	waitForPieceCheck(t, tor, 30*time.Second)
	return tasks, tor
}

// waitForPieceCheck waits until the client knows what each piece is, which is
// when a piece priority becomes something other than "not wanted yet".
func waitForPieceCheck(t *testing.T, tor *atorrent.Torrent, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		checked := true
		for index := range tor.NumPieces() {
			if state := tor.PieceState(index); state.Checking || !state.Ok {
				checked = false
				break
			}
		}
		if checked {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for the initial piece check")
		}
		time.Sleep(10 * time.Millisecond)
	}
}
