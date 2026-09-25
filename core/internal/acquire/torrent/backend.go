// Package torrent acquires media from BitTorrent swarms.
package torrent

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	atorrent "github.com/anacrolix/torrent"
	"github.com/anacrolix/torrent/metainfo"
	"github.com/anacrolix/torrent/storage"
	"golang.org/x/time/rate"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/egress"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

const readerReadahead = 32 << 20 // Large enough to smooth typical video bitrates without chasing far past a seek.

var videoExtensions = map[string]struct{}{
	".avi":  {},
	".m4v":  {},
	".mkv":  {},
	".mp4":  {},
	".ts":   {},
	".webm": {},
}

// Config controls the shared BitTorrent client. Seed and the limits are where
// it starts: SetSeed and SetLimits change them while it runs.
type Config struct {
	Port          int
	Seed          bool
	UploadLimit   int64 // bytes per second, 0 for none
	DownloadLimit int64
	DataDir       string
	// Peers bypass DHT discovery for tests and closed local sources.
	Peers []atorrent.PeerInfo
}

// sharedTorrent is one torrent in the client, and the count of downloads that
// want it. Season packs are the reason this exists: two episodes of the same
// pack are two downloads over one infohash, and anacrolix will only hold one
// torrent — with one storage, in one directory — per infohash.
type sharedTorrent struct {
	torrent *atorrent.Torrent
	storage storage.ClientImplCloser
	dir     string
	refs    int

	// Who still wants what, by file path and by piece. A pack outlives the
	// episode that opened it, and what that episode asked the swarm for has to
	// go when it does — otherwise a stopped episode keeps competing for peers
	// with the one being watched. Counted rather than flagged because the
	// piece where two episodes meet is asked for by both.
	wanted map[string]int
	ends   map[int]int

	// uploading is whether the torrent is let upload, as last set.
	uploading bool
}

// Backend owns one client shared by every active torrent.
type Backend struct {
	client *atorrent.Client
	peers  []atorrent.PeerInfo

	upload, download *limiter
	seed             atomic.Bool

	mu        sync.Mutex
	closed    bool
	tasks     map[*task]struct{}
	shared    map[metainfo.Hash]*sharedTorrent
	closeErr  error
	closeOnce sync.Once
}

var _ acquire.Backend = (*Backend)(nil)

func New(cfg Config) (*Backend, error) {
	if cfg.DataDir != "" {
		if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
			return nil, fmt.Errorf("torrent: create client data dir: %w", err)
		}
	}

	b := &Backend{
		peers:    append([]atorrent.PeerInfo(nil), cfg.Peers...),
		upload:   newLimiter(),
		download: newLimiter(),
		tasks:    make(map[*task]struct{}),
		shared:   make(map[metainfo.Hash]*sharedTorrent),
	}
	b.seed.Store(cfg.Seed)
	b.SetLimits(cfg.UploadLimit, cfg.DownloadLimit)

	clientConfig := atorrent.NewDefaultClientConfig()
	clientConfig.DataDir = cfg.DataDir
	clientConfig.ListenPort = cfg.Port
	// The client's own Seed cannot change while it runs, so it is on and
	// seeding is decided per torrent instead (setUpload).
	clientConfig.Seed = true
	// Ours rather than the default: that one is a package variable every
	// client in the process shares, and ours are changed while it runs.
	clientConfig.UploadRateLimiter = b.upload.rate
	clientConfig.DownloadRateLimiter = b.download.rate
	// A media app should not punch a hole in the user's router behind their
	// back: UPnP mapping is a change to their network, not to our process.
	// Peers still reach us through outgoing connections, holepunching and
	// whatever the user forwards deliberately.
	clientConfig.NoDefaultPortForwarding = true
	clientConfig.Slogger = slog.New(slog.NewTextHandler(io.Discard, nil))
	if len(cfg.Peers) != 0 {
		clientConfig.NoDHT = true
	}
	// anacrolix skips an address family it cannot bind, but not one the kernel
	// lacks altogether (ipv6.disable=1, some containers): there it fails the
	// whole client. Such a host has no IPv6 peers to lose.
	if !ipv6Supported() {
		clientConfig.DisableIPv6 = true
	}
	// Tracker URLs come from addons: an HTTP announce is a GET with a path and
	// query they choose, so it goes only to public addresses. (A UDP announce
	// is a binary handshake nothing on a LAN answers to.)
	clientConfig.TrackerDialContext = egress.PublicDialContext

	client, err := atorrent.NewClient(clientConfig)
	if err != nil {
		return nil, fmt.Errorf("torrent: create client: %w", err)
	}
	b.client = client
	return b, nil
}

// SetLimits caps what the client uploads and downloads, in bytes per second,
// 0 for no cap. The limiters are the client's own, so the next block sent or
// read is held to the new rate, on every torrent.
func (b *Backend) SetLimits(upload, download int64) {
	b.upload.set(upload)
	b.download.set(download)
}

// SetSeed turns seeding on or off for every torrent at once, running ones
// included.
func (b *Backend) SetSeed(on bool) {
	b.seed.Store(on)
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, sh := range b.shared {
		b.setUpload(sh)
	}
}

// setUpload lets a torrent upload unless seeding is off and it has every
// piece it was asked for. One still fetching keeps trading with its peers:
// a client that gives nothing back is choked by them. The caller holds mu.
func (b *Backend) setUpload(sh *sharedTorrent) {
	upload := b.seed.Load() || sh.fetching()
	if upload == sh.uploading {
		return
	}
	sh.uploading = upload
	if upload {
		sh.torrent.AllowDataUpload()
	} else {
		sh.torrent.DisallowDataUpload()
	}
}

// fetching says whether any file a download wants is still incomplete. Before
// the metadata, or before a download has picked its file, that is unknown,
// and counts as fetching.
func (sh *sharedTorrent) fetching() bool {
	if sh.torrent.Info() == nil || len(sh.wanted) == 0 {
		return true
	}
	for _, file := range sh.torrent.Files() {
		if sh.wanted[file.Path()] > 0 && file.BytesCompleted() < file.Length() {
			return true
		}
	}
	return false
}

// watchPieces re-decides whether a torrent uploads as its pieces come in:
// the last one it wanted is where seeding would start. It ends with the
// torrent.
func (b *Backend) watchPieces(hash metainfo.Hash, sh *sharedTorrent) {
	changes := sh.torrent.SubscribePieceStateChanges()
	defer changes.Close()
	for {
		select {
		case <-sh.torrent.Closed():
			return
		case change, ok := <-changes.Values:
			if !ok {
				return
			}
			b.mu.Lock()
			// Only a completion can end the fetching, and only a piece that
			// stopped being complete (a failed check) can start it again.
			if b.shared[hash] == sh && (change.Complete || !sh.uploading) {
				b.setUpload(sh)
			}
			b.mu.Unlock()
		}
	}
}

// minBurst is the smallest burst a limiter is given: a whole chunk has to fit
// in it, or anacrolix refuses to send it at all, and small reads cost more
// than they limit. 1 MiB is what anacrolix itself picks.
const minBurst = 1 << 20

// limiter is one of the client's rate limiters, which it reads on every
// block, changed while the client runs.
type limiter struct {
	rate *rate.Limiter

	mu   sync.Mutex
	last time.Time
}

func newLimiter() *limiter {
	// A burst already set: the client would otherwise pick its own on start.
	return &limiter{rate: rate.NewLimiter(rate.Inf, minBurst)}
}

func (l *limiter) set(bytesPerSecond int64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	// Changed at the very instant of the change before, while the limit is
	// infinite, the limiter counts its tokens as 0 × Inf: NaN, which never
	// runs out, and the limit would never hold again. Every change here is
	// strictly later than the last.
	now := time.Now()
	if !now.After(l.last) {
		now = l.last.Add(time.Nanosecond)
	}
	l.last = now
	if bytesPerSecond <= 0 {
		l.rate.SetLimitAt(now, rate.Inf)
		return
	}
	l.rate.SetLimitAt(now, rate.Limit(bytesPerSecond))
	l.rate.SetBurstAt(now, int(max(minBurst, min(bytesPerSecond, 1<<30))))
}

func ipv6Supported() bool {
	l, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		return !errors.Is(err, syscall.EAFNOSUPPORT)
	}
	l.Close()
	return true
}

func (b *Backend) Scheme() string {
	return "torrent"
}

func (b *Backend) Start(ctx context.Context, loc sources.Locator, dir string) (acquire.Task, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if loc.Scheme != b.Scheme() {
		return nil, fmt.Errorf("torrent: unsupported locator scheme %q", loc.Scheme)
	}

	var infoHash metainfo.Hash
	if err := infoHash.FromHexString(loc.InfoHash); err != nil {
		return nil, fmt.Errorf("torrent: invalid info hash: %w", err)
	}
	if infoHash.IsZero() {
		return nil, errors.New("torrent: info hash is zero")
	}
	absDir, err := filepath.Abs(dir)
	if err != nil {
		return nil, fmt.Errorf("torrent: resolve download dir: %w", err)
	}
	if err := os.MkdirAll(absDir, 0o700); err != nil {
		return nil, fmt.Errorf("torrent: create download dir: %w", err)
	}

	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil, errors.New("torrent: backend is closed")
	}

	sh, running := b.shared[infoHash]
	if !running {
		fileStorage, err := newFileStorage(absDir)
		if err != nil {
			return nil, err
		}
		tor, added := b.client.AddTorrentOpt(atorrent.AddTorrentOpts{
			InfoHash: infoHash,
			Storage:  fileStorage,
		})
		if !added {
			// The client knows this infohash but we do not, so we cannot tell
			// where its data lives or who owns its storage.
			if err := fileStorage.Close(); err != nil {
				return nil, fmt.Errorf("torrent: close unused storage: %w", err)
			}
			return nil, fmt.Errorf("torrent: info hash %s is active outside this backend", infoHash.HexString())
		}
		sh = &sharedTorrent{
			torrent:   tor,
			storage:   fileStorage,
			dir:       absDir,
			wanted:    map[string]int{},
			ends:      map[int]int{},
			uploading: true,
		}
		b.shared[infoHash] = sh
		go b.watchPieces(infoHash, sh)
	}
	sh.refs++
	if len(loc.Trackers) != 0 {
		sh.torrent.AddTrackers([][]string{append([]string(nil), loc.Trackers...)})
	}
	if len(b.peers) != 0 {
		sh.torrent.AddPeers(b.peers)
	}

	t := &task{
		backend: b,
		torrent: sh.torrent,
		// The bytes are where the first download of this torrent put them,
		// which is not necessarily the directory this call asked for.
		dir:      sh.dir,
		infoHash: infoHash,
	}
	if loc.FileIndex != nil {
		t.fileIndex = *loc.FileIndex
		t.hasFileIndex = true
	}
	t.onClose = func() error {
		b.mu.Lock()
		delete(b.tasks, t)
		b.mu.Unlock()
		return b.release(infoHash)
	}
	b.tasks[t] = struct{}{}
	go t.selectFile()
	return t, nil
}

// release drops a torrent once the last download that wanted it is gone.
func (b *Backend) release(infoHash metainfo.Hash) error {
	b.mu.Lock()
	sh, ok := b.shared[infoHash]
	if !ok {
		b.mu.Unlock()
		return nil
	}
	sh.refs--
	if sh.refs > 0 {
		b.mu.Unlock()
		return nil
	}
	delete(b.shared, infoHash)
	b.mu.Unlock()

	sh.torrent.Drop()
	return sh.storage.Close()
}

func (b *Backend) Close() error {
	b.closeOnce.Do(func() {
		b.mu.Lock()
		b.closed = true
		tasks := make([]*task, 0, len(b.tasks))
		for t := range b.tasks {
			tasks = append(tasks, t)
		}
		b.mu.Unlock()

		// Tasks first: they drop torrents and close storages, which a closed
		// client can no longer do for them.
		for _, t := range tasks {
			b.closeErr = errors.Join(b.closeErr, t.Close())
		}
		for _, err := range b.client.Close() {
			b.closeErr = errors.Join(b.closeErr, err)
		}
	})
	return b.closeErr
}

type task struct {
	backend  *Backend
	torrent  *atorrent.Torrent
	dir      string
	infoHash metainfo.Hash

	fileIndex    int
	hasFileIndex bool
	onClose      func() error

	mu     sync.RWMutex
	file   *torrentFile
	closed bool

	rateMu        sync.Mutex
	lastRateAt    time.Time
	lastRateBytes int64

	closeOnce sync.Once
	closeErr  error
}

var _ acquire.Task = (*task)(nil)

func (t *task) selectFile() {
	select {
	case <-t.torrent.GotInfo():
	case <-t.torrent.Closed():
		return
	}
	select {
	case <-t.torrent.Closed():
		return
	default:
	}

	selected := chooseFile(t.torrent.Files(), t.fileIndex, t.hasFileIndex)
	if selected == nil {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return
	}
	// File names inside a torrent are written by strangers. anacrolix already
	// refuses to open storage for a path that escapes the download directory,
	// so such a torrent never produces bytes — but the path we report is ours
	// to compute, and it must not point outside either.
	path, ok := safeFilePath(t.dir, selected.Path())
	if !ok {
		return
	}
	t.backend.want(t.infoHash, selected)
	t.file = &torrentFile{file: selected, path: path}
}

// want asks the swarm for a file, and records who is asking.
//
// The ends of it go first. A player does not always start a file from the
// front alone: Matroska keeps its index wherever the muxer put it, and a
// demuxer that goes looking for it reads the last bytes of the file before it
// shows the first frame. Left at the priority of everything else those bytes
// arrive whenever the swarm gets round to them — minutes, on the two peers a
// fresh magnet starts with. It is a hedge, not a guarantee: an index longer
// than one piece still has to be waited for, and the reader remains what
// actually decides what is urgent.
func (b *Backend) want(hash metainfo.Hash, file *atorrent.File) {
	b.mu.Lock()
	defer b.mu.Unlock()
	sh, ok := b.shared[hash]
	if !ok {
		return
	}
	sh.wanted[file.Path()]++
	file.Download()
	for _, piece := range ends(file) {
		sh.ends[piece]++
		sh.torrent.Piece(piece).SetPriority(atorrent.PiecePriorityNext)
	}
	// A new episode of a pack that was only seeding is fetching again.
	b.setUpload(sh)
}

// unwant is the other half: what the last reader of a file asked for goes with
// it, and nothing a still-running episode asked for goes with it.
//
// Priorities are put back to none rather than to normal. None is what a piece
// nobody named has, and the file's own priority decides from there — set them
// to normal instead and a file nothing wants any more would still be asked
// for, one piece at each end.
func (b *Backend) unwant(hash metainfo.Hash, file *atorrent.File) {
	b.mu.Lock()
	defer b.mu.Unlock()
	sh, ok := b.shared[hash]
	if !ok {
		return
	}
	path := file.Path()
	sh.wanted[path]--
	if sh.wanted[path] > 0 {
		return
	}
	delete(sh.wanted, path)
	// What is left wanted may all be here already.
	defer b.setUpload(sh)
	file.SetPriority(atorrent.PiecePriorityNone)
	for _, piece := range ends(file) {
		sh.ends[piece]--
		if sh.ends[piece] > 0 {
			continue
		}
		delete(sh.ends, piece)
		sh.torrent.Piece(piece).SetPriority(atorrent.PiecePriorityNone)
	}
}

// ends is the first and the last piece holding any of the file, without
// repeating itself when the file fits inside one.
func ends(file *atorrent.File) []int {
	begin, end := file.BeginPieceIndex(), file.EndPieceIndex()
	switch {
	case end <= begin:
		return nil
	case end-begin == 1:
		return []int{begin}
	default:
		return []int{begin, end - 1}
	}
}

func chooseFile(files []*atorrent.File, fileIndex int, hasFileIndex bool) *atorrent.File {
	if hasFileIndex && fileIndex >= 0 && fileIndex < len(files) {
		return files[fileIndex]
	}

	var largestVideo *atorrent.File
	var largest *atorrent.File
	for _, file := range files {
		if largest == nil || file.Length() > largest.Length() {
			largest = file
		}
		if _, ok := videoExtensions[strings.ToLower(filepath.Ext(file.Path()))]; ok &&
			(largestVideo == nil || file.Length() > largestVideo.Length()) {
			largestVideo = file
		}
	}
	if largestVideo != nil {
		return largestVideo
	}
	return largest
}

// safeFilePath resolves a path from torrent metadata against the download
// directory, refusing anything that would land outside it.
func safeFilePath(dir, torrentPath string) (string, bool) {
	full := filepath.Join(dir, filepath.FromSlash(torrentPath))
	rel, err := filepath.Rel(dir, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", false
	}
	return full, true
}

func (t *task) Progress() acquire.Progress {
	t.mu.RLock()
	file := t.file
	t.mu.RUnlock()

	stats := t.torrent.Stats()
	progress := acquire.Progress{
		Peers:   stats.ActivePeers,
		Seeders: stats.ConnectedSeeders,
	}
	if file != nil {
		progress.Completed = file.file.BytesCompleted()
		progress.Total = file.file.Length()
	}

	now := time.Now()
	bytesRead := stats.BytesReadUsefulData.Int64()
	progress.Received = bytesRead
	t.rateMu.Lock()
	if !t.lastRateAt.IsZero() {
		elapsed := now.Sub(t.lastRateAt)
		delta := bytesRead - t.lastRateBytes
		if elapsed > 0 && delta > 0 {
			progress.Rate = delta * int64(time.Second) / elapsed.Nanoseconds()
		}
	}
	t.lastRateAt = now
	t.lastRateBytes = bytesRead
	t.rateMu.Unlock()
	return progress
}

func (t *task) File() (acquire.File, bool) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	if t.file == nil {
		return nil, false
	}
	return t.file, true
}

func (t *task) Close() error {
	t.closeOnce.Do(func() {
		t.mu.Lock()
		t.closed = true
		file := t.file
		t.file = nil
		t.mu.Unlock()

		// Stop asking the swarm for this episode. The torrent may well stay —
		// another episode of the same pack can still be running — and then
		// nobody else would ever take this file off it.
		if file != nil {
			t.backend.unwant(t.infoHash, file.file)
		}

		// The torrent itself is dropped only when the last task on it goes:
		// another episode of the same pack may still be downloading.
		if t.onClose != nil {
			t.closeErr = t.onClose()
		}
	})
	return t.closeErr
}

type torrentFile struct {
	file *atorrent.File
	path string
}

var _ acquire.File = (*torrentFile)(nil)

func (f *torrentFile) Path() string {
	return f.path
}

func (f *torrentFile) Size() int64 {
	return f.file.Length()
}

// Head is the run of verified whole pieces at the start of the file: what the
// reader hands over without waiting. It stays at zero for exactly as long as
// it should — a magnet whose metadata arrived a second ago knows the name of a
// file it does not have a byte of.
func (f *torrentFile) Head() int64 {
	tor := f.file.Torrent()
	info := tor.Info()
	if info == nil || info.PieceLength <= 0 {
		return 0
	}
	whole := f.file.BeginPieceIndex()
	for whole < f.file.EndPieceIndex() && tor.PieceState(whole).Complete {
		whole++
	}
	head := int64(whole)*info.PieceLength - f.file.Offset()
	return max(0, min(head, f.file.Length()))
}

func (f *torrentFile) Open(ctx context.Context) (io.ReadSeekCloser, error) {
	reader := f.file.NewReader()
	// Without this a read blocks until the piece arrives even after the
	// request that wanted it is gone.
	reader.SetContext(ctx)
	// Not responsive: that hands over chunks before their piece is checked,
	// and a piece that fails the check has already reached the player.
	reader.SetReadahead(readerReadahead)
	return &boundedReader{reader: reader, size: f.file.Length()}, nil
}

// boundedReader stops a read at the end of the file. anacrolix computes how
// much is readable from the torrent's chunk map and clamps it to the caller's
// buffer, but not to the file the reader was opened on: ask for more than is
// left and you are handed the start of the next file in the torrent. Season
// packs make that the common case rather than the exotic one, and io.Copy or
// an HTTP range ending at EOF asks for exactly that.
type boundedReader struct {
	reader io.ReadSeekCloser
	size   int64
	pos    int64
}

func (b *boundedReader) Read(p []byte) (int, error) {
	if b.pos >= b.size {
		return 0, io.EOF
	}
	if left := b.size - b.pos; int64(len(p)) > left {
		p = p[:left]
	}
	n, err := b.reader.Read(p)
	b.pos += int64(n)
	return n, err
}

func (b *boundedReader) Seek(offset int64, whence int) (int64, error) {
	pos, err := b.reader.Seek(offset, whence)
	if err == nil {
		b.pos = pos
	}
	return pos, err
}

func (b *boundedReader) Close() error { return b.reader.Close() }
