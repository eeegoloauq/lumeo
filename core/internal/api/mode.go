package api

import (
	"context"
	"errors"
	"net/http"
	"regexp"
	"slices"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

// A core's mode says where the personal data of the devices paired with it
// lives. A full core keeps it. A media core holds the files, and each device
// keeps its viewer's data on a core of its own, which forwards here what this
// one owns (remote.go). The owner's token, readable only on this machine,
// stays a full core's viewer in either mode.

type deviceKey struct{}

// deviceOf is the paired device a request came from, "" for the owner's
// token.
func deviceOf(r *http.Request) string {
	id, _ := r.Context().Value(deviceKey{}).(string)
	return id
}

// mediaServer says whether this core leaves its devices' personal data on
// them.
func (s *Server) mediaServer() bool { return s.mode == remote.ModeMedia }

// viewerHere says whether the viewer behind a request keeps their data on this
// core: anyone but a device of a media server.
func (s *Server) viewerHere(r *http.Request) bool {
	return !s.mediaServer() || deviceOf(r) == ""
}

// viewerData guards a route of the viewer's own data: a media server keeps none
// of its devices', and says so rather than keeping some.
func (s *Server) viewerData(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.viewerHere(r) {
			writeError(w, http.StatusForbidden, "this is a media server: personal data stays on each device")
			return
		}
		next(w, r)
	}
}

// stampMode puts this core's mode on every answer, so a core forwarding to it
// notices the moment it stops being a media server.
func (s *Server) stampMode(next http.Handler) http.Handler {
	mode := s.mode
	if mode == "" {
		mode = "full"
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set(remote.ModeHeader, mode)
		next.ServeHTTP(w, r)
	})
}

// holdBody is what a device says of a download it holds.
type holdBody struct {
	Watched           *bool    `json:"watched"`
	SubtitleLanguages []string `json:"subtitleLanguages"`
}

// handlePutHold records a device's hold on a download of this media server:
// whether its viewer watched the episode, which the keep policy needs to free
// the file, and the subtitle languages to keep with it. Each device says only
// its own.
func (s *Server) handlePutHold(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	if s.viewerHere(r) {
		writeError(w, http.StatusForbidden, "only a device of a media server holds downloads; this core keeps its viewer's progress")
		return
	}
	var body holdBody
	if !readJSON(w, r, &body) {
		return
	}
	if body.Watched == nil || body.SubtitleLanguages == nil {
		writeError(w, http.StatusBadRequest, `request body must be {"watched": true|false, "subtitleLanguages": [...]}`)
		return
	}
	if !validLanguages(body.SubtitleLanguages) {
		writeError(w, http.StatusBadRequest, errLanguages)
		return
	}
	hold, err := s.downloads.SetHold(r.Context(), r.PathValue("id"), deviceOf(r), *body.Watched, body.SubtitleLanguages)
	switch {
	case errors.Is(err, acquire.ErrNotFound):
		writeError(w, http.StatusNotFound, "unknown download")
		return
	case err != nil:
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if *body.Watched && s.library != nil {
		s.library.Kick()
	}
	writeJSON(w, http.StatusOK, hold)
}

// heldDownload is a download as a device sees it: with its own hold, which its core
// compares with what it knows.
type heldDownload struct {
	acquire.Download
	Hold *acquire.Hold `json:"hold,omitempty"`
}

func (s *Server) asSeenBy(r *http.Request, d acquire.Download) heldDownload {
	out := heldDownload{Download: d}
	if device := deviceOf(r); device != "" {
		if i := slices.IndexFunc(d.Holds, func(h acquire.Hold) bool { return h.Device == device }); i >= 0 {
			out.Hold = &d.Holds[i]
		}
	}
	return out
}

const errLanguages = "subtitleLanguages must be at most 16 language tags"

var languageTag = regexp.MustCompile(`^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$`)

func validLanguages(tags []string) bool {
	if len(tags) > 16 {
		return false
	}
	for _, tag := range tags {
		if len(tag) > 35 || !languageTag.MatchString(tag) {
			return false
		}
	}
	return true
}

// SubtitleLanguages is what a viewer wants kept with the downloads of a
// title, best first: the language of the subtitles they picked for it, then
// their preferences'. A core keeps them with its own downloads, and sends
// them to a media server for the downloads there.
func SubtitleLanguages(ctx context.Context, watch *progress.Service, prefs *preferences.Service, itemID string) []string {
	var langs []string
	add := func(lang string) {
		if lang != "" && !slices.Contains(langs, lang) {
			langs = append(langs, lang)
		}
	}
	if watch != nil {
		if c, err := watch.Choice(ctx, itemID); err == nil && c.Subtitle != nil {
			add(subtitles.Language(c.Subtitle.Language))
		}
	}
	if prefs != nil {
		if p, err := prefs.Get(ctx); err == nil {
			for _, lang := range p.SubtitleLanguages {
				add(lang)
			}
		}
	}
	return langs
}
