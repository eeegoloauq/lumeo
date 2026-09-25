// Package subtitles finds the text for what is being watched. The domain
// model is deliberately thin: a provider answers a Query with candidates, and
// the Service decides which of them is the one for this release.
//
// Everything here is about one distinction other clients get wrong. A
// subtitle file is timed to a particular encode, so "English subtitles for
// this film" is the wrong question — the right one is "subtitles for the file
// I am playing", and the answer comes from the hash of that file, not from
// its title.
package subtitles

import (
	"context"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/release"
)

// Query is one lookup: what is being watched, and which copy of it.
type Query struct {
	Kind    catalog.Kind
	IMDbID  string
	Season  int
	Episode int

	// Below: the file actually being played. VideoHash is the OpenSubtitles
	// hash (see Hash); providers that understand it answer with subtitles
	// timed to exactly this encode, which is the whole point of sending it.
	Filename  string
	VideoSize int64
	VideoHash string
	// Release is what the source called itself, parsed. It is what ranking
	// falls back on when a provider returns names but no hash match.
	Release     release.Info
	ReleaseName string

	// Languages the viewer wants, best first, as ISO 639-1.
	Languages []string
}

// Subtitle is one candidate track.
//
// URL is ours, not the provider's: the client fetches subtitles through the
// core so that the encoding is fixed in one place and so that nothing outside
// can make the core fetch an arbitrary address.
type Subtitle struct {
	ProviderID string `json:"providerId"`
	ID         string `json:"id"`
	// Language is ISO 639-1 where we recognise the provider's code, and the
	// provider's own code where we do not.
	Language     string `json:"language"`
	LanguageName string `json:"languageName,omitempty"`
	// Name is what the provider calls this file — usually the release it was
	// timed for, which is why it is worth showing next to the language.
	Name   string `json:"name,omitempty"`
	Format string `json:"format,omitempty"` // srt, vtt, ass
	URL    string `json:"url"`              // core-relative path

	// HashMatch is the provider saying this file was found by the hash of the
	// video, not by its title: it was timed against this exact encode by
	// whoever uploaded it. It is the strongest thing a subtitle list can say.
	HashMatch bool `json:"hashMatch,omitempty"`
	// FPS the subtitle was timed at, when the provider knows it. A track
	// timed at 25 against a 23.976 encode drifts by minutes over a film, and
	// it is the only fact here a viewer can act on before pressing play.
	FPS float64 `json:"fps,omitempty"`

	// SourceURL is where it really lives. It never leaves the core.
	SourceURL string `json:"-"`
	// Encoding is the charset the provider declares, when it declares one.
	Encoding string `json:"-"`
}

// Provider is one place subtitles come from.
type Provider interface {
	ID() string
	Name() string
	Subtitles(ctx context.Context, q Query) ([]Subtitle, error)
}
