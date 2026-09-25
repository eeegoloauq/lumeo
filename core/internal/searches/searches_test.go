package searches

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"
)

type memStore struct{ queries []string }

func (m *memStore) RecordSearch(_ context.Context, query string, _ time.Time, keep int) error {
	m.queries = append([]string{query}, m.queries...)
	if len(m.queries) > keep {
		m.queries = m.queries[:keep]
	}
	return nil
}
func (m *memStore) Searches(context.Context) ([]string, error) { return m.queries, nil }
func (m *memStore) ForgetSearch(context.Context, string) error { return nil }
func (m *memStore) ClearSearches(context.Context) error        { m.queries = nil; return nil }

func TestRecordKeepsWordsNotSpacing(t *testing.T) {
	store := &memStore{}
	s := New(store)
	if err := s.Record(context.Background(), "  breaking \t bad "); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(store.queries, []string{"breaking bad"}) {
		t.Fatalf("stored %q", store.queries)
	}
	for _, bad := range []string{"", "   ", strings.Repeat("я", 201)} {
		if err := s.Record(context.Background(), bad); !errors.Is(err, ErrInvalid) {
			t.Fatalf("record %q: %v, want ErrInvalid", bad, err)
		}
	}
	if err := s.Record(context.Background(), strings.Repeat("я", 200)); err != nil {
		t.Fatalf("200 characters: %v", err)
	}
}
