package subtitles

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/egress"
)

// ErrUnknownToken means the client asked for a subtitle the core never handed
// out, or handed out long enough ago that it has forgotten.
var ErrUnknownToken = errors.New("subtitles: unknown subtitle")

const (
	// maxFileSize is generous for text and small enough that a provider
	// answering with something else cannot fill memory.
	maxFileSize = 8 << 20
	// tokenTTL outlives watching a film with the subtitle picker open.
	tokenTTL   = 12 * time.Hour
	maxTokens  = 1024
	fetchLimit = 30 * time.Second
)

// Service is the subtitle side of the core: providers behind one lookup, and
// the only thing that ever fetches a subtitle file.
type Service struct {
	providers func() []Provider
	// Languages is the preference order used when a request does not state
	// one of its own.
	Languages []string
	client    *http.Client
	log       *slog.Logger

	mu     sync.Mutex
	tokens map[string]tokenEntry
	now    func() time.Time
}

type tokenEntry struct {
	sub Subtitle
	at  time.Time
}

// NewService takes the providers as a function: the list is edited on a
// settings page while the core runs.
func NewService(providers func() []Provider, languages []string, log *slog.Logger) *Service {
	return &Service{
		providers: providers,
		Languages: languages,
		// A subtitle file's address is the provider's text: public ones only.
		client: &http.Client{Timeout: fetchLimit, Transport: egress.Addressed},
		log:    log,
		tokens: make(map[string]tokenEntry),
		now:    time.Now,
	}
}

// Find asks every provider and returns one ranked list. A provider that is
// down costs its own results and nothing else — subtitles are an addition to
// playback that has already started, never a reason to interrupt it.
func (s *Service) Find(ctx context.Context, q Query) []Subtitle {
	if len(q.Languages) == 0 {
		q.Languages = s.Languages
	}
	var all []Subtitle
	for _, p := range s.providers() {
		found, err := p.Subtitles(ctx, q)
		if err != nil {
			s.log.Warn("subtitle provider failed", "provider", p.ID(), "err", err)
			continue
		}
		all = append(all, found...)
	}
	rank(all, q)
	all = dedupe(all)
	for i := range all {
		all[i].URL = "/api/v1/subtitles/" + s.mint(all[i])
	}
	return all
}

// Text is one subtitle file, as the player should receive it.
type Text struct {
	Format string
	Body   []byte
}

// Fetch downloads the file behind a token and hands back UTF-8. Doing this in
// the core rather than in the player is what fixes the oldest problem in
// subtitles: half of what these databases hold is single-byte text from
// before Unicode, and a player handed it raw shows mojibake.
func (s *Service) Fetch(ctx context.Context, token string) (Text, error) {
	s.mu.Lock()
	entry, ok := s.tokens[token]
	s.mu.Unlock()
	if !ok || s.now().Sub(entry.at) > tokenTTL {
		return Text{}, ErrUnknownToken
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, entry.sub.SourceURL, nil)
	if err != nil {
		return Text{}, err
	}
	req.Header.Set("User-Agent", egress.UserAgent)
	resp, err := s.client.Do(req)
	if err != nil {
		return Text{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Text{}, &egress.StatusError{Provider: entry.sub.ProviderID, Status: resp.Status, Code: resp.StatusCode}
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxFileSize+1))
	if err != nil {
		return Text{}, err
	}
	if len(body) > maxFileSize {
		return Text{}, errors.New("subtitles: file is implausibly large for text")
	}
	body, err = decompress(body)
	if err != nil {
		return Text{}, err
	}
	return Text{
		Format: format(entry.sub, body),
		Body:   toUTF8(body, entry.sub.Encoding, entry.sub.Language),
	}, nil
}

// mint gives a subtitle an id of ours. The provider's URL stays inside the
// core: an endpoint that fetched whatever address it was handed would be an
// open proxy into whatever the core can reach, which on a home server is the
// rest of the home network.
func (s *Service) mint(sub Subtitle) string {
	sum := sha256.Sum256([]byte(sub.ProviderID + "\x00" + sub.SourceURL))
	token := hex.EncodeToString(sum[:12])

	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	s.tokens[token] = tokenEntry{sub: sub, at: now}
	if len(s.tokens) <= maxTokens {
		return token
	}
	for k, v := range s.tokens {
		if now.Sub(v.at) > tokenTTL {
			delete(s.tokens, k)
		}
	}
	// Still over the cap: drop the oldest until it fits. Losing a token only
	// means the client has to look the list up again.
	for len(s.tokens) > maxTokens {
		oldest, at := "", now
		for k, v := range s.tokens {
			if !v.at.After(at) {
				oldest, at = k, v.at
			}
		}
		if oldest == "" || oldest == token {
			break
		}
		delete(s.tokens, oldest)
	}
	return token
}

// rank puts what the viewer is most likely to pick first: their languages in
// the order they asked for them, and inside a language the copy timed for the
// file being played.
//
// Language comes before everything, hash match included: subtitles in a
// language nobody in the room reads are not a better answer for being an
// exact one.
func rank(subs []Subtitle, q Query) {
	prefs := make(map[string]int, len(q.Languages))
	for i, lang := range q.Languages {
		if _, seen := prefs[lang]; !seen {
			prefs[lang] = i
		}
	}
	sort.SliceStable(subs, func(i, j int) bool {
		pi, pj := languageRank(subs[i].Language, prefs), languageRank(subs[j].Language, prefs)
		if pi != pj {
			return pi < pj
		}
		if subs[i].Language != subs[j].Language {
			return subs[i].Language < subs[j].Language
		}
		if subs[i].HashMatch != subs[j].HashMatch {
			return subs[i].HashMatch
		}
		return releaseScore(subs[i].Name, q) > releaseScore(subs[j].Name, q)
	})
}

func languageRank(lang string, prefs map[string]int) int {
	if i, ok := prefs[lang]; ok {
		return i
	}
	// A regional variant satisfies a preference for the language ("pt-BR"
	// when "pt" was asked for), just not as well as an exact answer.
	if base, _, ok := strings.Cut(lang, "-"); ok {
		if i, ok := prefs[base]; ok {
			return i
		}
	}
	return len(prefs)
}

// releaseScore is how much a subtitle's own name looks like the release being
// played. The group is the strongest of these: two encodes by the same group
// share timings far more often than two encodes of the same resolution.
func releaseScore(name string, q Query) int {
	if name == "" {
		return 0
	}
	lower := strings.ToLower(name)
	if q.ReleaseName != "" && strings.Contains(lower, strings.ToLower(strings.TrimSuffix(q.ReleaseName, ".mkv"))) {
		return 10
	}
	score := 0
	if g := q.Release.Group; g != "" && strings.Contains(lower, strings.ToLower(g)) {
		score += 4
	}
	if r := q.Release.Resolution; r != "" && strings.Contains(lower, strings.ToLower(r)) {
		score += 2
	}
	if src := q.Release.Source; src != "" && strings.Contains(lower, strings.ToLower(src)) {
		score += 2
	}
	return score
}

// dedupe drops what the picker would show twice: the same file from two
// providers indexing one database, and the same upload stored under several
// ids, which is common enough in OpenSubtitles to be the usual case. It runs
// after ranking, so the copy that survives is the best-placed one.
func dedupe(subs []Subtitle) []Subtitle {
	seen := make(map[string]bool, len(subs))
	out := subs[:0]
	for _, sub := range subs {
		if sub.SourceURL == "" {
			continue
		}
		key := sub.SourceURL
		if sub.Name != "" {
			key = sub.ProviderID + "|" + sub.Language + "|" + strings.ToLower(sub.Name)
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, sub)
	}
	return out
}
