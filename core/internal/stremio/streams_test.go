package stremio

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

const oneStream = `{"streams":[{"title":"Film.2024.1080p","infoHash":"0123456789abcdef0123456789abcdef01234567"}]`

func TestFindKeepsTheAnswerAsLongAsTheAddonSays(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
		asks int32
	}{
		{"no hint", oneStream + `}`, 1},
		{"hint", oneStream + `,"cacheMaxAge":3600}`, 1},
		{"no caching", oneStream + `,"cacheMaxAge":0}`, 2},
		{"nothing found", `{"streams":[],"cacheMaxAge":3600}`, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var asks atomic.Int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				asks.Add(1)
				w.Write([]byte(tc.body))
			}))
			defer srv.Close()
			a := New("torrentio", "Torrentio", srv.URL)
			q := sources.Query{Kind: catalog.KindMovie, IMDbID: "tt0000001"}
			for range 2 {
				if _, err := a.Find(context.Background(), q); err != nil {
					t.Fatalf("find: %v", err)
				}
			}
			if got := asks.Load(); got != tc.asks {
				t.Fatalf("asked %d times, want %d", got, tc.asks)
			}
		})
	}
}
