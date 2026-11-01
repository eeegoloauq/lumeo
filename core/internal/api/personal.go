package api

import (
	"encoding/json"
	"errors"
	"mime"
	"net/http"

	"github.com/eeegoloauq/lumeo/core/internal/personal"
)

// The viewer's own data as one file, to carry to another core.

// maxPersonal bounds an import. Years of watching are a few megabytes.
const maxPersonal = 32 << 20

func (s *Server) handleExportPersonal(w http.ResponseWriter, r *http.Request) {
	if !s.havePersonal(w) {
		return
	}
	doc, err := s.personal.Export(r.Context())
	if err != nil {
		s.log.Warn("personal data export failed", "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="lumeo-`+doc.ExportedAt.Format("2006-01-02")+`.json"`)
	writeJSON(w, http.StatusOK, doc)
}

func (s *Server) handleImportPersonal(w http.ResponseWriter, r *http.Request) {
	if !s.havePersonal(w) {
		return
	}
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "content type must be application/json")
		return
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPersonal))
	var doc personal.Document
	err = decoder.Decode(&doc)
	if err == nil && decoder.More() {
		err = errors.New("data after the document")
	}
	var tooLarge *http.MaxBytesError
	switch {
	case errors.As(err, &tooLarge):
		writeError(w, http.StatusRequestEntityTooLarge, "the file is larger than personal data can be")
		return
	case err != nil:
		writeError(w, http.StatusBadRequest, "not a Lumeo personal data file")
		return
	}
	counts, err := s.personal.Import(r.Context(), doc)
	switch {
	case errors.Is(err, personal.ErrInvalid):
		writeError(w, http.StatusBadRequest, err.Error())
	case err != nil:
		s.log.Warn("personal data import failed", "err", err)
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		writeJSON(w, http.StatusOK, counts)
	}
}

func (s *Server) havePersonal(w http.ResponseWriter) bool {
	if s.personal == nil {
		writeError(w, http.StatusServiceUnavailable, "personal data is not configured")
		return false
	}
	return true
}
