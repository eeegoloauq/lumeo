package api

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/egress"
	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// handleSources fans out to every provider and returns one merged, ranked list.
// Ranking is deliberately crude for now: the client shows the list, and the
// "smart default" that decides what Play uses lives here once we know what
// people actually pick.
func (s *Server) handleSources(w http.ResponseWriter, r *http.Request) {
	params := r.URL.Query()
	q := sources.Query{
		Kind:   kindOr(params.Get("kind"), catalog.KindMovie),
		IMDbID: params.Get("imdb"),
	}
	q.Season, _ = strconv.Atoi(params.Get("season"))
	q.Episode, _ = strconv.Atoi(params.Get("episode"))

	// The client browses in our ids and should never have to know that the
	// source providers speak IMDb; it passes item=, we translate.
	itemID := params.Get("item")
	if itemID != "" {
		imdbID, kind, ok := s.resolveItem(w, r, itemID)
		if !ok {
			return
		}
		q.IMDbID, q.Kind = imdbID, kind
	}
	if q.IMDbID == "" {
		writeError(w, http.StatusBadRequest, "item or imdb parameter is required")
		return
	}

	providers := s.sources()
	found := make([][]sources.MediaSource, len(providers))
	errs := make([]error, len(providers))
	var wg sync.WaitGroup
	for i, p := range providers {
		wg.Go(func() { found[i], errs[i] = p.Find(r.Context(), q) })
	}
	wg.Wait()

	all := []sources.MediaSource{}
	failed := []failedProvider{}
	for i, p := range providers {
		if errs[i] != nil {
			// One dead addon must not empty the list, and an empty list must
			// say whether a provider refused rather than had no copies.
			s.log.Warn("provider failed", "provider", p.ID(), "err", errs[i])
			failed = append(failed, failure(p.Name(), errs[i]))
			continue
		}
		all = append(all, found[i]...)
	}
	// What is on disk is a copy whether or not a provider lists it today: a
	// file opened from this machine never is, and a download stays playable
	// while the addon that found it refuses (Torrentio's 403).
	if itemID != "" && s.downloads != nil {
		for _, row := range s.downloads.List(r.Context()) {
			if row.ItemID != itemID || row.Season != q.Season || row.Episode != q.Episode ||
				row.State == acquire.StateFailed || listed(all, row.Locator) {
				continue
			}
			// A local file that is not done is missing, and nothing can fetch it again.
			if row.Locator.Scheme == "file" && row.State != acquire.StateDone {
				continue
			}
			src := sources.MediaSource{
				ProviderID: "local",
				RawName:    row.Name,
				Release:    release.Parse(row.Name),
				Size:       row.Size,
				Filename:   row.Name,
				Locator:    row.Locator,
			}
			if row.Locator.Scheme == "file" {
				src.Tracker = "This computer"
			}
			all = append(all, src)
		}
	}
	subs, audio := s.viewerLanguages(r.Context())
	rankSources(all, subs, audio)
	listed := s.preferKnown(r.Context(), itemID, all)
	// providers is how many source addons were asked: with none, an empty list
	// means "add one", not "no copies".
	writeJSON(w, http.StatusOK, map[string]any{"sources": listed, "failed": failed, "providers": len(providers)})
}

func listed(all []sources.MediaSource, loc sources.Locator) bool {
	for _, src := range all {
		if src.Locator.Same(loc) {
			return true
		}
	}
	return false
}

type failedProvider struct {
	Provider string `json:"provider"`
	Reason   string `json:"reason"`
	// Status is the HTTP status a provider refused with, 0 when it did not
	// answer: the client says a 403 as a block and a 503 as an outage.
	Status int `json:"status,omitempty"`
}

// failure is what the user is shown: the status a provider refused with, or
// that it did not answer.
func failure(provider string, err error) failedProvider {
	if se, ok := errors.AsType[*egress.StatusError](err); ok {
		return failedProvider{Provider: provider, Reason: se.Status, Status: se.Code}
	}
	return failedProvider{Provider: provider, Reason: "no answer"}
}

// minStreamableSeeders is where "there is a swarm" starts. The number is not
// about download time: with too few peers the reader outruns the pieces and
// playback stalls, which is the one thing this product must not do.
const minStreamableSeeders = 8

// rankSources decides what Play uses when nobody chooses, which is the point
// of the whole ranked list: health first, then language, then quality.
//
// Resolution alone is the wrong answer and the reason this exists — a 56 GB
// remux with three seeders wins on resolution and cannot be watched. So a
// source that has a swarm always outranks one that does not, and only inside
// those groups does a copy the viewer can follow beat one they cannot, and
// bigger and sharper win after that. A 1080p raw without subtitles is worse
// than a 720p copy with them.
func rankSources(all []sources.MediaSource, subs, audio []string) {
	sort.SliceStable(all, func(i, j int) bool {
		hi, hj := all[i].Seeders >= minStreamableSeeders, all[j].Seeders >= minStreamableSeeders
		if hi != hj {
			return hi
		}
		li, lj := carriesAny(all[i], subs, audio), carriesAny(all[j], subs, audio)
		if li != lj {
			return li
		}
		ri, rj := resolutionRank(all[i].Release.Resolution), resolutionRank(all[j].Release.Resolution)
		if ri != rj {
			return ri > rj
		}
		return all[i].Seeders > all[j].Seeders
	})
}

// carriesAny reports whether a copy has one of the viewer's languages
// somewhere. The provider's languages do not say whether a language is the
// soundtrack or a subtitle track (a Crunchyroll rip with Japanese audio is
// flagged English, Russian, Spanish...), so this can only ask "is it there".
// A "Multi Subs" copy counts for a viewer who wants subtitles: it usually
// names no languages, and what it carries is every track the streaming
// service had.
func carriesAny(src sources.MediaSource, subs, audio []string) bool {
	if src.Release.MultiSub && len(subs) > 0 {
		return true
	}
	return slices.ContainsFunc(src.Languages, func(have string) bool {
		return slices.Contains(subs, have) || slices.Contains(audio, have)
	})
}

// viewerLanguages is the viewer's subtitle and audio languages as the bare
// ISO 639-1 the providers use: "pt-BR" is "pt" to a flag.
func (s *Server) viewerLanguages(ctx context.Context) (subs, audio []string) {
	if s.prefs == nil {
		return nil, nil
	}
	prefs, err := s.prefs.Get(ctx)
	if err != nil {
		s.log.Warn("reading language preferences failed", "err", err)
		return nil, nil
	}
	return baseLanguages(prefs.SubtitleLanguages), baseLanguages(prefs.AudioLanguages)
}

func baseLanguages(tags []string) []string {
	out := make([]string, 0, len(tags))
	for _, tag := range tags {
		base, _, _ := strings.Cut(strings.ToLower(tag), "-")
		out = append(out, base)
	}
	return out
}

// listedSource is a copy as the sources list shows it: the provider's
// MediaSource plus what this library knows about it. Kept off MediaSource,
// which the client sends back to start a download and which is stored with
// it, where these facts would go stale.
type listedSource struct {
	sources.MediaSource
	// Local is "done" for a copy on disk, "partial" for one started and not
	// finished.
	Local string `json:"local,omitempty"`
	// LastUsed is the pack started last time for this title.
	LastUsed bool `json:"lastUsed,omitempty"`
}

// preferKnown moves ahead of the ranking what this library already chose: a
// copy already on disk first — finished before one still arriving — then a
// copy from the pack started last time for this title. The ranking only
// decides among strangers; a finished download passed over for a fresh one
// was the ranking deciding for a viewer who had already decided.
func (s *Server) preferKnown(ctx context.Context, itemID string, all []sources.MediaSource) []listedSource {
	var binge string
	if s.progress != nil && itemID != "" {
		choice, err := s.progress.Choice(ctx, itemID)
		if err != nil {
			s.log.Warn("reading the source choice failed", "item", itemID, "err", err)
		}
		binge = choice.BingeGroup
	}
	listed := make([]listedSource, len(all))
	for i, src := range all {
		listed[i] = listedSource{MediaSource: src, LastUsed: binge != "" && src.BingeGroup == binge}
		if s.downloads != nil {
			if d, ok := s.downloads.Find(ctx, src.Locator); ok && d.State != acquire.StateFailed {
				listed[i].Local = "partial"
				if d.State == acquire.StateDone {
					listed[i].Local = "done"
				}
			}
		}
	}
	sort.SliceStable(listed, func(i, j int) bool { return listed[i].known() < listed[j].known() })
	return listed
}

func (l listedSource) known() int {
	switch {
	case l.Local == "done":
		return 0
	case l.Local == "partial":
		return 1
	case l.LastUsed:
		return 2
	}
	return 3
}

func resolutionRank(res string) int {
	switch res {
	case "4320p":
		return 5
	case "2160p":
		return 4
	case "1440p":
		return 3
	case "1080p":
		return 2
	case "720p":
		return 1
	default:
		return 0
	}
}
