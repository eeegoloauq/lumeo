package ratings

import (
	"context"
	"errors"
	"testing"
	"time"
)

type memory struct{ saved []Rating }

func (m *memory) SaveRating(_ context.Context, _ string, r Rating) error {
	m.saved = append(m.saved, r)
	return nil
}
func (m *memory) DeleteRating(context.Context, string, int, int) error { return nil }
func (m *memory) Ratings(context.Context, []string) (map[string][]Rating, error) {
	return map[string][]Rating{}, nil
}

type known map[string]bool

func (k known) Known(_ context.Context, id string) (bool, error) { return k[id], nil }

func TestSetChecksTheScoreAndTheTitle(t *testing.T) {
	store := &memory{}
	s := New(store, known{"series": true})
	at := time.Date(2026, 9, 24, 18, 0, 0, 500, time.UTC)
	s.now = func() time.Time { return at }
	ctx := context.Background()

	for _, c := range []struct {
		season, episode, score int
		want                   error
	}{
		{0, 0, 0, ErrInvalid},
		{0, 0, 11, ErrInvalid},
		{-1, 1, 5, ErrInvalid},
		{2, 0, 5, ErrInvalid}, // a season is not something to score
	} {
		if _, err := s.Set(ctx, "series", c.season, c.episode, c.score); !errors.Is(err, c.want) {
			t.Errorf("Set(%d, %d, %d) = %v, want %v", c.season, c.episode, c.score, err, c.want)
		}
	}
	if _, err := s.Set(ctx, "nobody", 0, 0, 5); !errors.Is(err, ErrUnknown) {
		t.Errorf("unknown title: %v", err)
	}
	for _, c := range [][2]int{{0, 0}, {1, 3}, {0, 2}} {
		r, err := s.Set(ctx, "series", c[0], c[1], 10)
		if err != nil || r.Score != 10 || !r.RatedAt.Equal(at.Truncate(time.Second)) {
			t.Errorf("Set(%v) = %+v, %v", c, r, err)
		}
	}
	if len(store.saved) != 3 {
		t.Fatalf("saved %d ratings, want 3", len(store.saved))
	}
}

func TestScoreFindsTheOneAsked(t *testing.T) {
	list := []Rating{{Score: 7}, {Season: 1, Episode: 2, Score: 9}}
	if Score(list, 0, 0) != 7 || Score(list, 1, 2) != 9 || Score(list, 1, 3) != 0 || Score(nil, 0, 0) != 0 {
		t.Fatal("Score found the wrong rating")
	}
}
