// Package personal moves a viewer's own data between cores as one file: what
// they watched and how far, their scores, My list, their searches and their
// preferences. Downloads, addons and the machine's settings stay where they
// are.
//
// Our item ids are minted per core, so the file names each title by its IMDb
// id, as a shared link does. An import merges: of two entries for the same
// episode, score or tracks the later one wins, a title already on My list
// keeps its date, and nothing is removed, so importing a file twice changes
// nothing the second time.
package personal

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/url"
	"regexp"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/searches"
)

// Format names the file; Version changes when a core could no longer read
// what an older one wrote, and a file of a newer version is refused.
const (
	Format  = "lumeo-personal"
	Version = 1
)

type Document struct {
	Format      string                     `json:"format"`
	Version     int                        `json:"version"`
	ExportedAt  time.Time                  `json:"exportedAt"`
	Titles      []Title                    `json:"titles"`
	Searches    []Search                   `json:"searches"`
	Preferences map[string]json.RawMessage `json:"preferences"`
}

// Title is one film or series and everything of the viewer's about it. Kind,
// Name, Year and Poster are its catalogue row, enough to list it on a core
// that has never seen it until its details are fetched on first open.
type Title struct {
	IMDb     string       `json:"imdb"`
	Kind     catalog.Kind `json:"kind"`
	Name     string       `json:"title"`
	Year     int          `json:"year,omitempty"`
	Poster   string       `json:"poster,omitempty"`
	ListedAt *time.Time   `json:"listedAt,omitempty"`
	Progress []Progress   `json:"progress,omitempty"`
	Ratings  []Rating     `json:"ratings,omitempty"`
	Tracks   *Tracks      `json:"tracks,omitempty"`
}

// Progress is one film's or episode's watch state; season and episode are 0
// for a film.
type Progress struct {
	Season        int       `json:"season"`
	Episode       int       `json:"episode"`
	Position      float64   `json:"position"`
	Duration      float64   `json:"duration"`
	Watched       bool      `json:"watched"`
	UpdatedAt     time.Time `json:"updatedAt"`
	SubtitleDelay float64   `json:"subtitleDelay,omitempty"`
}

// Rating is a score of the title when season and episode are 0, of one
// episode otherwise.
type Rating struct {
	Season  int       `json:"season"`
	Episode int       `json:"episode"`
	Score   int       `json:"rating"`
	RatedAt time.Time `json:"ratedAt"`
}

// Tracks are the audio and subtitles the viewer picked for a title. The copy
// they picked is left out: it names a release on the disk of the core it
// came from.
type Tracks struct {
	Audio     *progress.Track `json:"audio,omitempty"`
	Subtitle  *progress.Track `json:"subtitle,omitempty"`
	UpdatedAt time.Time       `json:"updatedAt"`
}

type Search struct {
	Query      string    `json:"query"`
	SearchedAt time.Time `json:"searchedAt"`
}

// Counts is what an import changed: titles new to the catalogue, and entries
// written because the core had none or an older one.
type Counts struct {
	Titles      int `json:"titles"`
	Progress    int `json:"progress"`
	Ratings     int `json:"ratings"`
	List        int `json:"list"`
	Tracks      int `json:"tracks"`
	Searches    int `json:"searches"`
	Preferences int `json:"preferences"`
}

type Store interface {
	// ExportPersonal returns every title that has any of the viewer's data
	// and an IMDb id, and the searches. Progress kept under a local file's
	// hash has no title another core could find it by and stays behind.
	ExportPersonal(ctx context.Context) ([]Title, []Search, error)
	// ImportPersonal merges titles, searches and preferences in one
	// transaction, keeping the latest searchKeep searches.
	ImportPersonal(ctx context.Context, titles []Title, found []Search, prefs map[string]json.RawMessage, searchKeep int) (Counts, error)
}

// ErrInvalid wraps every refusal of a document; its message is for the
// person who picked the file.
var ErrInvalid = errors.New("invalid personal data")

type invalidError struct{ message string }

func (e invalidError) Error() string { return e.message }
func (e invalidError) Unwrap() error { return ErrInvalid }

func invalidf(format string, args ...any) error {
	return invalidError{message: fmt.Sprintf(format, args...)}
}

type Service struct {
	store Store
	prefs *preferences.Service
	now   func() time.Time
}

func New(store Store, prefs *preferences.Service) *Service {
	return &Service{store: store, prefs: prefs, now: time.Now}
}

func (s *Service) Export(ctx context.Context) (Document, error) {
	titles, found, err := s.store.ExportPersonal(ctx)
	if err != nil {
		return Document{}, err
	}
	// The poster is the one field the core keeps as a provider sent it; one
	// an import would refuse is left out, and the title's page fetches it.
	for i := range titles {
		if !webAddress(titles[i].Poster) {
			titles[i].Poster = ""
		}
	}
	prefs, err := s.prefs.StoredPersonal(ctx)
	if err != nil {
		return Document{}, err
	}
	return Document{
		Format:      Format,
		Version:     Version,
		ExportedAt:  s.now().UTC().Truncate(time.Second),
		Titles:      titles,
		Searches:    found,
		Preferences: prefs,
	}, nil
}

// Import checks the whole document before anything is written, then writes
// all of it or none.
func (s *Service) Import(ctx context.Context, doc Document) (Counts, error) {
	if err := check(&doc); err != nil {
		return Counts{}, err
	}
	prefs, err := preferences.ValidatePersonal(doc.Preferences)
	if errors.Is(err, preferences.ErrInvalid) {
		return Counts{}, invalidError{message: err.Error()}
	}
	if err != nil {
		return Counts{}, err
	}
	var counts Counts
	_, err = s.prefs.Write(ctx, func(ctx context.Context) error {
		var err error
		counts, err = s.store.ImportPersonal(ctx, doc.Titles, doc.Searches, prefs, searches.Keep)
		return err
	})
	if err != nil {
		return Counts{}, err
	}
	return counts, nil
}

var imdbID = regexp.MustCompile(`^tt[0-9]{1,10}$`)

// check refuses a document no core could have written, and normalises the
// searches as the search history keeps them.
func check(doc *Document) error {
	if doc.Format != Format {
		return invalidf("not a Lumeo personal data file")
	}
	if doc.Version > Version {
		return invalidf("made by a newer Lumeo: update this one first")
	}
	if doc.Version < 1 {
		return invalidf("version %d is not one Lumeo wrote", doc.Version)
	}
	seen := make(map[string]bool, len(doc.Titles))
	for i := range doc.Titles {
		title := &doc.Titles[i]
		if err := checkTitle(title); err != nil {
			return err
		}
		if seen[title.IMDb] {
			return invalidf("%s is in the file twice", title.IMDb)
		}
		seen[title.IMDb] = true
	}
	for i := range doc.Searches {
		query, err := searches.Normalize(doc.Searches[i].Query)
		if err != nil {
			return invalidf("search %q: %v", doc.Searches[i].Query, err)
		}
		if doc.Searches[i].SearchedAt.IsZero() {
			return invalidf("search %q has no time", query)
		}
		doc.Searches[i].Query = query
	}
	return nil
}

func checkTitle(t *Title) error {
	if !imdbID.MatchString(t.IMDb) {
		return invalidf("%q is not an IMDb id", t.IMDb)
	}
	if t.Kind != catalog.KindMovie && t.Kind != catalog.KindSeries {
		return invalidf("%s: kind must be movie or series", t.IMDb)
	}
	if t.Year < 0 || t.Year > 9999 {
		return invalidf("%s: year %d", t.IMDb, t.Year)
	}
	if t.Poster != "" && !webAddress(t.Poster) {
		return invalidf("%s: poster is not a web address", t.IMDb)
	}
	if t.ListedAt != nil && t.ListedAt.IsZero() {
		return invalidf("%s: listedAt has no time", t.IMDb)
	}
	type key struct{ season, episode int }
	entries := make(map[key]bool, len(t.Progress))
	for _, p := range t.Progress {
		if p.Season < 0 || p.Episode < 0 {
			return invalidf("%s: season and episode must not be negative", t.IMDb)
		}
		if entries[key{p.Season, p.Episode}] {
			return invalidf("%s: progress of S%dE%d twice", t.IMDb, p.Season, p.Episode)
		}
		entries[key{p.Season, p.Episode}] = true
		if !finite(p.Position) || p.Position < 0 || !finite(p.Duration) || p.Duration < 0 ||
			(p.Duration > 0 && p.Position > p.Duration) {
			return invalidf("%s: position %v of %v", t.IMDb, p.Position, p.Duration)
		}
		if !finite(p.SubtitleDelay) {
			return invalidf("%s: subtitle delay %v", t.IMDb, p.SubtitleDelay)
		}
		if p.UpdatedAt.IsZero() {
			return invalidf("%s: progress has no time", t.IMDb)
		}
	}
	scores := make(map[key]bool, len(t.Ratings))
	for _, r := range t.Ratings {
		// As the rating service takes them: a special is season 0 with a
		// number, and a season with no episode is nothing.
		if r.Season < 0 || r.Episode < 0 || (r.Season > 0 && r.Episode == 0) {
			return invalidf("%s: no episode S%dE%d to rate", t.IMDb, r.Season, r.Episode)
		}
		if scores[key{r.Season, r.Episode}] {
			return invalidf("%s: rating of S%dE%d twice", t.IMDb, r.Season, r.Episode)
		}
		scores[key{r.Season, r.Episode}] = true
		if r.Score < 1 || r.Score > 10 {
			return invalidf("%s: rating must be between 1 and 10", t.IMDb)
		}
		if r.RatedAt.IsZero() {
			return invalidf("%s: rating has no time", t.IMDb)
		}
	}
	if t.Tracks != nil {
		if t.Tracks.Audio == nil && t.Tracks.Subtitle == nil {
			return invalidf("%s: tracks name neither audio nor subtitles", t.IMDb)
		}
		if t.Tracks.UpdatedAt.IsZero() {
			return invalidf("%s: tracks have no time", t.IMDb)
		}
	}
	return nil
}

// webAddress is what the core fetches artwork from; only that is a poster.
func webAddress(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Host != ""
}

func finite(f float64) bool { return !math.IsNaN(f) && !math.IsInf(f, 0) }
