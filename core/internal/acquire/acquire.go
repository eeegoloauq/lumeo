// Package acquire turns a chosen MediaSource into bytes on disk. The core
// never learns what BitTorrent is: it hands over a sources.Locator and gets
// back a Download it can watch, read from and throw away. Local files, HTTP
// and WebDAV are later Backends and nothing else changes.
package acquire

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"io"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

type State string

const (
	StateActive State = "active" // bytes are arriving
	StateDone   State = "done"   // the file is complete on disk
	StatePaused State = "paused" // known to us, nothing running
	StateFailed State = "failed"
)

// Request starts one acquisition. Everything except Source is there so the
// library knows later what this file actually is.
type Request struct {
	ItemID  string // our catalog id
	Season  int
	Episode int
	Source  sources.MediaSource
}

// Download is one acquisition as everything outside this package sees it.
// Progress is live from the backend; the rest survives a restart.
type Download struct {
	ID       string          `json:"id"`
	ItemID   string          `json:"itemId,omitempty"`
	Season   int             `json:"season,omitempty"`
	Episode  int             `json:"episode,omitempty"`
	Name     string          `json:"name"`
	Locator  sources.Locator `json:"locator"`
	Dir      string          `json:"-"` // where the backend writes; not the client's business
	FilePath string          `json:"-"`
	Size     int64           `json:"size,omitempty"`
	// Release is Name read the way the source list reads it, so a row can say
	// which copy it is (2160p, HDR) without the client parsing names itself.
	// Derived on every read, never stored: a better parser relabels old rows.
	Release release.Info `json:"release,omitzero"`
	// Ready means there is something to open: the backend has learned which
	// file this is and the beginning of it is on disk. Knowing the name was
	// not enough — a player handed a file with nothing at the front of it
	// blocks on its first read and, when its patience runs out, blames the
	// copy for a swarm that had simply not got there yet. Size alone says
	// less still: it comes from the source before anything has been fetched.
	Ready bool `json:"ready"`
	// Resolved means the backend knows which file of the source this is:
	// for a magnet link, its metadata has arrived. Before that a client can
	// say "fetching metadata" instead of a size and a rate that mean nothing.
	Resolved bool   `json:"resolved"`
	State    State  `json:"state"`
	Error    string `json:"error,omitempty"`
	// PausedByUser tells a pause somebody asked for from a download that
	// merely is not running; only the first stays paused until asked again.
	PausedByUser bool     `json:"pausedByUser,omitempty"`
	Progress     Progress `json:"progress"`
	// WaitingSince is when bytes last arrived, or the transfer started, while
	// an active download is getting none: no metadata yet, no peers, or peers
	// that have sent nothing for a while. A client says how long it has been
	// looking instead of showing a rate of zero.
	WaitingSince time.Time `json:"waitingSince,omitzero"`
	CreatedAt    time.Time `json:"createdAt"`
	UpdatedAt    time.Time `json:"updatedAt"`
}

// Progress is what a player bar shows while the file is still arriving.
type Progress struct {
	Completed int64 `json:"completed"` // bytes verified on disk
	Total     int64 `json:"total"`
	Peers     int   `json:"peers,omitempty"`
	Seeders   int   `json:"seeders,omitempty"`
	Rate      int64 `json:"rate,omitempty"` // bytes per second, download side
	// ETA is whole seconds to the end at the smoothed rate, given only while
	// bytes are arriving.
	ETA int64 `json:"eta,omitempty"`
	// Received counts the payload bytes the transfer has taken in so far,
	// checked or not. It moves with every block, where Completed moves a
	// whole piece at a time: minutes apart on a slow swarm.
	Received int64 `json:"-"`
}

// Backend acquires one Locator scheme.
type Backend interface {
	Scheme() string
	// Start begins or resumes acquiring loc into dir and returns once the
	// transfer is running — the bytes keep arriving in the background. It
	// never deletes anything in dir; discarding data is the manager's call.
	Start(ctx context.Context, loc sources.Locator, dir string) (Task, error)
	Close() error
}

// Task is one running acquisition inside a backend.
type Task interface {
	// Progress must be cheap: the API polls it per request.
	Progress() Progress
	// File is the playable file. It reports false until the transfer has
	// learned what it is downloading, which for a magnet link means after
	// the metadata arrives.
	File() (File, bool)
	// Close stops the transfer and leaves the data where it is.
	Close() error
}

// File is the one video the download is about. Open returns a reader that
// blocks until the bytes it needs have arrived, which is what makes playing
// a half-downloaded file work — and what forces the backend to fetch pieces
// in the order the player asks for them.
//
// The context belongs to whoever is reading — an HTTP request, usually — and
// cancelling it must unblock a read that is waiting for bytes. Without that,
// a player that seeks away or a viewer who closes the tab leaves a reader
// waiting for pieces nobody wants any more.
type File interface {
	Path() string
	Size() int64
	Open(ctx context.Context) (io.ReadSeekCloser, error)
	// Head is how many bytes at the start of the file can be read without
	// waiting for anybody. It is what [Download.Ready] is made of.
	Head() int64
}

// Store persists downloads so a restart does not lose them. Progress is not
// stored: it is cheaper to ask the backend than to keep it truthful.
type Store interface {
	SaveDownload(ctx context.Context, d Download) error
	Downloads(ctx context.Context) ([]Download, error)
	Download(ctx context.Context, id string) (Download, bool, error)
	DeleteDownload(ctx context.Context, id string) error
}

func newID() string {
	var v [8]byte
	if _, err := rand.Read(v[:]); err != nil {
		// crypto/rand does not fail on any platform we run on; if it ever
		// does, a time-based id is still better than a panic in a media app.
		return hex.EncodeToString([]byte(time.Now().UTC().Format("20060102150405.000000")))
	}
	return hex.EncodeToString(v[:])
}
