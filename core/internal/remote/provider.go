package remote

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"strings"

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

// Rows are the server's, each named by the server's provider and its own id
// in one: requests for a row come back here, and the server needs both. The
// last rows read stand in while the server cannot be asked.
func (p provider) Rows(ctx context.Context) ([]catalog.Row, error) {
	var answer struct {
		Catalogs []catalog.Row `json:"catalogs"`
	}
	if err := p.s.Do(ctx, http.MethodGet, "/api/v1/catalogs", nil, nil, &answer); err != nil {
		p.s.rowsMu.Lock()
		defer p.s.rowsMu.Unlock()
		if p.s.rows != nil {
			return p.s.rows, nil
		}
		return nil, err
	}
	rows := make([]catalog.Row, 0, len(answer.Catalogs))
	for _, row := range answer.Catalogs {
		row.ID = url.PathEscape(row.ProviderID) + "/" + url.PathEscape(row.ID)
		row.ProviderID = ProviderID
		rows = append(rows, row)
	}
	p.s.rowsMu.Lock()
	p.s.rows = rows
	p.s.rowsMu.Unlock()
	return rows, nil
}

// Browse asks for one page of a row, or a search, which the server runs on
// every provider it has.
func (p provider) Browse(ctx context.Context, req catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	var answer struct {
		Items []catalog.MediaItem `json:"items"`
	}
	var err error
	if req.Search != "" {
		err = p.s.Do(ctx, http.MethodGet, "/api/v1/search", url.Values{"kind": {string(req.Kind)}, "q": {req.Search}}, nil, &answer)
	} else {
		providerID, catalogID, ok := strings.Cut(req.CatalogID, "/")
		if providerID, err = url.PathUnescape(providerID); err != nil || !ok {
			return nil, errors.New("remote: not a row of the server")
		}
		if catalogID, err = url.PathUnescape(catalogID); err != nil {
			return nil, errors.New("remote: not a row of the server")
		}
		query := url.Values{"provider": {providerID}, "kind": {string(req.Kind)}, "id": {catalogID}, "skip": {itoa(req.Skip)}}
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
