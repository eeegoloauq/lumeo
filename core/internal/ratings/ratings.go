// Package ratings keeps the viewer's own scores, 1 to 10, of titles and of
// single episodes. They live in the core with watch progress, for the same
// reason: every client shows the same library, and a score given on the
// laptop is the one the TV shows. Together with the IMDb ids and the watched
// latch they are also all an import from Trakt, or an export to it, needs.
package ratings

import (
	"context"
	"errors"
	"time"
)

// Rating is one score. Season and Episode are 0 for the title itself.
type Rating struct {
	Season  int       `json:"season"`
	Episode int       `json:"episode"`
	Score   int       `json:"rating"`
	RatedAt time.Time `json:"ratedAt"`
}

// Title reports whether the rating is of the whole title.
func (r Rating) Title() bool { return r.Season == 0 && r.Episode == 0 }

type Store interface {
	SaveRating(ctx context.Context, itemID string, rating Rating) error
	DeleteRating(ctx context.Context, itemID string, season, episode int) error
	// Ratings returns every rating of the given titles, by title.
	Ratings(ctx context.Context, itemIDs []string) (map[string][]Rating, error)
}

// Catalog says whether an id is a title the core knows. Only a title can be
// rated: a score of an id nothing resolves could never be shown again.
type Catalog interface {
	Known(ctx context.Context, id string) (bool, error)
}

var (
	ErrInvalid = errors.New("invalid rating")
	ErrUnknown = errors.New("unknown title")
)

type invalidError struct{ message string }

func (e invalidError) Error() string { return e.message }
func (e invalidError) Unwrap() error { return ErrInvalid }

type Service struct {
	store   Store
	catalog Catalog
	now     func() time.Time
}

func New(store Store, catalog Catalog) *Service {
	return &Service{store: store, catalog: catalog, now: time.Now}
}

// Set scores a title, or one of its episodes, replacing an earlier score.
func (s *Service) Set(ctx context.Context, itemID string, season, episode, score int) (Rating, error) {
	if season < 0 || episode < 0 {
		return Rating{}, invalidError{"season and episode must not be negative"}
	}
	// A special is season 0 with a number; a season with no episode would be
	// a score of the whole season, which nothing shows.
	if season > 0 && episode == 0 {
		return Rating{}, invalidError{"an episode needs its number"}
	}
	if score < 1 || score > 10 {
		return Rating{}, invalidError{"rating must be between 1 and 10"}
	}
	known, err := s.catalog.Known(ctx, itemID)
	if err != nil {
		return Rating{}, err
	}
	if !known {
		return Rating{}, ErrUnknown
	}
	rating := Rating{Season: season, Episode: episode, Score: score, RatedAt: s.now().UTC().Truncate(time.Second)}
	if err := s.store.SaveRating(ctx, itemID, rating); err != nil {
		return Rating{}, err
	}
	return rating, nil
}

// Clear removes a score; clearing one that is not there is not an error.
func (s *Service) Clear(ctx context.Context, itemID string, season, episode int) error {
	if season < 0 || episode < 0 {
		return invalidError{"season and episode must not be negative"}
	}
	return s.store.DeleteRating(ctx, itemID, season, episode)
}

// Of returns every score of one title: its own and its episodes'.
func (s *Service) Of(ctx context.Context, itemID string) ([]Rating, error) {
	all, err := s.store.Ratings(ctx, []string{itemID})
	if err != nil {
		return nil, err
	}
	if all[itemID] == nil {
		return []Rating{}, nil
	}
	return all[itemID], nil
}

// For returns the scores of several titles at once, by title.
func (s *Service) For(ctx context.Context, itemIDs []string) (map[string][]Rating, error) {
	return s.store.Ratings(ctx, itemIDs)
}

// Score finds the score of one title or episode in a list [For] returned; 0
// when there is none.
func Score(list []Rating, season, episode int) int {
	for _, r := range list {
		if r.Season == season && r.Episode == episode {
			return r.Score
		}
	}
	return 0
}
