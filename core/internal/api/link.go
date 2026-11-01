package api

import (
	"errors"
	"net/http"
	"strings"

	"github.com/eeegoloauq/lumeo/core/internal/remote"
)

// The link to a media server is set by the owner of this core: the client
// pairs with the server, and a media server's answer makes it hand the
// device credential here instead of keeping it. The link is read at start
// (remote.go relies on it not changing under a running core), so a change
// takes effect on the next one; the app restarts with its core.

// linkView is what this core says of its links: the server it forwards to
// from its next start, the one it forwards to now, and every server it holds
// a credential for, which it can be switched to without pairing again.
type linkView struct {
	URL     string `json:"url"`
	Running string `json:"running"`
	// Certificate is the running server's pinned one, which the client pins
	// for that origin too.
	Certificate string   `json:"certificate,omitempty"`
	Saved       []string `json:"saved"`
}

func (s *Server) currentLink(w http.ResponseWriter) {
	saved, use, err := remote.Saved(s.dataDir)
	if err != nil {
		s.log.Error("read the links", "err", err)
		writeError(w, http.StatusInternalServerError, "cannot read the links")
		return
	}
	// An empty list rather than null, for a client reading it as one.
	view := linkView{URL: use, Saved: append([]string{}, saved...)}
	if s.remote != nil {
		view.Running = s.remote.URL()
		view.Certificate = s.remote.Certificate()
	}
	writeJSON(w, http.StatusOK, view)
}

// haveDataDir answers the request itself when there is nowhere to keep a link.
func (s *Server) haveDataDir(w http.ResponseWriter) bool {
	if s.dataDir == "" {
		writeError(w, http.StatusServiceUnavailable, "link unavailable")
		return false
	}
	return true
}

func (s *Server) handleLink(w http.ResponseWriter, r *http.Request) {
	if s.requireAdministrator(w, r) && s.haveDataDir(w) {
		s.currentLink(w)
	}
}

// handlePutLink keeps a device credential for a media server, once the server
// has taken it and said it is a media server: a full one keeps its devices'
// data, and the client talks to it directly instead.
func (s *Server) handlePutLink(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdministrator(w, r) || !s.haveDataDir(w) {
		return
	}
	if s.mediaServer() {
		writeError(w, http.StatusConflict, remote.ErrIsMediaServer.Error())
		return
	}
	// Certificate is the one the client pinned when it paired, if any.
	var body struct {
		URL         string `json:"url"`
		Token       string `json:"token"`
		Certificate string `json:"certificate"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	link := remote.Link{URL: strings.TrimRight(body.URL, "/"), Token: body.Token, Certificate: body.Certificate}
	if err := link.Validate(); err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := remote.Verify(r.Context(), link); err != nil {
		se, isStatus := errors.AsType[*remote.StatusError](err)
		switch {
		case r.Context().Err() != nil:
			return
		case errors.Is(err, remote.ErrNotMedia):
			writeError(w, http.StatusConflict, err.Error())
		case remote.Unauthorized(err):
			writeError(w, http.StatusUnprocessableEntity, remote.RefusedMessage)
		case isStatus:
			writeError(w, http.StatusBadGateway, "the server answered "+http.StatusText(se.Code))
		default:
			s.log.Warn("checking a link failed", "url", link.URL, "err", err)
			writeError(w, http.StatusBadGateway, remote.ErrUnreachable.Error())
		}
		return
	}
	if err := remote.Save(s.dataDir, link); err != nil {
		s.log.Error("save the link", "err", err)
		writeError(w, http.StatusInternalServerError, "cannot save the link")
		return
	}
	s.log.Info("linked to a media server; it is used from the next start", "url", link.URL)
	s.currentLink(w)
}

// handleUseLink makes a saved link the one used from the next start, or none
// for an empty url. Every link stays saved.
func (s *Server) handleUseLink(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdministrator(w, r) || !s.haveDataDir(w) {
		return
	}
	var body struct {
		URL string `json:"url"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	switch err := remote.Use(s.dataDir, body.URL); {
	case errors.Is(err, remote.ErrNotSaved):
		writeError(w, http.StatusNotFound, err.Error())
		return
	case err != nil:
		s.log.Error("switch the link", "err", err)
		writeError(w, http.StatusInternalServerError, "cannot switch the link")
		return
	}
	s.currentLink(w)
}

// handleUnlink forgets the link to ?url=, by default the one in use. The
// server keeps the device until its owner revokes it.
func (s *Server) handleUnlink(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdministrator(w, r) || !s.haveDataDir(w) {
		return
	}
	url := r.URL.Query().Get("url")
	if url == "" {
		in, _, err := remote.Load(s.dataDir)
		if err != nil {
			s.log.Error("read the links", "err", err)
			writeError(w, http.StatusInternalServerError, "cannot read the links")
			return
		}
		url = in.URL
	}
	if err := remote.Forget(s.dataDir, url); err != nil {
		s.log.Error("forget the link", "err", err)
		writeError(w, http.StatusInternalServerError, "cannot forget the link")
		return
	}
	s.currentLink(w)
}
