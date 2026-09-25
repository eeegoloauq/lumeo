// Package searches remembers what the viewer searched for, so that the search
// field can offer it again. It is the viewer's, like what they watched, so the
// core keeps it and every client shows the same.
package searches

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

// Keep is how many searches are remembered: the ones the field offers, and
// no long tail of everything ever typed.
const Keep = 10

// maxLength is a search, not a paragraph.
const maxLength = 200

// ErrInvalid is a query that is empty or longer than a search.
var ErrInvalid = errors.New("a search is 1 to 200 characters")

type Store interface {
	// RecordSearch puts query first, replacing one that differs only in
	// case, and forgets all but the latest keep.
	RecordSearch(ctx context.Context, query string, at time.Time, keep int) error
	// Searches is what is remembered, the latest first.
	Searches(ctx context.Context) ([]string, error)
	// ForgetSearch drops query, whatever its case.
	ForgetSearch(ctx context.Context, query string) error
	ClearSearches(ctx context.Context) error
}

type Service struct {
	store Store
	now   func() time.Time
}

func New(store Store) *Service {
	return &Service{store: store, now: time.Now}
}

func (s *Service) Recent(ctx context.Context) ([]string, error) {
	return s.store.Searches(ctx)
}

// Record remembers a search somebody went through with: the word they
// submitted, or the one whose answer they opened. Not every keystroke.
func (s *Service) Record(ctx context.Context, query string) error {
	query, err := normalize(query)
	if err != nil {
		return err
	}
	return s.store.RecordSearch(ctx, query, s.now(), Keep)
}

func (s *Service) Forget(ctx context.Context, query string) error {
	query, err := normalize(query)
	if err != nil {
		return err
	}
	return s.store.ForgetSearch(ctx, query)
}

func (s *Service) Clear(ctx context.Context) error {
	return s.store.ClearSearches(ctx)
}

// normalize is the query as it is kept: its words, one space between them.
func normalize(query string) (string, error) {
	query = strings.Join(strings.Fields(query), " ")
	if query == "" || utf8.RuneCountInString(query) > maxLength {
		return "", ErrInvalid
	}
	return query, nil
}
