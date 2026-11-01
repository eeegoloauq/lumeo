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

// keepRules are a device's keep rules for a download it holds on a media
// server, in days; either left out keeps what the hold had.
type keepRules struct {
	KeepWatchedDays   *int `json:"keepWatchedDays,omitempty"`
	KeepUnwatchedDays *int `json:"keepUnwatchedDays,omitempty"`
}

const errKeepRules = "keepWatchedDays must be between 0 and 365, keepUnwatchedDays between 1 and 365"

func (k keepRules) valid() bool {
	within := func(days *int, low int) bool { return days == nil || *days >= low && *days <= 365 }
	return within(k.KeepWatchedDays, 0) && within(k.KeepUnwatchedDays, 1)
}

// holdBody is what a device says of a download it holds.
type holdBody struct {
	Watched           *bool    `json:"watched"`
	SubtitleLanguages []string `json:"subtitleLanguages"`
	keepRules
}

// handlePutHold records a device's hold on a download of this media server:
// whether its viewer watched the episode, which the keep policy needs to free
// the file, the subtitle languages to keep with it, and the device's keep
// rules. Each device says only its own.
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
	if !body.valid() {
		writeError(w, http.StatusBadRequest, errKeepRules)
		return
	}
	hold, err := s.downloads.Hold(r.Context(), r.PathValue("id"), deviceOf(r), acquire.HoldChange{
		Watched: body.Watched, SubtitleLanguages: body.SubtitleLanguages,
		KeepWatchedDays: body.KeepWatchedDays, KeepUnwatchedDays: body.KeepUnwatchedDays,
	})
	switch {
	case errors.Is(err, acquire.ErrNotFound):
		writeError(w, http.StatusNotFound, "unknown download")
		return
	case err != nil:
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// A watched mark or a shorter rule can end the last hold on a file.
	if s.library != nil {
		s.library.Kick()
	}
	writeJSON(w, http.StatusOK, hold)
}

// touchHold records a device of this media server starting or playing a
// download: it holds it from now on, and its unwatched clock starts again.
func (s *Server) touchHold(r *http.Request, id string, change acquire.HoldChange) (acquire.Hold, bool) {
	if s.viewerHere(r) || s.downloads == nil {
		return acquire.Hold{}, false
	}
	change.Active = true
	hold, err := s.downloads.Hold(r.Context(), id, deviceOf(r), change)
	if err != nil {
		// Its core holds it again on its next pass.
		s.log.Warn("recording a device's hold failed", "download", id, "err", err)
		return acquire.Hold{}, false
	}
	return hold, true
}

// releasedBy says whether the device behind r let go of d on this media
// server. Its lists leave d out, though another device still holds it:
// deleting a download is not having it come back on the next refresh.
// Playing it again holds it again.
func (s *Server) releasedBy(r *http.Request, d acquire.Download) bool {
	if s.viewerHere(r) {
		return false
	}
	device := deviceOf(r)
	i := slices.IndexFunc(d.Holds, func(h acquire.Hold) bool { return h.Device == device })
	return i >= 0 && !d.Holds[i].ReleasedAt.IsZero()
}

// releaseDownload lets a device of this media server go of a download, and
// frees the file at once when no other device's hold on it lasts.
func (s *Server) releaseDownload(ctx context.Context, id, device string) error {
	if err := s.downloads.Release(ctx, id, device); err != nil {
		return err
	}
	if s.library != nil {
		if _, err := s.library.Released(ctx, id); err != nil {
			// The release is kept; the next pass frees it.
			s.log.Warn("freeing a released download failed", "download", id, "err", err)
		}
	}
	return nil
}

const errOwnersDownload = "this download is the server owner's: a device deletes only what it holds"

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
