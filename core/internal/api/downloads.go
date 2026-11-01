package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"slices"

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
	// SubtitleLanguages are the ones a device of a media server wants kept
	// with the file, its viewer's preferences being kept on the device.
	SubtitleLanguages []string `json:"subtitleLanguages,omitempty"`
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
	if !validLanguages(req.SubtitleLanguages) {
		writeError(w, http.StatusBadRequest, errLanguages)
		return
	}
	s.startDownload(w, r, req)
}

func (s *Server) startDownload(w http.ResponseWriter, r *http.Request, req startDownloadRequest) {
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
	if !req.Prefetch && !s.roomFor(r.Context(), w, req.Source) {
		return
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
	if s.library != nil && !req.Prefetch {
		s.library.Picked(d.ID)
	}
	if s.viewerHere(r) {
		s.rememberPick(r.Context(), req)
	} else {
		// A device starting a copy is about to watch it, so not watched; the
		// pick is remembered on the device.
		// Its core holds it again on its next pass if this fails.
		hold, err := s.downloads.SetHold(r.Context(), d.ID, deviceOf(r), false, req.SubtitleLanguages)
		if err != nil {
			s.log.Warn("recording a device's hold failed", "download", d.ID, "err", err)
		} else {
			d.Holds = append(slices.DeleteFunc(d.Holds, func(h acquire.Hold) bool { return h.Device == hold.Device }), hold)
		}
	}
	// A new download can take the library over its ceiling.
	if s.library != nil {
		s.library.Kick()
	}
	writeJSON(w, http.StatusCreated, s.asSeenBy(r, d))
}

// rememberPick makes the pack of a started copy the one Play continues from.
// Replaying a copy listed from disk is not a new pick, and a copy of the
// release already chosen leaves the choice as it was, picked by hand or not.
func (s *Server) rememberPick(ctx context.Context, req startDownloadRequest) {
	if s.progress == nil || req.Source.ProviderID == "local" || s.alreadyChosen(ctx, req.ItemID, req.Source) {
		return
	}
	if err := s.progress.RememberSource(ctx, req.ItemID, packOf(req.Source)); err != nil {
		// The download is running; forgetting the pick costs the next
		// episode its default, not this one its start.
		s.log.Warn("remembering the source failed", "item", req.ItemID, "err", err)
	}
}

// roomFor refuses a copy larger than the free disk: it would fill the disk
// and fail part way. The disk limit is no reason to refuse one the viewer
// asked for, since a file over it stays until it is watched, and a copy
// already begun was let in when it started. The sizes go with the refusal
// for the client to say in the viewer's language.
func (s *Server) roomFor(ctx context.Context, w http.ResponseWriter, src sources.MediaSource) bool {
	if s.library == nil || src.Size <= 0 || src.Locator.Scheme == "file" {
		return true
	}
	if _, ok := s.downloads.Find(ctx, src.Locator); ok {
		return true
	}
	disk, _, err := s.library.Room(ctx)
	if err != nil {
		// Not knowing the room is no reason to refuse a film.
		s.log.Warn("measuring room for a download failed", "err", err)
		return true
	}
	if src.Size <= disk {
		return true
	}
	writeJSON(w, http.StatusInsufficientStorage, map[string]any{
		"error": fmt.Sprintf("not enough free space: the copy needs %d bytes, %d are free", src.Size, max(disk, 0)),
		"size":  src.Size,
		"free":  max(disk, 0),
	})
	return false
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
	rows := s.downloads.List(r.Context())
	out := make([]heldDownload, len(rows))
	for i, d := range rows {
		out[i] = s.asSeenBy(r, d)
	}
	writeJSON(w, http.StatusOK, map[string]any{"downloads": out})
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
	writeJSON(w, http.StatusOK, s.asSeenBy(r, d))
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
		writeJSON(w, http.StatusOK, s.asSeenBy(r, d))
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

func (s *Server) alreadyChosen(ctx context.Context, itemID string, src sources.MediaSource) bool {
	choice, err := s.progress.Choice(ctx, itemID)
	return err == nil && holds(choice.Pack, src)
}
