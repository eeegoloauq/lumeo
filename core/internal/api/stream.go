package api

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
)

// metadataWait is how long a stream request will hold while a magnet link
// learns what it is downloading. Long enough to cover the usual few seconds,
// short enough that a dead swarm answers rather than hangs.
const metadataWait = 15 * time.Second

// handleStream serves the file of a download over HTTP, ranges included, while
// it is still arriving. Range parsing, If-Range, 206 and 416 are left to
// http.ServeContent: this is exactly the code nobody should write twice.
func (s *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	id := r.PathValue("id")
	// Before the file is looked up: a pass freeing it either finished first,
	// and the lookup says so, or sees it playing and leaves it.
	if s.library != nil {
		defer s.library.Play(id)()
	}
	file, err := s.downloads.File(r.Context(), id, metadataWait)
	switch {
	case errors.Is(err, acquire.ErrNotFound):
		writeError(w, http.StatusNotFound, "unknown download")
		return
	case errors.Is(err, acquire.ErrNotRunning):
		writeError(w, http.StatusConflict, "download is not running and has no finished file")
		return
	case errors.Is(err, acquire.ErrNotReady):
		// Nothing is wrong; the swarm has not handed over the metadata yet.
		w.Header().Set("Retry-After", "2")
		writeError(w, http.StatusServiceUnavailable, "file is not known yet, retry shortly")
		return
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return // the player gave up; there is nobody to answer
	case err != nil:
		s.log.Warn("stream failed", "download", id, "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	reader, err := file.Open(r.Context())
	if err != nil {
		s.log.Warn("opening stream failed", "download", id, "err", err)
		writeError(w, http.StatusInternalServerError, "cannot read the file")
		return
	}
	defer reader.Close()

	name := filepath.Base(file.Path())
	// Set the type ourselves: left to sniff, ServeContent reads the first 512
	// bytes, which on a fresh download means blocking a HEAD request until the
	// first piece arrives.
	w.Header().Set("Content-Type", contentType(name))
	w.Header().Set("X-Content-Type-Options", "nosniff")
	// The bytes behind an id never change — a torrent is its content — so a
	// strong validator is honest here, and it is what makes a player's
	// If-Range revalidation on seek work instead of refetching.
	etag := id
	if d, err := s.downloads.Get(r.Context(), id); err == nil && d.Locator.Scheme == "file" {
		if stat, err := os.Stat(file.Path()); err == nil {
			etag += "-" + strconv.FormatInt(stat.Size(), 10) + "-" + strconv.FormatInt(stat.ModTime().UnixNano(), 10)
		}
	}
	w.Header().Set("ETag", strconv.Quote(etag))
	body := &streamBody{ReadSeeker: reader}
	http.ServeContent(w, r, name, time.Time{}, body)
	// ServeContent reads no further than the response promised, so a read
	// that stopped while the player still wanted the bytes, EOF included, cut
	// it short. The player takes a short stream for the end of the file and
	// moves on to the next episode; this is the only trace of why.
	if body.err != nil && r.Context().Err() == nil {
		s.log.Warn("stream cut short", "download", id, "at", body.pos, "size", file.Size(), "err", body.err)
	}
}

// streamBody keeps how far a stream's reads got and what stopped them.
type streamBody struct {
	io.ReadSeeker
	pos int64
	err error
}

func (b *streamBody) Read(p []byte) (int, error) {
	n, err := b.ReadSeeker.Read(p)
	b.pos += int64(n)
	if err != nil && b.err == nil {
		b.err = err
	}
	return n, err
}

func (b *streamBody) Seek(offset int64, whence int) (int64, error) {
	pos, err := b.ReadSeeker.Seek(offset, whence)
	if err == nil {
		b.pos = pos
	}
	return pos, err
}

// contentType keeps the containers that actually turn up in releases, because
// the system mime database usually has never heard of Matroska.
func contentType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mkv":
		return "video/x-matroska"
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".webm":
		return "video/webm"
	case ".avi":
		return "video/x-msvideo"
	case ".ts", ".m2ts":
		return "video/mp2t"
	case ".mov":
		return "video/quicktime"
	case ".mpg", ".mpeg":
		return "video/mpeg"
	case ".wmv":
		return "video/x-ms-wmv"
	case ".flv":
		return "video/x-flv"
	case ".ogv":
		return "video/ogg"
	case ".3gp":
		return "video/3gpp"
	}
	// Never the system's type for the extension: a torrent can name its file
	// page.html, and served as text/html from this origin it would run with
	// the API's reach.
	return "application/octet-stream"
}
