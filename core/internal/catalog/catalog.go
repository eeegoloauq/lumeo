// Package catalog is the domain model of everything watchable: an item, its
// episodes, and the ids other systems know it by. It is the bottom of the
// dependency graph on purpose — sources, store and the API all speak these
// types, and none of them knows which metadata provider filled them in.
package catalog

import (
	"context"
	"time"
)

type Kind string

const (
	KindMovie  Kind = "movie"
	KindSeries Kind = "series"
)

// Namespaces of external ids. Ours is the only id the library stores; these
// are what providers and sources address the same item by.
const (
	NamespaceIMDb = "imdb"
	NamespaceTMDB = "tmdb"
	NamespaceTVDB = "tvdb"
)

// ExternalIDs maps a namespace to that system's id for the item.
type ExternalIDs map[string]string

// MediaItem is one movie or series. ID is ours and stable across metadata
// providers; everything else can be refetched or replaced.
type MediaItem struct {
	ID          string      `json:"id"`
	Kind        Kind        `json:"kind"`
	Title       string      `json:"title"`
	Year        int         `json:"year,omitempty"`
	YearEnd     int         `json:"yearEnd,omitempty"` // series: last aired year, 0 while running
	Overview    string      `json:"overview,omitempty"`
	Poster      string      `json:"poster,omitempty"`
	Background  string      `json:"background,omitempty"`
	Logo        string      `json:"logo,omitempty"`
	Genres      []string    `json:"genres,omitempty"`
	Cast        []string    `json:"cast,omitempty"`
	Directors   []string    `json:"directors,omitempty"`
	Runtime     string      `json:"runtime,omitempty"` // as the provider renders it, e.g. "136 min"
	IMDbRating  float64     `json:"imdbRating,omitempty"`
	ExternalIDs ExternalIDs `json:"externalIds,omitempty"`
	Episodes    []Episode   `json:"episodes,omitempty"` // series only, and only from Meta
}

// IMDbID is the id every source provider we have speaks.
func (i MediaItem) IMDbID() string { return i.ExternalIDs[NamespaceIMDb] }

type Episode struct {
	Season    int    `json:"season"`
	Number    int    `json:"number"`
	Title     string `json:"title,omitempty"`
	Overview  string `json:"overview,omitempty"`
	Thumbnail string `json:"thumbnail,omitempty"`
	// ThumbnailFallback is tried when Thumbnail is missing upstream. The API
	// folds it into the thumbnail's artwork URL and never sends it as is.
	ThumbnailFallback string    `json:"thumbnailFallback,omitempty"`
	Released          time.Time `json:"released,omitempty"`
	// Rating is per-episode and often absent: some titles have it for every
	// episode, others for none. Zero means the provider did not say.
	Rating float64 `json:"rating,omitempty"`
}

// Row is one catalog a provider offers: a labelled list such as "Popular
// movies", with the filters it accepts. Rows come from the provider manifest
// and are what a home screen is built from.
type Row struct {
	ProviderID string   `json:"providerId"`
	ID         string   `json:"id"`
	Kind       Kind     `json:"kind"`
	Name       string   `json:"name"`
	Genres     []string `json:"genres,omitempty"` // values accepted by BrowseRequest.Genre
	Searchable bool     `json:"searchable"`
}

// BrowseRequest asks one provider for one page of one row.
type BrowseRequest struct {
	ProviderID string
	Kind       Kind
	CatalogID  string
	Genre      string
	Search     string
	Skip       int
}

// Provider serves metadata. Cinemeta is the default implementation and needs
// no API key; anything else the user configures plugs in here.
type Provider interface {
	ID() string
	Name() string
	// Namespace is the external id namespace this provider addresses items
	// by, e.g. "imdb" for everything speaking the addon protocol.
	Namespace() string
	// Rows lists the catalogs the provider offers.
	Rows(ctx context.Context) ([]Row, error)
	// Browse returns one page of a row. Items carry provider ids in
	// ExternalIDs and an empty ID: minting ours is the store's job.
	Browse(ctx context.Context, req BrowseRequest) ([]MediaItem, error)
	// Meta returns the full item, episodes included, by the provider's own id.
	Meta(ctx context.Context, kind Kind, externalID string) (*MediaItem, error)
}

// ItemState is what the store knows about a cached item besides its contents.
type ItemState struct {
	Found    bool
	Detailed bool // came from Meta, not from a catalog row
	// UpdatedAt is when the details were fetched once Detailed: a catalog row
	// carries no episodes, so seeing the title in a list must not make them
	// look fresh. It is zero for details another core version wrote, which
	// may be parsed differently and are not served while new ones load.
	UpdatedAt time.Time
}

// Store persists the catalog. It owns internal ids: UpsertItems matches each
// item on ExternalIDs[namespace], mints an id when it is new, and returns the
// items with ID filled in.
type Store interface {
	UpsertItems(ctx context.Context, namespace string, items []MediaItem, detailed bool) ([]MediaItem, error)
	Item(ctx context.Context, id string) (MediaItem, ItemState, error)
	// ItemsByIDs returns the items that exist, in the order asked for.
	ItemsByIDs(ctx context.Context, ids []string) ([]MediaItem, error)
	SavePage(ctx context.Context, key string, itemIDs []string) error
	Page(ctx context.Context, key string) ([]string, time.Time, error)
}
