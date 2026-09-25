package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"

	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

func (s *Server) handlePreferences(w http.ResponseWriter, r *http.Request) {
	if !s.havePreferences(w) {
		return
	}
	prefs, err := s.prefs.Get(r.Context())
	if err != nil {
		s.log.Warn("reading preferences failed", "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, prefs)
}

func (s *Server) handlePatchPreferences(w http.ResponseWriter, r *http.Request) {
	if !s.havePreferences(w) {
		return
	}
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "content type must be application/json")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		writeError(w, http.StatusBadRequest, "malformed request body")
		return
	}
	prefs, err := s.prefs.Patch(r.Context(), body)
	if errors.Is(err, preferences.ErrInvalid) {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err != nil {
		s.log.Warn("updating preferences failed", "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	var changed map[string]json.RawMessage
	if json.Unmarshal(body, &changed) == nil &&
		(changed["keep"] != nil || changed["keepDays"] != nil || changed["diskLimit"] != nil) {
		s.clean(r.Context())
	}
	writeJSON(w, http.StatusOK, prefs)
}

// handleResetPreferences puts every preference back to its default. Nothing
// else goes with them: downloads, lists, history and addons are not
// preferences.
func (s *Server) handleResetPreferences(w http.ResponseWriter, r *http.Request) {
	if !s.havePreferences(w) {
		return
	}
	prefs, err := s.prefs.Reset(r.Context())
	if err != nil {
		s.log.Warn("resetting preferences failed", "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.clean(r.Context())
	writeJSON(w, http.StatusOK, prefs)
}

// clean runs a pass of the keep policy before a change of it is answered, so
// the Storage list a client reads next already shows what it freed.
func (s *Server) clean(ctx context.Context) {
	if s.library == nil {
		return
	}
	if err := s.library.Clean(ctx); err != nil {
		s.log.Warn("cleaning the library failed", "err", err)
	}
}

func (s *Server) handlePreferenceLanguages(w http.ResponseWriter, _ *http.Request) {
	if !s.havePreferences(w) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"languages": subtitles.Languages()})
}
