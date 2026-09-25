package api

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/watchlist"
)

func (s *Server) handlePutProgress(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	var body struct {
		Season   int     `json:"season"`
		Episode  int     `json:"episode"`
		Position float64 `json:"position"`
		Duration float64 `json:"duration"`
		Watched  *bool   `json:"watched"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	id := r.PathValue("id")
	before, _, err := s.progress.Get(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	entry, err := s.progress.Put(r.Context(), id, progress.Update{
		Season: body.Season, Episode: body.Episode, Position: body.Position, Duration: body.Duration, Watched: body.Watched,
	})
	if errors.Is(err, progress.ErrInvalid) {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if s.library != nil && entry.Watched && entry.Position == 0 {
		s.library.Kick()
	}
	// What someone starts watching belongs in their list. Only the first time:
	// a title taken out of the list stays out while it is being finished.
	if len(before) == 0 && s.watchlist != nil {
		if _, err := s.watchlist.Add(r.Context(), id); err != nil && !errors.Is(err, watchlist.ErrUnknown) {
			s.log.Warn("adding to the list failed", "item", id, "err", err)
		}
	}
	writeJSON(w, http.StatusOK, entry)
}

func (s *Server) handleChoice(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	choice, err := s.progress.Choice(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, choice)
}

// handlePatchChoice records the tracks a player saw picked by hand. The source
// is not patched here: it is recorded by the download that starts it.
func (s *Server) handlePatchChoice(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	var body struct {
		Audio    *progress.Track `json:"audio"`
		Subtitle *progress.Track `json:"subtitle"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	choice, err := s.progress.RememberTracks(r.Context(), r.PathValue("id"), body.Audio, body.Subtitle)
	if errors.Is(err, progress.ErrInvalid) {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, choice)
}

func (s *Server) handleProgress(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	entries, next, err := s.progress.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "next": next})
}

func (s *Server) handleDeleteProgress(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	query := r.URL.Query()
	seasonText, haveSeason := query["season"]
	episodeText, haveEpisode := query["episode"]
	if haveSeason != haveEpisode {
		writeError(w, http.StatusBadRequest, "season and episode must be provided together")
		return
	}
	var season, episode *int
	if haveSeason {
		s, errS := strconv.Atoi(seasonText[0])
		e, errE := strconv.Atoi(episodeText[0])
		if errS != nil || errE != nil || s < 0 || e < 0 {
			writeError(w, http.StatusBadRequest, "season and episode must be non-negative integers")
			return
		}
		season, episode = &s, &e
	}
	if err := s.progress.Delete(r.Context(), r.PathValue("id"), season, episode); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleContinue(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	limit := 30
	if value := r.URL.Query().Get("limit"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 1 || parsed > 100 {
			writeError(w, http.StatusBadRequest, "limit must be between 1 and 100")
			return
		}
		limit = parsed
	}
	items, err := s.progress.Continue(r.Context(), limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	urls := make(map[string]string)
	for i := range items {
		s.rewriteItem(r, &items[i].Item, urls)
	}
	if err := s.registerArtwork(r, urls); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, items)
}
