package catalog

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/flight"
)

// ErrNotFound means the id is not one we ever minted.
var ErrNotFound = errors.New("catalog: item not found")

// ErrNoProviders means no enabled addon serves a catalog.
var ErrNoProviders = errors.New("catalog: no metadata providers configured")

// How long cached data is served without asking the provider again. Cinemeta
// is a free service with no SLA, so the numbers lean towards not bothering it:
// a home screen that is six hours stale is fine. Past the TTL the cached copy
// is still what a request gets; the provider is asked in the background.
const (
	DefaultPageTTL = 6 * time.Hour
	DefaultMetaTTL = 24 * time.Hour
)

// Service is the catalog as the rest of the core sees it: providers behind a
// cache, and provider ids translated into ours on the way in.
//
// The providers are asked for on every call rather than kept: the list is
// edited on a settings page while the core runs, and the first one is the
// one a home screen is built from.
//
// Provider requests run on the service's own context, not the caller's: a
// page closed before Cinemeta answered still wants the answer cached, and a
// request that is already out is joined rather than sent again — opening a
// title asks for it three times at once (the page, its progress, its sources).
type Service struct {
	providers func() []Provider
	store     Store
	log       *slog.Logger

	PageTTL time.Duration
	MetaTTL time.Duration
	now     func() time.Time

	items *flight.Group[MediaItem]
	pages *flight.Group[[]MediaItem]

	// background holds a slot for each refresh [Cached] started, so that a
	// long list is refreshed a few titles at a time.
	background chan struct{}
}

func NewService(providers func() []Provider, store Store, log *slog.Logger) *Service {
	return &Service{
		providers: providers,
		store:     store,
		log:       log,
		PageTTL:   DefaultPageTTL,
		MetaTTL:   DefaultMetaTTL,
		now:       time.Now,
		items:     flight.New[MediaItem](),
		pages:     flight.New[[]MediaItem](),

		background: make(chan struct{}, 4),
	}
}

// Close cancels the provider requests in flight and waits for them, so none
// writes to the store after it is closed.
func (s *Service) Close() {
	s.items.Close()
	s.pages.Close()
}

// Fixed is a provider list that never changes, for a core that was handed
// one at startup and for tests.
func Fixed(providers ...Provider) func() []Provider {
	return func() []Provider { return providers }
}

// Rows lists every catalog on offer. One dead provider must not empty a home
// screen, so failures are logged and the rest is returned.
func (s *Service) Rows(ctx context.Context) []Row {
	var out []Row
	for _, p := range s.providers() {
		rows, err := p.Rows(ctx)
		if err != nil {
			s.log.Warn("catalog rows failed", "provider", p.ID(), "err", err)
			continue
		}
		out = append(out, rows...)
	}
	return out
}

// Browse returns one page of one row. A cached page is served as it is: when
// it is past the TTL the provider is asked again in the background, and the
// next request gets the new page. Only a page never fetched, or fetched by
// another core version, waits for the provider — and falls back to what the
// cache has when the provider fails.
func (s *Service) Browse(ctx context.Context, req BrowseRequest) ([]MediaItem, error) {
	p, err := s.provider(req.ProviderID)
	if err != nil {
		return nil, err
	}
	req.ProviderID = p.ID()
	key := pageKey(req)

	cached, fetchedAt, err := s.store.Page(ctx, key)
	if err != nil {
		// A broken cache degrades to a slow catalog, never to a broken one.
		s.log.Warn("page cache read failed", "key", key, "err", err)
	}
	var stale []MediaItem
	if len(cached) > 0 {
		if stale, err = s.store.ItemsByIDs(ctx, cached); err != nil {
			s.log.Warn("page cache read failed", "key", key, "err", err)
			stale = nil
		}
	}
	if len(stale) > 0 && s.fresh(fetchedAt, s.PageTTL) {
		return stale, nil
	}

	call := s.pages.Go(key, func(ctx context.Context) ([]MediaItem, error) {
		return s.fetchPage(ctx, p, req, key)
	})
	if len(stale) > 0 && !fetchedAt.IsZero() {
		return stale, nil
	}
	items, err := call.Wait(ctx)
	if err != nil {
		if ctx.Err() == nil && len(stale) > 0 {
			s.log.Warn("browse failed, serving stale page", "provider", p.ID(), "err", err)
			return stale, nil
		}
		return nil, err
	}
	return items, nil
}

func (s *Service) fetchPage(ctx context.Context, p Provider, req BrowseRequest, key string) ([]MediaItem, error) {
	items, err := p.Browse(ctx, req)
	if err != nil {
		s.log.Warn("browse failed", "provider", p.ID(), "key", key, "err", err)
		return nil, fmt.Errorf("browse %s: %w", p.ID(), err)
	}
	saved, err := s.store.UpsertItems(ctx, p.Namespace(), items, false)
	if err != nil {
		return nil, fmt.Errorf("cache items: %w", err)
	}
	saved = identified(saved)
	if err := s.store.SavePage(ctx, key, idsOf(saved)); err != nil {
		s.log.Warn("page cache write failed", "key", key, "err", err)
	}
	return saved, nil
}

// Search asks every provider's first searchable row of that kind.
func (s *Service) Search(ctx context.Context, kind Kind, query string) ([]MediaItem, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, errors.New("catalog: empty search query")
	}
	var out []MediaItem
	seen := make(map[string]bool)
	for _, p := range s.providers() {
		rows, err := p.Rows(ctx)
		if err != nil {
			s.log.Warn("catalog rows failed", "provider", p.ID(), "err", err)
			continue
		}
		for _, r := range rows {
			if r.Kind != kind || !r.Searchable {
				continue
			}
			items, err := s.Browse(ctx, BrowseRequest{
				ProviderID: p.ID(),
				Kind:       kind,
				CatalogID:  r.ID,
				Search:     query,
			})
			if err != nil {
				s.log.Warn("search failed", "provider", p.ID(), "catalog", r.ID, "err", err)
			}
			for _, it := range items {
				if seen[it.ID] {
					continue
				}
				seen[it.ID] = true
				out = append(out, it)
			}
			break // one searchable row per provider is enough
		}
	}
	return out, nil
}

// Item returns the full item behind one of our ids, fetching the details the
// catalog row did not carry (episodes, cast, artwork) when they are missing or
// stale. Details already fetched are served at once and refreshed in the
// background once past the TTL; only a title never opened, or opened under
// another core version, waits for the provider. A provider that is down costs
// freshness, not the page.
func (s *Service) Item(ctx context.Context, id string) (MediaItem, error) {
	item, state, err := s.store.Item(ctx, id)
	if err != nil {
		return MediaItem{}, err
	}
	if !state.Found {
		return MediaItem{}, ErrNotFound
	}
	if state.Detailed && s.fresh(state.UpdatedAt, s.MetaTTL) {
		return item, nil
	}
	call := s.items.Go(id, func(ctx context.Context) (MediaItem, error) {
		return s.fetchItem(ctx, id, item)
	})
	if state.Detailed && !state.UpdatedAt.IsZero() {
		return item, nil
	}
	full, err := call.Wait(ctx)
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return MediaItem{}, ctxErr
		}
		return item, nil
	}
	return full, nil
}

// fetchItem asks the providers in order for the details of item, and stores
// the first answer.
func (s *Service) fetchItem(ctx context.Context, id string, item MediaItem) (MediaItem, error) {
	err := errors.New("catalog: no provider knows the item")
	for _, p := range s.providers() {
		externalID := item.ExternalIDs[p.Namespace()]
		if externalID == "" {
			continue
		}
		full, metaErr := p.Meta(ctx, item.Kind, externalID)
		if metaErr != nil {
			s.log.Warn("meta fetch failed", "provider", p.ID(), "id", id, "err", metaErr)
			err = metaErr
			continue
		}
		saved, err := s.store.UpsertItems(ctx, p.Namespace(), []MediaItem{*full}, true)
		if err != nil {
			s.log.Warn("item cache write failed", "id", id, "err", err)
			return MediaItem{}, fmt.Errorf("cache item: %w", err)
		}
		if len(saved) == 1 && saved[0].ID != "" {
			return saved[0], nil
		}
		return *full, nil
	}
	return MediaItem{}, err
}

func (s *Service) ItemsByIDs(ctx context.Context, ids []string) ([]MediaItem, error) {
	return s.store.ItemsByIDs(ctx, ids)
}

// Known reports whether id is one we minted, without asking a provider.
func (s *Service) Known(ctx context.Context, id string) (bool, error) {
	_, state, err := s.store.Item(ctx, id)
	return state.Found, err
}

// Cached returns what the cache holds for ids, in the order asked for, and
// never waits on a provider. Details missing or past the TTL are asked for
// behind the answer, a few at a time, so the next one is fresher.
//
// It is for lists of titles nobody is opening right now — My list, the
// series whose new episodes are looked for. Item per title would wait on
// Cinemeta for each one never opened, and forty requests at once for a
// library of forty series is what gets a free service to refuse us.
func (s *Service) Cached(ctx context.Context, ids []string) ([]MediaItem, error) {
	out := make([]MediaItem, 0, len(ids))
	for _, id := range ids {
		item, state, err := s.store.Item(ctx, id)
		if err != nil {
			return nil, err
		}
		if !state.Found {
			continue
		}
		out = append(out, item)
		if state.Detailed && s.fresh(state.UpdatedAt, s.MetaTTL) {
			continue
		}
		s.items.Go(id, func(ctx context.Context) (MediaItem, error) {
			select {
			case s.background <- struct{}{}:
			case <-ctx.Done():
				return MediaItem{}, ctx.Err()
			}
			defer func() { <-s.background }()
			return s.fetchItem(ctx, id, item)
		})
	}
	return out, nil
}

func (s *Service) provider(id string) (Provider, error) {
	providers := s.providers()
	if len(providers) == 0 {
		return nil, ErrNoProviders
	}
	if id == "" {
		return providers[0], nil
	}
	for _, p := range providers {
		if p.ID() == id {
			return p, nil
		}
	}
	return nil, fmt.Errorf("catalog: unknown provider %q", id)
}

func (s *Service) fresh(t time.Time, ttl time.Duration) bool {
	return !t.IsZero() && s.now().Sub(t) < ttl
}

// pageKey has to be stable across restarts, so it is built from the request
// fields rather than from anything hashed in memory.
func pageKey(req BrowseRequest) string {
	return fmt.Sprintf("%s|%s|%s|genre=%s|search=%s|skip=%d",
		req.ProviderID, req.Kind, req.CatalogID, req.Genre, req.Search, req.Skip)
}

// identified drops what the store could not key: an item the provider returned
// without the id it addresses items by cannot be opened later.
func identified(items []MediaItem) []MediaItem {
	out := items[:0]
	for _, it := range items {
		if it.ID != "" {
			out = append(out, it)
		}
	}
	return out
}

func idsOf(items []MediaItem) []string {
	ids := make([]string, 0, len(items))
	for _, it := range items {
		ids = append(ids, it.ID)
	}
	return ids
}
