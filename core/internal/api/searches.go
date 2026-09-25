package api

import (
	"errors"
	"net/http"

	"github.com/eeegoloauq/lumeo/core/internal/searches"
)

// What the viewer searched for: offered again under an empty search field.

func (s *Server) handleSearches(w http.ResponseWriter, r *http.Request) {
	if !s.haveSearches(w) {
		return
	}
	recent, err := s.searches.Recent(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"searches": recent})
}

func (s *Server) handleRecordSearch(w http.ResponseWriter, r *http.Request) {
	if !s.haveSearches(w) {
		return
	}
	var body struct {
		Query string `json:"query"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	s.answerSearchChange(w, s.searches.Record(r.Context(), body.Query))
}

// handleForgetSearches forgets the search in ?q=, or every one without it.
func (s *Server) handleForgetSearches(w http.ResponseWriter, r *http.Request) {
	if !s.haveSearches(w) {
		return
	}
	if !r.URL.Query().Has("q") {
		s.answerSearchChange(w, s.searches.Clear(r.Context()))
		return
	}
	s.answerSearchChange(w, s.searches.Forget(r.Context(), r.URL.Query().Get("q")))
}

func (s *Server) answerSearchChange(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, searches.ErrInvalid):
		writeError(w, http.StatusBadRequest, err.Error())
	case err != nil:
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (s *Server) haveSearches(w http.ResponseWriter) bool {
	if s.searches == nil {
		writeError(w, http.StatusServiceUnavailable, "search history is not configured")
		return false
	}
	return true
}
