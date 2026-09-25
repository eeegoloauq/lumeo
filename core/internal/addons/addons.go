// Package addons owns the list of installed addons: what the core reads
// catalogs, metadata, streams and subtitles from. An addon is a URL to a
// manifest.json, and the manifest is what says which of those it serves —
// the core is never told, it reads.
package addons

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/stremio"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

// Record is one addon as the store keeps it.
type Record struct {
	ID       string
	URL      string
	Name     string
	Enabled  bool
	Position int
	// Manifest is the last one fetched, as JSON, so that a core started
	// without a network still knows what each addon is for. Empty until the
	// addon has answered once.
	Manifest json.RawMessage
}

type Store interface {
	Addons(context.Context) ([]Record, error)
	// SeedAddons fills a table that has just been created and does nothing
	// on any later run.
	SeedAddons(context.Context, []Record) error
	PutAddon(context.Context, Record) error
	// PutAddons writes several records as one change.
	PutAddons(context.Context, []Record) error
	DeleteAddon(context.Context, string) error
}

// Seed is an addon a new database starts with.
type Seed struct {
	ID   string
	Name string
	URL  string
}

// Addon is one installed addon as a settings screen sees it.
type Addon struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	URL     string `json:"url"`
	Enabled bool   `json:"enabled"`
	// Resources is what the manifest lists: "catalog", "meta", "stream",
	// "subtitles". Empty while the addon has never answered.
	Resources   []string `json:"resources"`
	Description string   `json:"description,omitempty"`
	Version     string   `json:"version,omitempty"`
	Logo        string   `json:"logo,omitempty"`
	// Error is why there is no manifest, when there is none.
	Error string `json:"error,omitempty"`
}

// Patch is what a client may change about an installed addon.
type Patch struct {
	Enabled  *bool `json:"enabled"`
	Position *int  `json:"position"`
}

var (
	ErrNotFound = errors.New("addon not found")
	// ErrInvalid wraps every refusal of an Add or a Patch; the message on it
	// is written for the person who typed the value.
	ErrInvalid = errors.New("invalid addon")
)

type invalidError struct{ message string }

func (e invalidError) Error() string { return e.message }
func (e invalidError) Unwrap() error { return ErrInvalid }

func invalidf(format string, args ...any) error {
	return invalidError{message: fmt.Sprintf(format, args...)}
}

const (
	// refreshEvery is how often the installed addons are asked for their
	// manifests. What an addon serves changes with its releases, so the
	// answer is kept for requests to use as it is and refreshed behind them.
	refreshEvery = time.Hour
	// retryEvery bounds how often a manifest that has never arrived is asked
	// for again on the way to answering a request.
	retryEvery = time.Minute
	// retryWithin bounds how long that request waits for it: long enough for
	// an addon that is there, short enough that one that is not does not
	// stall the home screen for the protocol client's full timeout.
	retryWithin = 5 * time.Second
)

// entry is one installed addon. The record and the protocol client are
// replaced together, under the lock, when the addon is reconfigured; a
// fetch that started against the old client finds out by comparing.
type entry struct {
	rec      Record
	addon    *stremio.Addon
	manifest *stremio.Manifest
	err      error
}

type Service struct {
	store Store
	log   *slog.Logger

	mu        sync.RWMutex
	entries   []*entry
	retriedAt time.Time
}

func New(store Store, log *slog.Logger) *Service {
	return &Service{store: store, log: log}
}

// Load reads the installed list. A database that did not have one takes the
// seed: the environment is the default, what is stored wins, and an
// installed copy started by a desktop launcher with no environment at all
// still has the three addons the MVP runs on.
func (s *Service) Load(ctx context.Context, seed []Seed) error {
	records := make([]Record, 0, len(seed))
	taken := make(map[string]bool, len(seed))
	for i, a := range seed {
		id := a.ID
		for n := 2; taken[id]; n++ {
			id = fmt.Sprintf("%s-%d", a.ID, n)
		}
		taken[id] = true
		records = append(records, Record{
			ID:       id,
			URL:      stremio.New(id, a.Name, a.URL).BaseURL(),
			Name:     a.Name,
			Enabled:  true,
			Position: i,
		})
	}
	if err := s.store.SeedAddons(ctx, records); err != nil {
		return err
	}
	records, err := s.store.Addons(ctx)
	if err != nil {
		return err
	}

	entries := make([]*entry, 0, len(records))
	for _, rec := range records {
		e := &entry{rec: rec, addon: stremio.New(rec.ID, rec.Name, rec.URL)}
		if len(rec.Manifest) > 0 {
			var m stremio.Manifest
			if err := json.Unmarshal(rec.Manifest, &m); err != nil {
				s.log.Warn("stored addon manifest unreadable", "addon", rec.ID, "err", err)
			} else {
				e.manifest = &m
				e.addon.PrimeManifest(m)
			}
		}
		entries = append(entries, e)
	}
	s.mu.Lock()
	s.entries = entries
	s.mu.Unlock()
	return nil
}

// fetch is one manifest request in flight: the entry it is for and the
// client it was started against.
type fetch struct {
	e     *entry
	addon *stremio.Addon
}

// Run refreshes the manifests now and every refreshEvery after, until ctx
// ends.
func (s *Service) Run(ctx context.Context) {
	ticker := time.NewTicker(refreshEvery)
	defer ticker.Stop()
	for {
		s.Refresh(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Refresh asks every addon for its manifest again and keeps what answers.
// An addon that does not answer keeps the manifest it had: a provider that
// is down for a minute has not changed what it is for.
func (s *Service) Refresh(ctx context.Context) {
	s.mu.RLock()
	fetches := make([]fetch, 0, len(s.entries))
	for _, e := range s.entries {
		fetches = append(fetches, fetch{e, e.addon})
	}
	s.mu.RUnlock()
	s.refresh(ctx, fetches)
}

func (s *Service) refresh(ctx context.Context, fetches []fetch) {
	var wg sync.WaitGroup
	for _, f := range fetches {
		wg.Add(1)
		go func() {
			defer wg.Done()
			m, err := f.addon.RefreshManifest(ctx)
			s.mu.Lock()
			defer s.mu.Unlock()
			// Removed, or reconfigured, while the request was out: the
			// answer is about an addon that is no longer installed. The
			// entry itself is looked for, not its id — an addon removed
			// and another installed under the same name is a new entry
			// with the old id.
			if !s.has(f.e) || f.e.addon != f.addon {
				return
			}
			if err != nil {
				f.e.err = err
				s.log.Warn("addon manifest", "addon", f.e.rec.ID, "err", err)
				return
			}
			f.e.err = nil
			// The write happens under the lock on purpose: outside it, a
			// Remove could delete the row between this answer arriving and
			// its being written, and the write would bring the addon back.
			if err := s.remember(ctx, f.e, m); err != nil {
				s.log.Warn("storing addon manifest", "addon", f.e.rec.ID, "err", err)
			}
		}()
	}
	wg.Wait()
}

// remember keeps a fetched manifest in the store and, once that has
// succeeded, on the entry. The caller holds the lock.
func (s *Service) remember(ctx context.Context, e *entry, m *stremio.Manifest) error {
	rec := e.rec
	if m.Name != "" {
		rec.Name = m.Name
	}
	rec.Manifest, _ = json.Marshal(m)
	if err := s.store.PutAddon(ctx, rec); err != nil {
		return err
	}
	e.rec = rec
	e.manifest = m
	return nil
}

// retryMissing asks again, not more than once a minute and not for longer
// than a few seconds, for the manifests that have never arrived. It waits
// for the answer rather than fetching in the background because the first
// request after a fresh start is the home screen asking for its catalogue,
// and an empty answer there is an empty screen until it is reopened. A
// laptop that starts the core before it has found the Wi-Fi is the other
// case: the addons should not stay useless until it is restarted.
func (s *Service) retryMissing() {
	s.mu.Lock()
	var missing []fetch
	for _, e := range s.entries {
		if e.rec.Enabled && e.manifest == nil {
			missing = append(missing, fetch{e, e.addon})
		}
	}
	if len(missing) == 0 || time.Since(s.retriedAt) < retryEvery {
		s.mu.Unlock()
		return
	}
	s.retriedAt = time.Now()
	s.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), retryWithin)
	defer cancel()
	s.refresh(ctx, missing)
}

func (s *Service) List() []Addon {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]Addon, 0, len(s.entries))
	for _, e := range s.entries {
		out = append(out, e.view())
	}
	return out
}

// view is the entry as the API shows it. The caller holds the lock.
func (e *entry) view() Addon {
	a := Addon{
		ID:        e.rec.ID,
		Name:      e.rec.Name,
		URL:       e.rec.URL,
		Enabled:   e.rec.Enabled,
		Resources: []string{},
	}
	if m := e.manifest; m != nil {
		a.Resources = append(a.Resources, m.Resources...)
		a.Description = m.Description
		a.Version = m.Version
		a.Logo = m.Logo
	}
	if e.err != nil {
		a.Error = e.err.Error()
	}
	return a
}

// Add installs the addon at a URL, or reconfigures the one already installed
// from it: an addon's /configure page hands back a new URL with the same
// manifest id, and pasting that in is meant to change the addon, not to
// install it twice. The manifest is fetched before anything is stored, which
// is the check that the address is alive. The second result is whether a
// new addon was installed.
func (s *Service) Add(ctx context.Context, rawURL string) (Addon, bool, error) {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return Addon{}, false, invalidf("the address must start with http:// or https://")
	}
	probe := stremio.New("", "", u.String())
	m, err := probe.RefreshManifest(ctx)
	if err != nil {
		return Addon{}, false, invalidf("no addon answered there: %v", err)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	for _, e := range s.entries {
		if e.manifest == nil || e.manifest.ID != m.ID {
			continue
		}
		rec := e.rec
		rec.URL = probe.BaseURL()
		if m.Name != "" {
			rec.Name = m.Name
		}
		rec.Manifest, _ = json.Marshal(m)
		if err := s.store.PutAddon(ctx, rec); err != nil {
			return Addon{}, false, err
		}
		e.rec = rec
		e.addon = stremio.New(rec.ID, rec.Name, rec.URL)
		e.addon.PrimeManifest(*m)
		e.manifest = m
		e.err = nil
		return e.view(), false, nil
	}

	position := 0
	for _, e := range s.entries {
		if e.rec.Position >= position {
			position = e.rec.Position + 1
		}
	}
	rec := Record{
		ID:       s.uniqueID(m.Name),
		URL:      probe.BaseURL(),
		Name:     m.Name,
		Enabled:  true,
		Position: position,
	}
	rec.Manifest, _ = json.Marshal(m)
	if err := s.store.PutAddon(ctx, rec); err != nil {
		return Addon{}, false, err
	}
	e := &entry{
		rec:      rec,
		addon:    stremio.New(rec.ID, rec.Name, rec.URL),
		manifest: m,
	}
	e.addon.PrimeManifest(*m)
	s.entries = append(s.entries, e)
	return e.view(), true, nil
}

// Update changes what a client may change. Nothing in memory moves until
// the store has taken the change, and the change is one write however many
// fields it touches: a PATCH the database refused is a list that did not
// change, in the answer and in the next request alike.
func (s *Service) Update(ctx context.Context, id string, patch Patch) (Addon, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	index := s.index(id)
	if index < 0 {
		return Addon{}, ErrNotFound
	}
	e := s.entries[index]
	changed := e.rec
	if patch.Enabled != nil {
		changed.Enabled = *patch.Enabled
	}

	order := s.entries
	if patch.Position != nil {
		to := *patch.Position
		if to < 0 || to >= len(s.entries) {
			return Addon{}, invalidf("position must be between 0 and %d", len(s.entries)-1)
		}
		order = make([]*entry, 0, len(s.entries))
		order = append(order, s.entries[:index]...)
		order = append(order, s.entries[index+1:]...)
		order = append(order[:to], append([]*entry{e}, order[to:]...)...)
	}

	records := make([]Record, 0, len(order))
	for i, other := range order {
		rec := other.rec
		if other == e {
			rec = changed
		}
		rec.Position = i
		records = append(records, rec)
	}
	if err := s.store.PutAddons(ctx, records); err != nil {
		return Addon{}, err
	}
	for i, other := range order {
		other.rec = records[i]
	}
	s.entries = order
	return e.view(), nil
}

func (s *Service) Remove(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	index := s.index(id)
	if index < 0 {
		return ErrNotFound
	}
	if err := s.store.DeleteAddon(ctx, id); err != nil {
		return err
	}
	s.entries = append(s.entries[:index:index], s.entries[index+1:]...)
	return nil
}

// Sources are the enabled addons whose manifest lists streams, in list
// order — which is the order the source list keeps between two copies that
// rank the same.
func (s *Service) Sources() []sources.Provider {
	var out []sources.Provider
	for _, a := range s.providing("stream") {
		out = append(out, a)
	}
	return out
}

// Metadata are the enabled addons that serve catalogs or items; the first
// is the one a home screen is built from.
func (s *Service) Metadata() []catalog.Provider {
	var out []catalog.Provider
	for _, a := range s.providing("catalog", "meta") {
		out = append(out, a)
	}
	return out
}

func (s *Service) Subtitles() []subtitles.Provider {
	var out []subtitles.Provider
	for _, a := range s.providing("subtitles") {
		out = append(out, a)
	}
	return out
}

// providing hands out the protocol clients, not the entries: an entry is
// only read under the lock, and a client is safe to use after it.
func (s *Service) providing(resources ...string) []*stremio.Addon {
	s.retryMissing()
	s.mu.RLock()
	defer s.mu.RUnlock()
	var out []*stremio.Addon
	for _, e := range s.entries {
		if !e.rec.Enabled || e.manifest == nil {
			continue
		}
		for _, r := range resources {
			if e.manifest.Provides(r) {
				out = append(out, e.addon)
				break
			}
		}
	}
	return out
}

// has reports whether an entry is still installed. The caller holds the
// lock.
func (s *Service) has(e *entry) bool {
	for _, other := range s.entries {
		if other == e {
			return true
		}
	}
	return false
}

// index finds an entry by id. The caller holds the lock.
func (s *Service) index(id string) int {
	for i, e := range s.entries {
		if e.rec.ID == id {
			return i
		}
	}
	return -1
}

var notSlug = regexp.MustCompile(`[^a-z0-9]+`)

// uniqueID makes an id out of the addon's name — "torrentio", not
// "com.stremio.torrentio.addon", because the id is what the client passes
// back and what a catalog row is filed under. The caller holds the lock.
func (s *Service) uniqueID(name string) string {
	base := strings.Trim(notSlug.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if base == "" {
		base = "addon"
	}
	id := base
	for n := 2; s.index(id) >= 0; n++ {
		id = fmt.Sprintf("%s-%d", base, n)
	}
	return id
}
