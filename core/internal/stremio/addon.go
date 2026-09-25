// Package stremio talks the Stremio addon protocol, which is the widest
// available source of media links: a GET to /stream/{type}/{id}.json returns a
// list of streams. Everything structured we want (quality, codec, audio) is
// absent from that response and has to be parsed out of two free-text fields.
package stremio

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/egress"
	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// client is shared by every addon. Its limit is under the application's 20 s,
// so a slow addon costs its own results and not the whole answer.
var client = &http.Client{Timeout: 15 * time.Second, Transport: egress.Transport}

// maxResponse bounds what an addon's answer may take in memory. The longest
// real ones are Cinemeta's meta of a series with a thousand episodes, around
// 2 MiB; an addon that sends more is broken or hostile, and the timeout alone
// lets a fast one fill the machine's memory.
const maxResponse = 16 << 20

var (
	_ sources.Provider = (*Addon)(nil)
	_ catalog.Provider = (*Addon)(nil)
)

type Addon struct {
	id      string
	name    string
	baseURL string

	mu       sync.Mutex
	manifest *Manifest
}

// New builds a provider for one addon. baseURL is the configured addon root,
// e.g. https://torrentio.strem.fun/sort=qualitysize (trailing manifest.json is
// tolerated and stripped).
func New(id, name, baseURL string) *Addon {
	baseURL = strings.TrimSuffix(strings.TrimSpace(baseURL), "/manifest.json")
	return &Addon{
		id:      id,
		name:    name,
		baseURL: strings.TrimSuffix(baseURL, "/"),
	}
}

func (a *Addon) ID() string        { return a.id }
func (a *Addon) Name() string      { return a.name }
func (a *Addon) Namespace() string { return catalog.NamespaceIMDb }
func (a *Addon) BaseURL() string   { return a.baseURL }

// Manifest is what the addon last said about itself, fetched when it has
// never said anything. Keeping it current is the owner's job, in the
// background (addons.Service.Run): a manifest that expired on the way to a
// request would put a remote round trip in front of the home screen and take
// its rows away whenever the addon cannot be reached.
func (a *Addon) Manifest(ctx context.Context) (*Manifest, error) { return a.loadManifest(ctx) }

// RefreshManifest asks the addon again whatever the cache says. It is the
// one request that proves an address is alive: an addon is a URL to a
// manifest.json, and a URL that does not answer one is not an addon.
func (a *Addon) RefreshManifest(ctx context.Context) (*Manifest, error) {
	var m Manifest
	if err := a.getJSON(ctx, a.baseURL+"/manifest.json", &m); err != nil {
		return nil, err
	}
	if m.ID == "" {
		return nil, fmt.Errorf("stremio: %s answered without a manifest id", a.baseURL)
	}
	a.mu.Lock()
	a.manifest = &m
	a.mu.Unlock()
	return &m, nil
}

// PrimeManifest seeds the cache with a manifest fetched earlier — the copy
// the core keeps in its database — so that a core started without a network
// still knows what each addon is for.
func (a *Addon) PrimeManifest(m Manifest) {
	a.mu.Lock()
	a.manifest = &m
	a.mu.Unlock()
}

func (a *Addon) Rows(ctx context.Context) ([]catalog.Row, error) {
	m, err := a.loadManifest(ctx)
	if err != nil {
		return nil, err
	}
	rows := make([]catalog.Row, 0, len(m.Catalogs))
	for _, c := range m.Catalogs {
		rows = append(rows, catalogRow(a.id, c))
	}
	return rows, nil
}

func (a *Addon) Browse(ctx context.Context, req catalog.BrowseRequest) ([]catalog.MediaItem, error) {
	u := fmt.Sprintf("%s/catalog/%s/%s%s.json", a.baseURL, req.Kind, req.CatalogID, extraPath(req))
	var body struct {
		Metas []metaObject `json:"metas"`
	}
	if err := a.getJSON(ctx, u, &body); err != nil {
		return nil, err
	}
	out := make([]catalog.MediaItem, 0, len(body.Metas))
	for _, m := range body.Metas {
		out = append(out, m.toItem(false))
	}
	return out, nil
}

func (a *Addon) Meta(ctx context.Context, kind catalog.Kind, externalID string) (*catalog.MediaItem, error) {
	u := fmt.Sprintf("%s/meta/%s/%s.json", a.baseURL, kind, externalID)
	var body struct {
		Meta metaObject `json:"meta"`
	}
	if err := a.getJSON(ctx, u, &body); err != nil {
		return nil, err
	}
	item := body.Meta.toItem(true)
	return &item, nil
}

type streamResponse struct {
	Streams []struct {
		Name          string   `json:"name"`
		Title         string   `json:"title"`
		Description   string   `json:"description"`
		InfoHash      string   `json:"infoHash"`
		FileIdx       *int     `json:"fileIdx"`
		URL           string   `json:"url"`
		Sources       []string `json:"sources"`
		BehaviorHints struct {
			BingeGroup string `json:"bingeGroup"`
			Filename   string `json:"filename"`
			VideoSize  int64  `json:"videoSize"`
		} `json:"behaviorHints"`
	} `json:"streams"`
}

func (a *Addon) Find(ctx context.Context, q sources.Query) ([]sources.MediaSource, error) {
	if q.IMDbID == "" {
		return nil, fmt.Errorf("stremio: query needs an IMDb id")
	}
	id := q.IMDbID
	if q.Kind == catalog.KindSeries {
		id = fmt.Sprintf("%s:%d:%d", q.IMDbID, q.Season, q.Episode)
	}
	var body streamResponse
	if err := a.getJSON(ctx, fmt.Sprintf("%s/stream/%s/%s.json", a.baseURL, q.Kind, id), &body); err != nil {
		return nil, err
	}

	out := make([]sources.MediaSource, 0, len(body.Streams))
	for _, s := range body.Streams {
		text := s.Title
		if text == "" {
			text = s.Description
		}
		// The first line is the release name; the rest is the addon's own
		// rendering of seeders, size and tracker.
		name := firstLine(text)
		if name == "" {
			name = s.Name
		}
		ms := sources.MediaSource{
			ProviderID: a.id,
			RawName:    name,
			Release:    release.Parse(name),
			Seeders:    parseSeeders(text),
			Size:       s.BehaviorHints.VideoSize,
			Filename:   s.BehaviorHints.Filename,
			Tracker:    parseTracker(text),
			Languages:  parseFlagLanguages(text),
			BingeGroup: s.BehaviorHints.BingeGroup,
		}
		if len(ms.Languages) == 0 {
			ms.Languages = ms.Release.Languages
		}
		if ms.Size == 0 {
			ms.Size = parseSize(text)
		}
		switch {
		case s.InfoHash != "":
			ms.Locator = sources.Locator{
				Scheme:    "torrent",
				InfoHash:  strings.ToLower(s.InfoHash),
				FileIndex: s.FileIdx,
				Trackers:  trackers(s.Sources),
			}
		case s.URL != "":
			ms.Locator = sources.Locator{Scheme: "http", URL: s.URL}
		default:
			continue // nothing playable
		}
		out = append(out, ms)
	}
	return out, nil
}

var (
	reSeeders = regexp.MustCompile(`(?:👤|Seed(?:ers)?:?)\s*([\d,\.]+)`)
	reSize    = regexp.MustCompile(`(?i)(?:💾)?\s*([\d.,]+)\s*(GB|MB|GiB|MiB|TB|TiB)\b`)
	// The addon renders where it found the copy after a gear, on the same
	// line as seeders and size: "👤 154 💾 346.03 MB ⚙️ NyaaSi".
	reTracker = regexp.MustCompile(`⚙️?\s*([^\n|]+)`)
)

// flagLanguages maps the regional-indicator flags addons print for the
// languages a copy carries to language codes; Torrentio does not say which of
// them are the soundtrack and which are subtitles. A flag is a country and a
// language is not, but this is the convention every addon in this ecosystem
// uses, and the
// alternative is guessing the language from the release name — which is
// exactly what we already do and what these flags are better than.
var flagLanguages = map[string]string{
	"GB": "en", "US": "en", "RU": "ru", "UA": "uk", "FR": "fr", "DE": "de",
	"ES": "es", "MX": "es", "IT": "it", "PT": "pt", "BR": "pt", "JP": "ja",
	"KR": "ko", "CN": "zh", "TW": "zh", "PL": "pl", "TR": "tr", "NL": "nl",
	"SE": "sv", "NO": "no", "DK": "da", "FI": "fi", "CZ": "cs", "SK": "sk",
	"HU": "hu", "RO": "ro", "BG": "bg", "GR": "el", "IL": "he", "SA": "ar",
	"IN": "hi", "TH": "th", "VN": "vi", "ID": "id", "LT": "lt", "LV": "lv",
	"EE": "et", "RS": "sr", "HR": "hr", "IR": "fa",
}

func parseTracker(text string) string {
	m := reTracker.FindStringSubmatch(text)
	if m == nil {
		return ""
	}
	return strings.TrimSpace(m[1])
}

// parseFlagLanguages reads the flag emoji an addon prints for a copy's languages.
// Each flag is a pair of regional indicator symbols, which are just A-Z
// shifted into their own block.
func parseFlagLanguages(text string) []string {
	var out []string
	seen := map[string]bool{}
	runes := []rune(text)
	for i := 0; i+1 < len(runes); i++ {
		a, b := runes[i], runes[i+1]
		if a < 0x1F1E6 || a > 0x1F1FF || b < 0x1F1E6 || b > 0x1F1FF {
			continue
		}
		country := string([]rune{'A' + (a - 0x1F1E6), 'A' + (b - 0x1F1E6)})
		lang, ok := flagLanguages[country]
		if !ok || seen[lang] {
			i++
			continue
		}
		seen[lang] = true
		out = append(out, lang)
		i++
	}
	return out
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}

func parseSeeders(text string) int {
	m := reSeeders.FindStringSubmatch(text)
	if m == nil {
		return 0
	}
	n, err := strconv.Atoi(strings.NewReplacer(",", "", ".", "").Replace(m[1]))
	if err != nil {
		return 0
	}
	return n
}

func parseSize(text string) int64 {
	m := reSize.FindStringSubmatch(text)
	if m == nil {
		return 0
	}
	v, err := strconv.ParseFloat(strings.ReplaceAll(m[1], ",", ""), 64)
	if err != nil {
		return 0
	}
	unit := map[string]float64{
		"MB": 1 << 20, "MIB": 1 << 20,
		"GB": 1 << 30, "GIB": 1 << 30,
		"TB": 1 << 40, "TIB": 1 << 40,
	}[strings.ToUpper(m[2])]
	return int64(v * unit)
}

// trackers keeps only the tracker URLs from the addon's "sources" list, which
// also carries dht: entries the torrent client discovers on its own.
func trackers(src []string) []string {
	var out []string
	for _, s := range src {
		if v, ok := strings.CutPrefix(s, "tracker:"); ok {
			out = append(out, v)
		}
	}
	return out
}

type extraProp struct {
	Name    string   `json:"name"`
	Options []string `json:"options"`
}

type manifestCatalog struct {
	Type           string      `json:"type"`
	ID             string      `json:"id"`
	Name           string      `json:"name"`
	Extra          []extraProp `json:"extra"`
	ExtraSupported []string    `json:"extraSupported"`
	Genres         []string    `json:"genres"`
}

// Manifest is the part of an addon's manifest.json the core reads. The
// resources are what decide what an addon is for: the same URL serves
// catalogs, metadata, streams or subtitles depending on what it lists here,
// and the core never has to be told which.
type Manifest struct {
	ID          string            `json:"id"`
	Version     string            `json:"version"`
	Name        string            `json:"name"`
	Description string            `json:"description"`
	Logo        string            `json:"logo"`
	Resources   resourceList      `json:"resources"`
	Types       []string          `json:"types"`
	Catalogs    []manifestCatalog `json:"catalogs"`
}

// Provides reports whether the manifest lists a resource: "catalog", "meta",
// "stream" or "subtitles".
func (m *Manifest) Provides(resource string) bool {
	for _, r := range m.Resources {
		if r == resource {
			return true
		}
	}
	return false
}

// resourceList reads the manifest's resources, which the protocol allows as
// either a name ("stream") or an object ({"name": "stream", "types": [...]}),
// and keeps only the names; the object's other fields narrow what the addon
// answers for, which the core learns from the answer itself.
type resourceList []string

func (r *resourceList) UnmarshalJSON(b []byte) error {
	var raw []json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}
	out := make([]string, 0, len(raw))
	for _, entry := range raw {
		var name string
		if json.Unmarshal(entry, &name) == nil {
			out = append(out, name)
			continue
		}
		var object struct {
			Name string `json:"name"`
		}
		if err := json.Unmarshal(entry, &object); err != nil {
			return err
		}
		out = append(out, object.Name)
	}
	*r = out
	return nil
}

type metaObject struct {
	ID          string      `json:"id"`
	Type        string      `json:"type"`
	Name        string      `json:"name"`
	Description string      `json:"description"`
	Poster      string      `json:"poster"`
	Background  string      `json:"background"`
	Logo        string      `json:"logo"`
	Genres      []string    `json:"genres"`
	Cast        []string    `json:"cast"`
	Director    stringList  `json:"director"`
	Runtime     string      `json:"runtime"`
	IMDbRating  anyString   `json:"imdbRating"`
	MovieDBID   anyString   `json:"moviedb_id"`
	TVDBID      anyString   `json:"tvdb_id"`
	ReleaseInfo string      `json:"releaseInfo"`
	Videos      []metaVideo `json:"videos"`
}

type metaVideo struct {
	Season     int       `json:"season"`
	Episode    int       `json:"episode"`
	Number     int       `json:"number"`
	Rating     anyString `json:"rating"`
	Name       string    `json:"name"`
	Overview   string    `json:"overview"`
	Thumbnail  string    `json:"thumbnail"`
	Released   string    `json:"released"`
	FirstAired string    `json:"firstAired"`
}

// anyString accepts the JSON string-or-number mix Cinemeta actually ships:
// imdbRating is quoted ("8.7"), moviedb_id / tvdb_id are bare integers.
type anyString string

func (s *anyString) UnmarshalJSON(b []byte) error {
	if len(b) == 0 || string(b) == "null" {
		return nil
	}
	var str string
	if err := json.Unmarshal(b, &str); err == nil {
		*s = anyString(str)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(b, &n); err == nil {
		*s = anyString(n.String())
		return nil
	}
	return nil
}

// stringList accepts director as a string, an array, or null.
type stringList []string

func (s *stringList) UnmarshalJSON(b []byte) error {
	if len(b) == 0 || string(b) == "null" {
		return nil
	}
	var arr []string
	if err := json.Unmarshal(b, &arr); err == nil {
		*s = arr
		return nil
	}
	var str string
	if err := json.Unmarshal(b, &str); err == nil {
		if str != "" {
			*s = []string{str}
		}
		return nil
	}
	return nil
}

func (a *Addon) loadManifest(ctx context.Context) (*Manifest, error) {
	a.mu.Lock()
	m := a.manifest
	a.mu.Unlock()
	if m != nil {
		return m, nil
	}
	return a.RefreshManifest(ctx)
}

func (a *Addon) getJSON(ctx context.Context, rawURL string, dest any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", egress.UserAgent)
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	// An addon being installed has no id yet; its address is the name then.
	name := a.id
	if name == "" {
		name = rawURL
	}
	if resp.StatusCode != http.StatusOK {
		return &egress.StatusError{Provider: name, Status: resp.Status, Code: resp.StatusCode}
	}
	if err := json.NewDecoder(http.MaxBytesReader(nil, resp.Body, maxResponse)).Decode(dest); err != nil {
		return fmt.Errorf("stremio: decode %s: %w", name, err)
	}
	return nil
}

func catalogRow(providerID string, c manifestCatalog) catalog.Row {
	row := catalog.Row{
		ProviderID: providerID,
		ID:         c.ID,
		Kind:       catalog.Kind(c.Type),
		Name:       c.Name,
	}
	extras := c.Extra
	if len(extras) == 0 {
		// Pre-SDK manifests only list extra names: extraSupported: ["search","genre","skip"].
		for _, name := range c.ExtraSupported {
			extras = append(extras, extraProp{Name: name})
		}
	}
	for _, e := range extras {
		switch e.Name {
		case "genre":
			row.Genres = e.Options
			if len(row.Genres) == 0 {
				row.Genres = c.Genres
			}
		case "search":
			row.Searchable = true
		}
	}
	return row
}

// extraPath is the Stremio extraArgs segment: a querystring inside the path,
// keys in a fixed order so two equivalent BrowseRequests hit the same URL and
// therefore the same cache entry.
func extraPath(req catalog.BrowseRequest) string {
	var parts []string
	if req.Genre != "" {
		parts = append(parts, "genre="+escapeExtra(req.Genre))
	}
	if req.Search != "" {
		parts = append(parts, "search="+escapeExtra(req.Search))
	}
	if req.Skip > 0 {
		parts = append(parts, "skip="+strconv.Itoa(req.Skip))
	}
	if len(parts) == 0 {
		return ""
	}
	return "/" + strings.Join(parts, "&")
}

// escapeExtra percent-encodes a space as %20 rather than "+". Addons split
// this segment themselves and the ones that hand it to decodeURIComponent
// leave a "+" as a literal plus, so "the matrix" would search for "the+matrix".
func escapeExtra(v string) string {
	return strings.ReplaceAll(url.QueryEscape(v), "+", "%20")
}

func (m metaObject) toItem(withEpisodes bool) catalog.MediaItem {
	item := catalog.MediaItem{
		Kind:       catalog.Kind(m.Type),
		Title:      m.Name,
		Overview:   m.Description,
		Poster:     m.Poster,
		Background: m.Background,
		Logo:       m.Logo,
		Genres:     m.Genres,
		Cast:       m.Cast,
		Directors:  []string(m.Director),
		Runtime:    m.Runtime,
	}
	item.Year, item.YearEnd = parseReleaseInfo(m.ReleaseInfo)
	if r := string(m.IMDbRating); r != "" {
		item.IMDbRating, _ = strconv.ParseFloat(r, 64)
	}
	ids := catalog.ExternalIDs{}
	if m.ID != "" {
		ids[catalog.NamespaceIMDb] = m.ID
	}
	if s := string(m.MovieDBID); s != "" {
		ids[catalog.NamespaceTMDB] = s
	}
	if s := string(m.TVDBID); s != "" {
		ids[catalog.NamespaceTVDB] = s
	}
	if len(ids) > 0 {
		item.ExternalIDs = ids
	}
	if withEpisodes && len(m.Videos) > 0 {
		item.Episodes = make([]catalog.Episode, 0, len(m.Videos))
		for _, v := range m.Videos {
			n := v.Episode
			if n == 0 {
				n = v.Number
			}
			episode := catalog.Episode{
				Season:    v.Season,
				Number:    n,
				Title:     v.Name,
				Overview:  v.Overview,
				Thumbnail: v.Thumbnail,
				Released:  parseMetaTime(v.Released, v.FirstAired),
			}
			// Sent as a string, and as "0" when there is no rating at all.
			if r := string(v.Rating); r != "" {
				episode.Rating, _ = strconv.ParseFloat(r, 64)
			}
			item.Episodes = append(item.Episodes, episode)
		}
		sort.Slice(item.Episodes, func(i, j int) bool {
			if item.Episodes[i].Season != item.Episodes[j].Season {
				return item.Episodes[i].Season < item.Episodes[j].Season
			}
			return item.Episodes[i].Number < item.Episodes[j].Number
		})
		seasonOneStills(item.Episodes)
	}
	return item
}

// metahubStill is Cinemeta's episode still: metahub.space/<imdb>/<season>/<episode>/<size>.
var metahubStill = regexp.MustCompile(`^(https://episodes\.metahub\.space/[^/]+)/(\d+)/(\d+)/([^/]+)$`)

// seasonOneStills gives every metahub still after the first season a
// fallback in season one under the absolute episode number. Metahub follows
// TMDB, which numbers some series (anime above all: Re:Zero) as one long
// season, so their later seasons 404 there. Episodes must be sorted.
func seasonOneStills(episodes []catalog.Episode) {
	absolute := 0
	for i := range episodes {
		e := &episodes[i]
		if e.Season < 1 {
			continue
		}
		absolute++
		if e.Season == 1 {
			continue
		}
		if m := metahubStill.FindStringSubmatch(e.Thumbnail); m != nil {
			e.ThumbnailFallback = fmt.Sprintf("%s/1/%d/%s", m[1], absolute, m[4])
		}
	}
}

func parseReleaseInfo(s string) (year, yearEnd int) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, 0
	}
	// Cinemeta uses an en dash in ranges ("2008–2013", "2023–"); ASCII hyphen too.
	s = strings.NewReplacer("–", "-", "—", "-").Replace(s)
	start, end, found := strings.Cut(s, "-")
	year, _ = strconv.Atoi(strings.TrimSpace(start))
	if !found {
		return year, 0
	}
	yearEnd, _ = strconv.Atoi(strings.TrimSpace(end))
	return year, yearEnd
}

func parseMetaTime(released, firstAired string) time.Time {
	for _, s := range []string{released, firstAired} {
		if s == "" {
			continue
		}
		if t, err := time.Parse(time.RFC3339, s); err == nil {
			return t
		}
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			return t
		}
	}
	return time.Time{}
}
