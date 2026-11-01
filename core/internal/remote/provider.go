package remote

import (
	"context"
	"errors"
	"net/http"
	"net/url"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
)

// ProviderID names the server among a catalogue's providers.
const ProviderID = "server"

// Provider is the server as this core's one metadata provider: its rows,
// pages, searches and details, the server's own providers behind them. The
// catalogue mints its own ids for what comes back, matched by IMDb id, so the
// shelves built from the progress kept here show the server's titles and
// artwork.
func (s *Server) Provider() catalog.Provider { return provider{s} }

type provider struct{ s *Server }

func (provider) ID() string        { return ProviderID }
func (provider) Name() string      { return "Server" }
func (provider) Namespace() string { return catalog.NamespaceIMDb }

// Relays every provider id: the server answers for those it has, and refuses
// the rest.
func (provider) Relays(string) bool { return true }

// Rows are the server's as it answers them, named by its own providers, so a
// client picks its shelves here as it would there. The catalogue keeps the
// last ones for while the server cannot be asked.
func (p provider) Rows(ctx context.Context) ([]catalog.Row, error) {
	var answer struct {
		Catalogs []catalog.Row `json:"catalogs"`
	}
	if err := p.s.Do(ctx, http.MethodGet, "/api/v1/catalogs", nil, nil, &answer); err != nil {
		return nil, err
	}
	return answer.Catalogs, nil
}

// Browse asks for one page of a row of the server's provider req names, its
// first for none or this one, or a search, which the server runs on every
// provider it has.
func (p provider) Browse(ctx context.Context, req catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	var answer struct {
		Items []catalog.MediaItem `json:"items"`
	}
	var err error
	if req.Search != "" {
		err = p.s.Do(ctx, http.MethodGet, "/api/v1/search", url.Values{"kind": {string(req.Kind)}, "q": {req.Search}}, nil, &answer)
	} else {
		providerID := req.ProviderID
		if providerID == ProviderID {
			providerID = ""
		}
		query := url.Values{"provider": {providerID}, "kind": {string(req.Kind)}, "id": {req.CatalogID}, "skip": {itoa(req.Skip)}}
		if req.Genre != "" {
			query.Set("genre", req.Genre)
		}
		err = p.s.Do(ctx, http.MethodGet, "/api/v1/catalog", query, nil, &answer)
	}
	if err != nil {
		return nil, err
	}
	for i := range answer.Items {
		p.s.RememberItem(answer.Items[i])
		answer.Items[i].ID = ""
	}
	return answer.Items, nil
}

// Meta is the server's details of a title.
func (p provider) Meta(ctx context.Context, kind catalog.Kind, imdb string) (*catalog.MediaItem, error) {
	item, err := p.s.Find(ctx, kind, imdb)
	if se, ok := errors.AsType[*StatusError](err); ok && se.Code == http.StatusNotFound {
		return nil, catalog.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	item.ID = ""
	return &item, nil
}
