// Package sources defines where playable media comes from. The core never
// knows about BitTorrent, HTTP or anything else directly: it asks Providers
// for MediaSources and hands the winning locator to the acquisition layer.
package sources

import (
	"context"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/release"
)

// Query identifies what the user wants, not where it lives. IMDb IDs are the
// lingua franca of every source we have looked at; other IDs get added as
// providers need them.
type Query struct {
	Kind    catalog.Kind
	IMDbID  string
	Season  int
	Episode int
}

// Locator is the provider-specific handle for one source. Exactly one shape is
// populated, and only the matching acquisition backend understands it.
type Locator struct {
	Scheme    string   `json:"scheme"` // "torrent", "http", "file"
	InfoHash  string   `json:"infoHash,omitempty"`
	FileIndex *int     `json:"fileIndex,omitempty"`
	URL       string   `json:"url,omitempty"`
	Path      string   `json:"path,omitempty"`
	Trackers  []string `json:"trackers,omitempty"`
}

// Same says whether two locators name one file: trackers and the provider's
// other hints do not change which file it is.
func (l Locator) Same(o Locator) bool {
	if l.Scheme != o.Scheme {
		return false
	}
	if l.Scheme == "torrent" {
		return l.InfoHash == o.InfoHash && fileIndex(l) == fileIndex(o)
	}
	return l.URL == o.URL && l.Path == o.Path
}

func fileIndex(l Locator) int {
	if l.FileIndex == nil {
		return -1
	}
	return *l.FileIndex
}

// MediaSource is one candidate way to watch the requested item.
type MediaSource struct {
	ProviderID string       `json:"providerId"`
	RawName    string       `json:"rawName"` // exactly what the provider sent
	Release    release.Info `json:"release"`
	Size       int64        `json:"size,omitempty"` // bytes, 0 when unknown
	Seeders    int          `json:"seeders,omitempty"`
	Filename   string       `json:"filename,omitempty"`
	// Tracker is where the provider found this copy — its own word for it,
	// not ours. A provider that aggregates several trackers is the only one
	// that knows which of them answered.
	Tracker string `json:"tracker,omitempty"`
	// Languages the provider states this copy has, as ISO 639-1. Providers
	// declare these explicitly; the release-name parser only guesses, so
	// these win where both exist.
	Languages  []string `json:"languages,omitempty"`
	BingeGroup string   `json:"bingeGroup,omitempty"` // provider hint: same pack as the next episode
	Locator    Locator  `json:"locator"`
}

type Provider interface {
	ID() string
	Name() string
	Find(ctx context.Context, q Query) ([]MediaSource, error)
}
