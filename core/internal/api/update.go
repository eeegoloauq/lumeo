package api

import (
	"net/http"
	"time"
)

// handleUpdate answers with a published release newer than this core, or
// 204 when there is none, when the viewer turned the check off, or when
// GitHub could not be asked: a failed look is not something to show.
func (s *Server) handleUpdate(w http.ResponseWriter, r *http.Request) {
	if s.updates == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if !s.havePreferences(w) {
		return
	}
	prefs, err := s.prefs.Get(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if !prefs.CheckUpdates {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	release, err := s.updates.Newer(r.Context(), time.Now())
	if err != nil {
		s.log.Warn("checking for a newer release failed", "err", err)
	}
	if release == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, release)
}
