package api

import (
	"cmp"
	"crypto/rand"
	"crypto/subtle"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/eeegoloauq/lumeo/core/internal/store"
)

// Only the local administrator can open pairing. A long random code avoids a
// guessable public PIN and needs no IP-based limits behind a reverse proxy.
func (s *Server) handlePairing(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdministrator(w, r) {
		return
	}
	if s.devices == nil {
		writeError(w, http.StatusServiceUnavailable, "devices unavailable")
		return
	}
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	s.pairCode = rand.Text()
	s.pairUntil = time.Now().Add(10 * time.Minute)
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"code": s.pairCode, "expiresAt": s.pairUntil})
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	var body struct {
		Code string `json:"code"`
		Name string `json:"name"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	body.Name = strings.TrimSpace(body.Name)
	if body.Name == "" || len(body.Name) > 128 || strings.IndexFunc(body.Name, unicode.IsControl) >= 0 {
		writeError(w, http.StatusBadRequest, "device name must be 1 to 128 bytes without control characters")
		return
	}
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	if s.devices == nil || s.pairCode == "" || !time.Now().Before(s.pairUntil) || subtle.ConstantTimeCompare([]byte(body.Code), []byte(s.pairCode)) != 1 {
		writeError(w, http.StatusUnauthorized, "invalid or expired pairing code")
		return
	}
	credential := rand.Text()
	device := store.Device{ID: rand.Text(), Name: body.Name, CreatedAt: time.Now().UTC()}
	if err := s.devices.AddDevice(r.Context(), device, credential); err != nil {
		s.log.Error("pair device", "err", err)
		writeError(w, http.StatusInternalServerError, "cannot save device")
		return
	}
	s.pairCode = ""
	// The mode, so a core about to forward here, or a client, knows where the
	// viewer's data will live (mode.go).
	writeJSON(w, http.StatusCreated, map[string]any{"device": device, "token": credential, "mode": cmp.Or(s.mode, "full")})
}

func (s *Server) requireAdministrator(w http.ResponseWriter, r *http.Request) bool {
	if s.token != "" && subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.token)) == 1 {
		return true
	}
	writeError(w, http.StatusForbidden, "administrator token required")
	return false
}

func (s *Server) handleDevices(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdministrator(w, r) {
		return
	}
	if s.devices == nil {
		writeError(w, http.StatusServiceUnavailable, "devices unavailable")
		return
	}
	devices, err := s.devices.Devices(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "cannot list devices")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, http.StatusOK, map[string]any{"devices": devices})
}

func (s *Server) handleRevokeDevice(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdministrator(w, r) {
		return
	}
	if s.devices == nil {
		writeError(w, http.StatusServiceUnavailable, "devices unavailable")
		return
	}
	// Its holds go first: a hold left behind would keep its files forever.
	if s.downloads != nil {
		if err := s.downloads.ReleaseDevice(r.Context(), r.PathValue("id")); err != nil {
			s.log.Error("release a revoked device's holds", "err", err)
			writeError(w, http.StatusInternalServerError, "cannot release the device's downloads")
			return
		}
	}
	found, err := s.devices.RevokeDevice(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "cannot revoke device")
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, "unknown device")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
