package api

import (
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
		s.clean()
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
	s.clean()
	writeJSON(w, http.StatusOK, prefs)
}

// clean asks for a pass of the changed keep policy without waiting for it: a
// pass that frees many downloads takes longer than a client waits for an
// answer, and the Storage list shows what it freed on its next refresh.
func (s *Server) clean() {
	if s.library != nil {
		s.library.Kick()
	}
}

func (s *Server) handlePreferenceLanguages(w http.ResponseWriter, _ *http.Request) {
	if !s.havePreferences(w) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"languages": subtitles.Languages()})
}
