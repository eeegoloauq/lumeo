package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/local"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// startDownloadRequest is the client saying "I picked this one": the source it
// chose from /api/v1/sources, verbatim, plus what it is a source of.
type startDownloadRequest struct {
	ItemID  string              `json:"itemId"`
	Season  int                 `json:"season"`
	Episode int                 `json:"episode"`
	Source  sources.MediaSource `json:"source"`
	// Prefetch is a download nobody asked for yet: the next episode, started
	// only when it fits inside the free disk and the disk limit.
	Prefetch bool `json:"prefetch"`
}

func (s *Server) handleStartDownload(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	var req startDownloadRequest
	if !readJSON(w, r, &req) {
		return
	}
	if req.Source.Locator.Scheme == "" {
		writeError(w, http.StatusBadRequest, "source.locator is required")
		return
	}
	// Only the core knows what the downloads take and which of them the limit
	// would free, so whether a prefetch fits is its answer.
	if req.Prefetch {
		if s.library == nil {
			writeError(w, http.StatusServiceUnavailable, "the library is not configured")
			return
		}
		fits, err := s.library.Fits(r.Context(), req.Source.Size)
		if err != nil {
			s.log.Warn("measuring room for a prefetch failed", "err", err)
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if !fits {
			writeError(w, http.StatusInsufficientStorage, "no room for a prefetch inside the disk limit and the free disk")
			return
		}
	}
	start := func() (acquire.Download, error) {
		return s.downloads.Start(r.Context(), acquire.Request{
			ItemID:  req.ItemID,
			Season:  req.Season,
			Episode: req.Episode,
			Source:  req.Source,
		})
	}
	var d acquire.Download
	var err error
	if s.library != nil {
		d, err = s.library.Start(start)
	} else {
		d, err = start()
	}
	if err != nil {
		s.log.Warn("starting download failed", "err", err)
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	// A copy listed from disk carries no pack name; replaying it is not a new pick.
	if s.progress != nil && req.Source.ProviderID != "local" {
		if err := s.progress.RememberSource(r.Context(), req.ItemID, req.Source.BingeGroup); err != nil {
			// The download is running; forgetting the pick costs the next
			// episode its default, not this one its start.
			s.log.Warn("remembering the source failed", "item", req.ItemID, "err", err)
		}
	}
	// A new download can take the library over its ceiling.
	if s.library != nil {
		s.library.Kick()
	}
	writeJSON(w, http.StatusCreated, d)
}

func (s *Server) handleLocal(w http.ResponseWriter, r *http.Request) {
	if s.local == nil {
		writeError(w, http.StatusServiceUnavailable, "local files are not configured")
		return
	}
	var body struct {
		Path string `json:"path"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	if body.Path == "" {
		writeError(w, http.StatusBadRequest, "path is required")
		return
	}
	d, err := s.local.Open(r.Context(), body.Path)
	switch {
	case errors.Is(err, local.ErrNotVideo):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, os.ErrNotExist):
		writeError(w, http.StatusNotFound, err.Error())
	case err != nil:
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		writeJSON(w, http.StatusCreated, d)
	}
}

func (s *Server) handleDownloads(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"downloads": s.downloads.List(r.Context())})
}

func (s *Server) handleDownload(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	d, err := s.downloads.Get(r.Context(), r.PathValue("id"))
	if errors.Is(err, acquire.ErrNotFound) {
		writeError(w, http.StatusNotFound, "unknown download")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// handlePatchDownload pauses or resumes a download: {"paused": true} or
// {"paused": false}, nothing else.
func (s *Server) handlePatchDownload(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	var patch map[string]json.RawMessage
	if !readJSON(w, r, &patch) {
		return
	}
	// Spelled out: null would decode into a bool as false, a resume nobody
	// asked for.
	value := string(patch["paused"])
	if len(patch) != 1 || value != "true" && value != "false" {
		writeError(w, http.StatusBadRequest, `request body must be {"paused": true} or {"paused": false}`)
		return
	}
	paused := value == "true"
	d, err := s.downloads.SetPaused(r.Context(), r.PathValue("id"), paused)
	switch {
	case errors.Is(err, acquire.ErrNotFound):
		writeError(w, http.StatusNotFound, "unknown download")
	case errors.Is(err, acquire.ErrNothingToFetch):
		writeError(w, http.StatusBadRequest, "download has nothing left to fetch")
	case err != nil:
		s.log.Warn("pausing download failed", "download", r.PathValue("id"), "paused", paused, "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		writeJSON(w, http.StatusOK, d)
	}
}

// handleRemoveDownload stops a download. ?data=true also throws away what it
// already fetched; without it the bytes stay, which is what "stop" usually
// means to someone who is out of bandwidth, not out of disk.
func (s *Server) handleRemoveDownload(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	deleteData := r.URL.Query().Get("data") == "true"
	err := s.downloads.Remove(r.Context(), r.PathValue("id"), deleteData)
	if errors.Is(err, acquire.ErrNotFound) {
		writeError(w, http.StatusNotFound, "unknown download")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
