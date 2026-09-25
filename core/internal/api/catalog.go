package api

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
)

// handleCatalogs lists the rows a home screen can be built from.
func (s *Server) handleCatalogs(w http.ResponseWriter, r *http.Request) {
	if !s.haveCatalog(w) {
		return
	}
	rows := s.catalog.Rows(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{"catalogs": rows})
}

func (s *Server) handleCatalog(w http.ResponseWriter, r *http.Request) {
	if !s.haveCatalog(w) {
		return
	}
	q := r.URL.Query()
	req := catalog.BrowseRequest{
		ProviderID: q.Get("provider"),
		Kind:       kindOr(q.Get("kind"), catalog.KindMovie),
		CatalogID:  q.Get("id"),
		Genre:      q.Get("genre"),
	}
	req.Skip, _ = strconv.Atoi(q.Get("skip"))
	if req.CatalogID == "" {
		writeError(w, http.StatusBadRequest, "id parameter is required")
		return
	}
	items, err := s.catalog.Browse(r.Context(), req)
	if errors.Is(err, catalog.ErrNoProviders) {
		writeError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	if err != nil {
		s.log.Warn("browse failed", "catalog", req.CatalogID, "err", err)
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := s.rewriteItems(r, items); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	if !s.haveCatalog(w) {
		return
	}
	query := r.URL.Query().Get("q")
	if query == "" {
		writeError(w, http.StatusBadRequest, "q parameter is required")
		return
	}
	items, err := s.catalog.Search(r.Context(), kindOr(r.URL.Query().Get("kind"), catalog.KindMovie), query)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}
	if err := s.rewriteItems(r, items); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// handleItem is the item page: everything the client needs before it asks for
// sources, episodes included.
func (s *Server) handleItem(w http.ResponseWriter, r *http.Request) {
	if !s.haveCatalog(w) {
		return
	}
	item, err := s.catalog.Item(r.Context(), r.PathValue("id"))
	if err != nil {
		s.writeItemError(w, err)
		return
	}
	items := []catalog.MediaItem{item}
	if err := s.rewriteItems(r, items); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, items[0])
}

// handleEpisodeAfter answers what follows the episode the caller names.
//
// Deliberately not the progress answer: that one is "what to open when Play is
// pressed", counted from the most recent thing reported, and an episode latches
// as watched at 90% — so a player that asks it in the middle of the credits is
// told about the episode after the one it is about to move to. It is also free
// of the question of which device reported last. Here the caller says which
// episode it means, and the answer is about that episode.
func (s *Server) handleEpisodeAfter(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) || !s.haveCatalog(w) {
		return
	}
	query := r.URL.Query()
	season, seasonErr := strconv.Atoi(query.Get("season"))
	episode, episodeErr := strconv.Atoi(query.Get("episode"))
	if seasonErr != nil || episodeErr != nil || season < 0 || episode < 0 {
		writeError(w, http.StatusBadRequest, "season and episode must be non-negative integers")
		return
	}
	next, err := s.progress.After(r.Context(), r.PathValue("id"), season, episode)
	if err != nil {
		s.writeItemError(w, err)
		return
	}
	if next != nil {
		urls := make(map[string]string)
		s.rewriteEpisode(r, next, urls)
		if err := s.registerArtwork(r, urls); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	// A null next, as the progress route already answers with: "that was the
	// last one" is an answer about a catalogue that was read, and it has to be
	// told apart from one that could not be read — which is the error above.
	writeJSON(w, http.StatusOK, map[string]any{"next": next})
}

func kindOr(v string, def catalog.Kind) catalog.Kind {
	switch catalog.Kind(v) {
	case catalog.KindMovie, catalog.KindSeries:
		return catalog.Kind(v)
	default:
		return def
	}
}
