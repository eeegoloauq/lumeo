package catalog

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// memStore is the Store contract as the service needs it, with none of the
// SQL: what these tests are about is when the service talks to a provider.
// Provider answers are stored from the service's own goroutines, hence the
// lock.
type memStore struct {
	mu     sync.Mutex
	items  map[string]MediaItem
	state  map[string]ItemState
	byExt  map[string]string // namespace|externalID -> internal id
	pages  map[string][]string
	pageAt map[string]time.Time
	nextID int
	now    time.Time
}

func newMemStore(now time.Time) *memStore {
	return &memStore{
		items:  map[string]MediaItem{},
		state:  map[string]ItemState{},
		byExt:  map[string]string{},
		pages:  map[string][]string{},
		pageAt: map[string]time.Time{},
		now:    now,
	}
}

func (m *memStore) UpsertItems(_ context.Context, ns string, items []MediaItem, detailed bool) ([]MediaItem, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]MediaItem, 0, len(items))
	for _, it := range items {
		ext := it.ExternalIDs[ns]
		if ext == "" {
			out = append(out, it)
			continue
		}
		key := ns + "|" + ext
		id, ok := m.byExt[key]
		if !ok {
			m.nextID++
			id = string(rune('a' + m.nextID))
			m.byExt[key] = id
		}
		it.ID = id
		if old, ok := m.items[id]; ok && len(it.Episodes) == 0 {
			it.Episodes = old.Episodes
		}
		m.items[id] = it
		st := m.state[id]
		m.state[id] = ItemState{Found: true, Detailed: st.Detailed || detailed, UpdatedAt: m.now}
		out = append(out, it)
	}
	return out, nil
}

func (m *memStore) Item(_ context.Context, id string) (MediaItem, ItemState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.items[id], m.state[id], nil
}

func (m *memStore) ItemsByIDs(_ context.Context, ids []string) ([]MediaItem, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []MediaItem
	for _, id := range ids {
		if it, ok := m.items[id]; ok {
			out = append(out, it)
		}
	}
	return out, nil
}

func (m *memStore) SavePage(_ context.Context, key string, ids []string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pages[key], m.pageAt[key] = ids, m.now
	return nil
}

func (m *memStore) Page(_ context.Context, key string) ([]string, time.Time, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.pages[key], m.pageAt[key], nil
}

func (m *memStore) setNow(t time.Time) {
	m.mu.Lock()
	m.now = t
	m.mu.Unlock()
}

// expire does to everything cached what a core of another version finds.
func (m *memStore) expire() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, st := range m.state {
		st.UpdatedAt = time.Time{}
		m.state[id] = st
	}
	for key := range m.pageAt {
		m.pageAt[key] = time.Time{}
	}
}

type fakeProvider struct {
	id    string
	rows  []Row
	items []MediaItem
	meta  *MediaItem

	mu  sync.Mutex
	err error
	// gate, when set, holds every Browse and Meta until it is closed.
	gate chan struct{}

	browses atomic.Int32
	metas   atomic.Int32
}

func (f *fakeProvider) ID() string        { return f.id }
func (f *fakeProvider) Name() string      { return f.id }
func (f *fakeProvider) Namespace() string { return NamespaceIMDb }
func (f *fakeProvider) Rows(context.Context) ([]Row, error) {
	return f.rows, nil
}
func (f *fakeProvider) Browse(ctx context.Context, _ BrowseRequest) ([]MediaItem, error) {
	f.browses.Add(1)
	if err := f.answer(ctx); err != nil {
		return nil, err
	}
	return f.items, nil
}
func (f *fakeProvider) Meta(ctx context.Context, _ Kind, _ string) (*MediaItem, error) {
	f.metas.Add(1)
	if err := f.answer(ctx); err != nil {
		return nil, err
	}
	return f.meta, nil
}

func (f *fakeProvider) answer(ctx context.Context) error {
	f.mu.Lock()
	gate, err := f.gate, f.err
	f.mu.Unlock()
	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return err
}

func (f *fakeProvider) fail(err error) {
	f.mu.Lock()
	f.err = err
	f.mu.Unlock()
}

func (f *fakeProvider) hold() chan struct{} {
	gate := make(chan struct{})
	f.mu.Lock()
	f.gate = gate
	f.mu.Unlock()
	return gate
}

func testService(t *testing.T, p *fakeProvider, st *memStore) *Service {
	s := NewService(Fixed(p), st, slog.New(slog.NewTextHandler(io.Discard, nil)))
	now := st.now
	s.now = func() time.Time { return now }
	t.Cleanup(s.Close)
	return s
}

func movie(imdb, title string) MediaItem {
	return MediaItem{Kind: KindMovie, Title: title, ExternalIDs: ExternalIDs{NamespaceIMDb: imdb}}
}

func browseReq() BrowseRequest {
	return BrowseRequest{ProviderID: "meta", Kind: KindMovie, CatalogID: "top"}
}

func TestBrowseServesSecondCallFromCache(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	p := &fakeProvider{id: "meta", items: []MediaItem{movie("tt0133093", "The Matrix")}}
	svc := testService(t, p, st)

	first, err := svc.Browse(context.Background(), browseReq())
	if err != nil {
		t.Fatalf("browse: %v", err)
	}
	if len(first) != 1 || first[0].ID == "" {
		t.Fatalf("expected one item with an internal id, got %+v", first)
	}
	second, err := svc.Browse(context.Background(), browseReq())
	if err != nil {
		t.Fatalf("browse again: %v", err)
	}
	if p.browses.Load() != 1 {
		t.Errorf("provider hit %d times, want 1", p.browses.Load())
	}
	if len(second) != 1 || second[0].ID != first[0].ID {
		t.Errorf("cached page returned %+v", second)
	}
}

// Past the TTL the cached page is the answer, and the provider is asked in
// the background: a slow or blocked Cinemeta costs freshness, not a wait.
func TestBrowseServesStalePageAndRefetchesInBackground(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	p := &fakeProvider{id: "meta", items: []MediaItem{movie("tt0133093", "The Matrix")}}
	svc := testService(t, p, st)
	if _, err := svc.Browse(context.Background(), browseReq()); err != nil {
		t.Fatalf("browse: %v", err)
	}
	later := st.now.Add(DefaultPageTTL + time.Minute)
	svc.now = func() time.Time { return later }
	st.setNow(later)
	gate := p.hold()
	p.items = []MediaItem{movie("tt0133093", "The Matrix"), movie("tt0234215", "The Matrix Reloaded")}

	items, err := svc.Browse(context.Background(), browseReq())
	if err != nil {
		t.Fatalf("browse: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("stale page not served while the provider is out: %+v", items)
	}
	close(gate)
	svc.items.Wait() // the background requests, answered
	svc.pages.Wait()
	if p.browses.Load() != 2 {
		t.Errorf("provider hit %d times, want 2", p.browses.Load())
	}
	if items, _ := svc.Browse(context.Background(), browseReq()); len(items) != 2 {
		t.Errorf("background answer not cached: %+v", items)
	}
}

// Cinemeta is a free service with no SLA: when it is down, yesterday's home
// screen is a better answer than an error.
func TestBrowseFallsBackToStalePage(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	p := &fakeProvider{id: "meta", items: []MediaItem{movie("tt0133093", "The Matrix")}}
	svc := testService(t, p, st)
	if _, err := svc.Browse(context.Background(), browseReq()); err != nil {
		t.Fatalf("browse: %v", err)
	}
	later := st.now.Add(DefaultPageTTL + time.Minute)
	svc.now = func() time.Time { return later }
	p.fail(errors.New("cinemeta down"))

	items, err := svc.Browse(context.Background(), browseReq())
	if err != nil {
		t.Fatalf("expected the stale page, got error %v", err)
	}
	if len(items) != 1 || items[0].Title != "The Matrix" {
		t.Errorf("stale page returned %+v", items)
	}
}

// A page another core version wrote may be parsed differently: it waits for
// the provider, and is still better than an error when the provider is down.
func TestBrowseWaitsOutPageOfAnotherVersion(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	p := &fakeProvider{id: "meta", items: []MediaItem{movie("tt0133093", "The Matrix")}}
	svc := testService(t, p, st)
	if _, err := svc.Browse(context.Background(), browseReq()); err != nil {
		t.Fatalf("browse: %v", err)
	}
	st.expire()
	p.items = []MediaItem{movie("tt0133093", "The Matrix"), movie("tt0234215", "The Matrix Reloaded")}
	if items, err := svc.Browse(context.Background(), browseReq()); err != nil || len(items) != 2 {
		t.Fatalf("expired page not refetched: %+v, %v", items, err)
	}

	st.expire()
	p.fail(errors.New("cinemeta down"))
	if items, err := svc.Browse(context.Background(), browseReq()); err != nil || len(items) != 2 {
		t.Fatalf("expired page not served when the provider is down: %+v, %v", items, err)
	}
}

func TestItemFetchesMetaOnceAndKeepsEpisodes(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series := MediaItem{Kind: KindSeries, Title: "Severance", ExternalIDs: ExternalIDs{NamespaceIMDb: "tt11280740"}}
	full := series
	full.Overview = "Mark leads a team"
	full.Episodes = []Episode{{Season: 1, Number: 1, Title: "Good News About Hell"}}
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)

	page, err := svc.Browse(context.Background(), BrowseRequest{ProviderID: "meta", Kind: KindSeries, CatalogID: "top"})
	if err != nil {
		t.Fatalf("browse: %v", err)
	}
	id := page[0].ID

	got, err := svc.Item(context.Background(), id)
	if err != nil {
		t.Fatalf("item: %v", err)
	}
	if len(got.Episodes) != 1 || got.Overview == "" {
		t.Fatalf("meta not merged in: %+v", got)
	}
	if _, err := svc.Item(context.Background(), id); err != nil {
		t.Fatalf("item again: %v", err)
	}
	if p.metas.Load() != 1 {
		t.Errorf("meta fetched %d times, want 1", p.metas.Load())
	}

	// A later catalog page carries no episodes; it must not undo the meta.
	if _, err := svc.Browse(context.Background(), BrowseRequest{ProviderID: "meta", Kind: KindSeries, CatalogID: "other"}); err != nil {
		t.Fatalf("browse: %v", err)
	}
	again, err := svc.Item(context.Background(), id)
	if err != nil {
		t.Fatalf("item: %v", err)
	}
	if len(again.Episodes) != 1 {
		t.Errorf("catalog row wiped the episodes: %+v", again)
	}
}

func severanceFixture() (MediaItem, MediaItem) {
	series := MediaItem{Kind: KindSeries, Title: "Severance", ExternalIDs: ExternalIDs{NamespaceIMDb: "tt11280740"}}
	full := series
	full.Overview = "Mark leads a team"
	full.Episodes = []Episode{{Season: 1, Number: 1, Title: "Good News About Hell"}}
	return series, full
}

func browseSeries(t *testing.T, svc *Service) string {
	t.Helper()
	page, err := svc.Browse(context.Background(), BrowseRequest{ProviderID: "meta", Kind: KindSeries, CatalogID: "top"})
	if err != nil || len(page) != 1 {
		t.Fatalf("browse: %+v, %v", page, err)
	}
	return page[0].ID
}

// Details past the TTL are the answer while new ones load: opening a title
// seen yesterday must not wait for Cinemeta.
func TestItemServesStaleDetailsWithoutWaiting(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series, full := severanceFixture()
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)
	id := browseSeries(t, svc)
	if _, err := svc.Item(context.Background(), id); err != nil {
		t.Fatalf("item: %v", err)
	}

	later := st.now.Add(DefaultMetaTTL + time.Minute)
	svc.now = func() time.Time { return later }
	st.setNow(later)
	gate := p.hold()
	newer := full
	newer.Episodes = append(append([]Episode(nil), full.Episodes...), Episode{Season: 1, Number: 2, Title: "Half Loop"})
	p.meta = &newer

	got, err := svc.Item(context.Background(), id)
	if err != nil {
		t.Fatalf("item: %v", err)
	}
	if len(got.Episodes) != 1 {
		t.Fatalf("stale details not served while the provider is out: %+v", got)
	}
	close(gate)
	svc.items.Wait() // the background requests, answered
	svc.pages.Wait()
	if p.metas.Load() != 2 {
		t.Errorf("meta fetched %d times, want 2", p.metas.Load())
	}
	if got, _ := svc.Item(context.Background(), id); len(got.Episodes) != 2 {
		t.Errorf("background answer not cached: %+v", got)
	}
}

// Details another core version wrote wait for the provider, so a parser
// change shows on the next open.
func TestItemWaitsOutDetailsOfAnotherVersion(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series, full := severanceFixture()
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)
	id := browseSeries(t, svc)
	if _, err := svc.Item(context.Background(), id); err != nil {
		t.Fatalf("item: %v", err)
	}

	st.expire()
	newer := full
	newer.Overview = "Parsed anew"
	p.meta = &newer
	got, err := svc.Item(context.Background(), id)
	if err != nil {
		t.Fatalf("item: %v", err)
	}
	if got.Overview != "Parsed anew" {
		t.Errorf("details of another version served: %+v", got)
	}
}

// Opening a title asks for it from the page, its progress and its sources at
// once; the provider hears one request.
func TestItemJoinsTheRequestInFlight(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series, full := severanceFixture()
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)
	id := browseSeries(t, svc)
	gate := p.hold()

	const callers = 3
	results := make(chan MediaItem, callers)
	for range callers {
		go func() {
			got, err := svc.Item(context.Background(), id)
			if err != nil {
				t.Errorf("item: %v", err)
			}
			results <- got
		}()
	}
	for p.metas.Load() == 0 {
		time.Sleep(time.Millisecond)
	}
	close(gate)
	for range callers {
		if got := <-results; len(got.Episodes) != 1 {
			t.Errorf("caller got %+v", got)
		}
	}
	if p.metas.Load() != 1 {
		t.Errorf("meta fetched %d times, want 1", p.metas.Load())
	}
}

// A caller that gives up gets its context's error; the request carries on
// and its answer is cached for the next one.
func TestItemCallerLeavingDoesNotCancelTheFetch(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series, full := severanceFixture()
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)
	id := browseSeries(t, svc)
	gate := p.hold()

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := svc.Item(ctx, id); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v, want context.Canceled", err)
	}
	close(gate)
	svc.items.Wait() // the background requests, answered
	svc.pages.Wait()
	_, state, _ := st.Item(context.Background(), id)
	if !state.Detailed {
		t.Error("the answer of a request its caller left was not cached")
	}
}

// Close cancels what is still out and waits for it; a title opened after it
// is served from the cache.
func TestCloseCancelsRequestsInFlight(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series, full := severanceFixture()
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)
	id := browseSeries(t, svc)
	p.hold() // never answers

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := svc.Item(ctx, id); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v, want context.Canceled", err)
	}
	svc.Close()
	got, err := svc.Item(context.Background(), id)
	if err != nil || got.Title != "Severance" {
		t.Fatalf("item after close: %+v, %v", got, err)
	}
}

func TestItemUnknownID(t *testing.T) {
	svc := testService(t, &fakeProvider{id: "meta"}, newMemStore(time.Unix(1_700_000_000, 0)))
	if _, err := svc.Item(context.Background(), "nope"); !errors.Is(err, ErrNotFound) {
		t.Errorf("got %v, want ErrNotFound", err)
	}
}

func TestSearchUsesSearchableRow(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	p := &fakeProvider{
		id: "meta",
		rows: []Row{
			{ProviderID: "meta", ID: "year", Kind: KindMovie, Name: "By year"},
			{ProviderID: "meta", ID: "top", Kind: KindMovie, Name: "Popular", Searchable: true},
		},
		items: []MediaItem{movie("tt0133093", "The Matrix")},
	}
	svc := testService(t, p, st)
	items, err := svc.Search(context.Background(), KindMovie, "matrix")
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(items) != 1 || items[0].Title != "The Matrix" {
		t.Fatalf("search returned %+v", items)
	}
	if _, err := svc.Search(context.Background(), KindMovie, "matrix"); err != nil {
		t.Fatalf("search again: %v", err)
	}
	if p.browses.Load() != 1 {
		t.Errorf("search hit the provider %d times, want 1 (second one cached)", p.browses.Load())
	}
}

func TestSearchEmptyQuery(t *testing.T) {
	svc := testService(t, &fakeProvider{id: "meta"}, newMemStore(time.Unix(1_700_000_000, 0)))
	if _, err := svc.Search(context.Background(), KindMovie, "  "); err == nil {
		t.Error("expected an error for an empty query")
	}
}

// A list of titles is answered from the cache at once, whatever state the
// details are in, and what is stale or missing is fetched behind it.
func TestCachedAnswersAtOnceAndRefreshesBehind(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series, full := severanceFixture()
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)
	id := browseSeries(t, svc)
	gate := p.hold()

	got, err := svc.Cached(context.Background(), []string{"unknown", id})
	if err != nil {
		t.Fatalf("cached: %v", err)
	}
	if len(got) != 1 || got[0].ID != id || len(got[0].Episodes) != 0 {
		t.Fatalf("cached = %+v, want the catalogue row alone", got)
	}
	close(gate)
	svc.items.Wait()
	if p.metas.Load() != 1 {
		t.Fatalf("meta fetched %d times, want 1", p.metas.Load())
	}
	if got, _ := svc.Cached(context.Background(), []string{id}); len(got) != 1 || len(got[0].Episodes) != 1 {
		t.Fatalf("background answer not cached: %+v", got)
	}
	svc.items.Wait()
	if p.metas.Load() != 1 {
		t.Errorf("fresh details fetched again: %d requests", p.metas.Load())
	}
}

func TestKnownDoesNotAskTheProvider(t *testing.T) {
	st := newMemStore(time.Unix(1_700_000_000, 0))
	series, full := severanceFixture()
	p := &fakeProvider{id: "meta", items: []MediaItem{series}, meta: &full}
	svc := testService(t, p, st)
	id := browseSeries(t, svc)
	for want, asked := range map[bool]string{true: id, false: "nobody"} {
		if got, err := svc.Known(context.Background(), asked); err != nil || got != want {
			t.Errorf("Known(%q) = %v, %v; want %v", asked, got, err, want)
		}
	}
	if p.metas.Load() != 0 {
		t.Errorf("Known asked the provider %d times", p.metas.Load())
	}
}
