package api

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
	"github.com/eeegoloauq/lumeo/core/internal/watchlist"
)

// The library: My list, the viewer's ratings and the history of what was
// watched. All three are the viewer's, kept by the core so that every client
// shows the same library.

func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	if !s.haveWatchlist(w) {
		return
	}
	listed, err := s.watchlist.List(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	urls := make(map[string]string)
	for i := range listed {
		s.rewriteItem(r, &listed[i].Item, urls)
	}
	if err := s.registerArtwork(r, urls); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": listed})
}

// listState is whether one title is on the list, which is what its page
// needs to draw the button.
type listState struct {
	InList bool `json:"inList"`
	*watchlist.Entry
}

func (s *Server) handleListEntry(w http.ResponseWriter, r *http.Request) {
	if !s.haveWatchlist(w) {
		return
	}
	entry, ok, err := s.watchlist.Has(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	state := listState{InList: ok}
	if ok {
		state.Entry = &entry
	}
	writeJSON(w, http.StatusOK, state)
}

func (s *Server) handleAddToList(w http.ResponseWriter, r *http.Request) {
	if !s.haveWatchlist(w) {
		return
	}
	entry, err := s.watchlist.Add(r.Context(), r.PathValue("id"))
	if errors.Is(err, watchlist.ErrUnknown) {
		writeError(w, http.StatusNotFound, "unknown item")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, listState{InList: true, Entry: &entry})
}

func (s *Server) handleRemoveFromList(w http.ResponseWriter, r *http.Request) {
	if !s.haveWatchlist(w) {
		return
	}
	if err := s.watchlist.Remove(r.Context(), r.PathValue("id")); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleNewEpisodes(w http.ResponseWriter, r *http.Request) {
	if !s.haveWatchlist(w) {
		return
	}
	found, err := s.watchlist.NewEpisodes(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	urls := make(map[string]string)
	for i := range found {
		s.rewriteItem(r, &found[i].Item, urls)
		s.rewriteEpisode(r, &found[i].Episode, urls)
	}
	if err := s.registerArtwork(r, urls); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": found})
}

func (s *Server) handleRatings(w http.ResponseWriter, r *http.Request) {
	if !s.haveRatings(w) {
		return
	}
	list, err := s.ratings.Of(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ratings": list})
}

func (s *Server) handleRate(w http.ResponseWriter, r *http.Request) {
	if !s.haveRatings(w) {
		return
	}
	var body struct {
		Season  int `json:"season"`
		Episode int `json:"episode"`
		Rating  int `json:"rating"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	rating, err := s.ratings.Set(r.Context(), r.PathValue("id"), body.Season, body.Episode, body.Rating)
	switch {
	case errors.Is(err, ratings.ErrInvalid):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, ratings.ErrUnknown):
		writeError(w, http.StatusNotFound, "unknown item")
	case err != nil:
		writeError(w, http.StatusInternalServerError, err.Error())
	default:
		writeJSON(w, http.StatusOK, rating)
	}
}

// handleUnrate clears the score of an episode named by season and episode,
// or of the title itself when neither is given.
func (s *Server) handleUnrate(w http.ResponseWriter, r *http.Request) {
	if !s.haveRatings(w) {
		return
	}
	query := r.URL.Query()
	seasonText, haveSeason := query["season"]
	episodeText, haveEpisode := query["episode"]
	if haveSeason != haveEpisode {
		writeError(w, http.StatusBadRequest, "season and episode must be provided together")
		return
	}
	var season, episode int
	if haveSeason {
		var errS, errE error
		season, errS = strconv.Atoi(seasonText[0])
		episode, errE = strconv.Atoi(episodeText[0])
		if errS != nil || errE != nil {
			writeError(w, http.StatusBadRequest, "season and episode must be non-negative integers")
			return
		}
	}
	err := s.ratings.Clear(r.Context(), r.PathValue("id"), season, episode)
	if errors.Is(err, ratings.ErrInvalid) {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// historyEntry is a viewing with the score given to what was watched.
type historyEntry struct {
	progress.Viewing
	Rating int `json:"rating,omitempty"`
}

func (s *Server) handleHistory(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	limit, offset := 50, 0
	query := r.URL.Query()
	if value := query.Get("limit"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 1 || parsed > 200 {
			writeError(w, http.StatusBadRequest, "limit must be between 1 and 200")
			return
		}
		limit = parsed
	}
	if value := query.Get("offset"); value != "" {
		parsed, err := strconv.Atoi(value)
		if err != nil || parsed < 0 {
			writeError(w, http.StatusBadRequest, "offset must be a non-negative integer")
			return
		}
		offset = parsed
	}
	viewings, more, err := s.progress.History(r.Context(), limit, offset)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	scores := map[string][]ratings.Rating{}
	if s.ratings != nil {
		ids := make([]string, 0, len(viewings))
		for _, v := range viewings {
			ids = append(ids, v.Item.ID)
		}
		if scores, err = s.ratings.For(r.Context(), ids); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	entries := make([]historyEntry, len(viewings))
	urls := make(map[string]string)
	for i, v := range viewings {
		s.rewriteItem(r, &v.Item, urls)
		if v.Episode != nil {
			episode := *v.Episode
			s.rewriteEpisode(r, &episode, urls)
			v.Episode = &episode
		}
		entries[i] = historyEntry{Viewing: v, Rating: ratings.Score(scores[v.Item.ID], v.Entry.Season, v.Entry.Episode)}
	}
	if err := s.registerArtwork(r, urls); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": entries, "more": more})
}

func (s *Server) haveWatchlist(w http.ResponseWriter) bool {
	if s.watchlist == nil {
		writeError(w, http.StatusServiceUnavailable, "the list is not configured")
		return false
	}
	return true
}

func (s *Server) haveRatings(w http.ResponseWriter) bool {
	if s.ratings == nil {
		writeError(w, http.StatusServiceUnavailable, "ratings are not configured")
		return false
	}
	return true
}
