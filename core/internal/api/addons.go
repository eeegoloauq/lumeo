package api

import (
	"errors"
	"net/http"

	"github.com/eeegoloauq/lumeo/core/internal/addons"
)

func (s *Server) handleAddons(w http.ResponseWriter, r *http.Request) {
	if !s.haveAddons(w) {
		return
	}
	list := s.addons.List()
	if err := s.rewriteAddons(r, list); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"addons": list})
}

// handleAddAddon installs the addon at a URL — 201 — or, when the manifest
// there names an addon already installed, points that one at the new URL
// and answers 200. Either way the manifest was fetched first; a URL nothing
// answers at is a 400 that says so.
func (s *Server) handleAddAddon(w http.ResponseWriter, r *http.Request) {
	if !s.haveAddons(w) {
		return
	}
	var body struct {
		URL string `json:"url"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	addon, created, err := s.addons.Add(r.Context(), body.URL)
	if errors.Is(err, addons.ErrInvalid) {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err != nil {
		s.log.Warn("adding addon failed", "url", body.URL, "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	status := http.StatusOK
	if created {
		status = http.StatusCreated
	}
	list := []addons.Addon{addon}
	if err := s.rewriteAddons(r, list); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, status, list[0])
}

func (s *Server) handlePatchAddon(w http.ResponseWriter, r *http.Request) {
	if !s.haveAddons(w) {
		return
	}
	var patch addons.Patch
	if !readJSON(w, r, &patch) {
		return
	}
	addon, err := s.addons.Update(r.Context(), r.PathValue("id"), patch)
	switch {
	case errors.Is(err, addons.ErrNotFound):
		writeError(w, http.StatusNotFound, "unknown addon")
	case errors.Is(err, addons.ErrInvalid):
		writeError(w, http.StatusBadRequest, err.Error())
	case err != nil:
		s.log.Warn("updating addon failed", "addon", r.PathValue("id"), "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		list := []addons.Addon{addon}
		if err := s.rewriteAddons(r, list); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, list[0])
	}
}

func (s *Server) handleRemoveAddon(w http.ResponseWriter, r *http.Request) {
	if !s.haveAddons(w) {
		return
	}
	err := s.addons.Remove(r.Context(), r.PathValue("id"))
	switch {
	case errors.Is(err, addons.ErrNotFound):
		writeError(w, http.StatusNotFound, "unknown addon")
	case err != nil:
		s.log.Warn("removing addon failed", "addon", r.PathValue("id"), "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
