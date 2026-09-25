package api

import (
	"context"
	"errors"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

// handleSubtitles answers with the tracks for one file, ranked. The download
// is optional and is what makes the answer about a file rather than about a
// title: from it come the size, the name and the hash a subtitle database
// matches an encode by.
func (s *Server) handleSubtitles(w http.ResponseWriter, r *http.Request) {
	if s.subtitles == nil {
		writeError(w, http.StatusServiceUnavailable, "no subtitle provider configured")
		return
	}
	params := r.URL.Query()
	q := subtitles.Query{
		Kind:      kindOr(params.Get("kind"), catalog.KindMovie),
		IMDbID:    params.Get("imdb"),
		Languages: splitLanguages(params.Get("lang")),
	}
	q.Season, _ = strconv.Atoi(params.Get("season"))
	q.Episode, _ = strconv.Atoi(params.Get("episode"))
	if params.Get("lang") == "" && s.prefs != nil {
		prefs, err := s.prefs.Get(r.Context())
		if err != nil {
			s.log.Warn("reading subtitle language preferences failed", "err", err)
		} else {
			q.Languages = prefs.SubtitleLanguages
		}
	}

	if itemID := params.Get("item"); itemID != "" {
		imdbID, kind, ok := s.resolveItem(w, r, itemID)
		if !ok {
			return
		}
		q.IMDbID, q.Kind = imdbID, kind
	}
	if q.IMDbID == "" {
		writeError(w, http.StatusBadRequest, "item or imdb parameter is required")
		return
	}
	if id := params.Get("download"); id != "" && s.downloads != nil {
		s.describePlaying(r, id, &q)
	}
	writeJSON(w, http.StatusOK, map[string]any{"subtitles": s.subtitles.Find(r.Context(), q)})
}

// handleSubtitleFile serves the track itself, converted to UTF-8. The token
// in the path is one the core minted for a file a provider returned; nothing
// else can be asked for, which is what keeps this from being a proxy into
// whatever the core can reach.
func (s *Server) handleSubtitleFile(w http.ResponseWriter, r *http.Request) {
	if s.subtitles == nil {
		writeError(w, http.StatusServiceUnavailable, "no subtitle provider configured")
		return
	}
	// The extension is there for the player, which decides what it is parsing
	// from the name long before it looks at a Content-Type.
	token, _, _ := strings.Cut(r.PathValue("token"), ".")
	text, err := s.subtitles.Fetch(r.Context(), token)
	switch {
	case errors.Is(err, subtitles.ErrUnknownToken):
		writeError(w, http.StatusNotFound, "unknown subtitle")
		return
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return // the player gave up
	case err != nil:
		s.log.Warn("subtitle fetch failed", "err", err)
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	w.Header().Set("Content-Type", subtitleContentType(text.Format))
	// A subtitle file never changes, and a player that reloads the track on
	// every seek should not refetch it from the other side of the world.
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("Content-Length", strconv.Itoa(len(text.Body)))
	_, _ = w.Write(text.Body)
}

// hashWait bounds how long a subtitle lookup will wait for the tail of a file
// that is still arriving. Past it the lookup goes ahead on the title alone:
// approximate subtitles now beat exact subtitles after the scene has passed.
const hashWait = 10 * time.Second

// describePlaying fills the query with the copy being watched. Everything it
// adds is optional: a download that has not learned its file yet, or a swarm
// too slow to hand over the last piece, costs precision and not the lookup.
func (s *Server) describePlaying(r *http.Request, id string, q *subtitles.Query) {
	d, err := s.downloads.Get(r.Context(), id)
	if err != nil {
		return
	}
	if d.Name != "" {
		q.ReleaseName, q.Release = d.Name, release.Parse(d.Name)
	}
	if q.Season == 0 && q.Episode == 0 {
		q.Season, q.Episode = d.Season, d.Episode
	}
	file, err := s.downloads.File(r.Context(), id, 0)
	if err != nil {
		return
	}
	q.Filename = filepath.Base(file.Path())
	q.VideoSize = file.Size()
	q.VideoHash = s.videoHash(r.Context(), id, file)
}

func (s *Server) videoHash(ctx context.Context, id string, file acquire.File) string {
	s.hashMu.Lock()
	cached, ok := s.hashes[id]
	s.hashMu.Unlock()
	if ok {
		return cached
	}

	ctx, cancel := context.WithTimeout(ctx, hashWait)
	defer cancel()
	reader, err := file.Open(ctx)
	if err != nil {
		return ""
	}
	defer reader.Close()
	hash, err := subtitles.Hash(reader, file.Size())
	if err != nil {
		// Nothing to report: a swarm that has not sent the last piece yet is
		// the normal case at the start of a film.
		s.log.Debug("video hash unavailable", "download", id, "err", err)
		return ""
	}
	s.hashMu.Lock()
	s.hashes[id] = hash
	s.hashMu.Unlock()
	return hash
}

// splitLanguages reads the "lang" parameter: preferred languages, best first.
func splitLanguages(spec string) []string {
	var out []string
	for _, code := range strings.Split(spec, ",") {
		if code = strings.TrimSpace(code); code != "" {
			out = append(out, subtitles.Language(code))
		}
	}
	return out
}

func subtitleContentType(format string) string {
	switch format {
	case "vtt":
		return "text/vtt; charset=utf-8"
	case "ass", "ssa":
		return "text/x-ssa; charset=utf-8"
	default:
		return "application/x-subrip; charset=utf-8"
	}
}
