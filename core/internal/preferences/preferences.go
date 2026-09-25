// Package preferences owns settings shared by every client of the core.
package preferences

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

// Preferences is the document every client reads and patches. A field here
// is a choice that holds on the next machine too; anything that is a fact
// about one machine (volume, which core to talk to) belongs to the client.
type Preferences struct {
	SubtitleLanguages []string `json:"subtitleLanguages"` // ISO 639-1 with an optional region, best first
	// AudioLanguages is the same list for the soundtrack. Empty means the
	// file's own default track, which is what a viewer with no preference
	// would have got from any player.
	AudioLanguages []string `json:"audioLanguages"`
	// SubtitleMode is when a subtitle track is switched on without being
	// asked for: "always" for the first preferred language the file or the
	// database has, "foreign" only when the soundtrack is not in one of the
	// subtitle languages, "manual" for none until one is picked.
	SubtitleMode string `json:"subtitleMode"`
	// SubtitleScale and SubtitlePosition are mpv's sub-scale and sub-pos: 1
	// is the size mpv draws by default, and 100 sits the line on the bottom
	// edge of the picture, with lower numbers lifting it.
	SubtitleScale    float64 `json:"subtitleScale"`
	SubtitlePosition int     `json:"subtitlePosition"`
	// SubtitleBackground is what sits behind the text: "none" is mpv's
	// outline alone, "shadow" adds a drop shadow, "box" a dark box.
	SubtitleBackground string `json:"subtitleBackground"`
	// SubtitleColor is the colour of the text, by name: each client maps it
	// to the shade it draws.
	SubtitleColor string `json:"subtitleColor"`
	// SubtitleKeepStyling leaves a styled (ASS) track its own fonts and
	// colours; off, the size, colour and background above win over them.
	SubtitleKeepStyling bool   `json:"subtitleKeepStyling"`
	EpisodeArtwork      string `json:"episodeArtwork"`
	// Accent is the one colour the interface spends on what to press and how
	// far along something is.
	Accent string `json:"accent"`
	// Keep is how long a download stays once it is watched: "watched" frees
	// it then, "days" KeepDays later, "forever" never. A download nobody
	// finished is never freed by it.
	Keep     string `json:"keep"`
	KeepDays int    `json:"keepDays"`
	// DiskLimit is the ceiling in bytes on what downloads take, 0 for none.
	// Over it, watched downloads go, the longest watched first, whatever Keep
	// says; unwatched ones stay, so a file larger than the ceiling stays
	// until it is watched.
	DiskLimit int64 `json:"diskLimit"`
	// Prefetch starts the next episode once the one playing is on disk,
	// when it fits inside DiskLimit and the free disk.
	Prefetch bool `json:"prefetch"`
	// NextCountdown is how many seconds the last frame of an episode is held,
	// counting down, before the next one starts by itself; 0 means it waits
	// for a press. Credits the file marks as a chapter are the countdown
	// themselves: the next episode starts when they end.
	NextCountdown int `json:"nextCountdown"`
	// NextNotice is how many seconds before the end of an episode the card
	// offering the next one appears.
	NextNotice int `json:"nextNotice"`
	// SeekStep is the jump of the arrow keys, in seconds.
	SeekStep int `json:"seekStep"`
	// DownloadDir is where new downloads go; empty is the core's own place
	// in its data directory. Downloads already made stay where they are.
	DownloadDir string `json:"downloadDir"`
	// Seed keeps a torrent uploading once it has everything it was asked
	// for. Off, one still fetching still trades with its peers: a client
	// that gives nothing back is choked.
	Seed bool `json:"seed"`
	// UploadLimit and DownloadLimit cap the torrent client as a whole, in
	// bytes per second; 0 is no cap.
	UploadLimit   int64 `json:"uploadLimit"`
	DownloadLimit int64 `json:"downloadLimit"`
}

// The modes SubtitleMode accepts, in the order a client should offer them.
var SubtitleModes = []string{"always", "foreign", "manual"}

// The backgrounds SubtitleBackground accepts, in the order a client offers
// them.
var SubtitleBackgrounds = []string{"none", "shadow", "box"}

// The accents Accent accepts, in the order a client offers them.
var Accents = []string{"white", "amber", "red", "violet", "blue", "teal"}

// The colours SubtitleColor accepts, in the order a client offers them.
var SubtitleColors = []string{"white", "yellow", "cream", "cyan"}

// The policies Keep accepts, in the order a client offers them.
var Keeps = []string{"watched", "days", "forever"}

// legacyKeep is what Keep said before the number of days was a preference of
// its own. It is still read, and still taken from a client that knows no
// other way to say it, as "days" with KeepDays at thirty.
const legacyKeep = "30days"

// maxRate bounds the rate limits: a terabyte a second is no limit at all.
const maxRate = 1 << 40

type Store interface {
	Preferences(context.Context) (map[string]json.RawMessage, error)
	SetPreferences(context.Context, map[string]json.RawMessage) error
}

type Service struct {
	store    Store
	defaults Preferences

	// mu orders changes, so subscribers see them in the order they were
	// stored.
	mu          sync.Mutex
	subscribers []func(Preferences)
}

// ErrInvalid wraps every refusal of a Patch; the message on it is written
// for the person who typed the value.
var ErrInvalid = errors.New("invalid preferences")

type invalidError struct{ message string }

func (e invalidError) Error() string { return e.message }
func (e invalidError) Unwrap() error { return ErrInvalid }

func invalidf(format string, args ...any) error {
	return invalidError{message: fmt.Sprintf(format, args...)}
}

func New(store Store, defaults Preferences) *Service {
	defaults.SubtitleLanguages = append([]string(nil), defaults.SubtitleLanguages...)
	defaults.AudioLanguages = append([]string(nil), defaults.AudioLanguages...)
	return &Service{store: store, defaults: defaults}
}

func (s *Service) Get(ctx context.Context) (Preferences, error) {
	effective := s.defaults
	effective.SubtitleLanguages = append([]string(nil), s.defaults.SubtitleLanguages...)
	effective.AudioLanguages = append([]string(nil), s.defaults.AudioLanguages...)
	stored, err := s.store.Preferences(ctx)
	if err != nil {
		return Preferences{}, err
	}
	overlay(stored, "subtitleLanguages", &effective.SubtitleLanguages)
	overlay(stored, "audioLanguages", &effective.AudioLanguages)
	overlay(stored, "subtitleMode", &effective.SubtitleMode)
	overlay(stored, "subtitleScale", &effective.SubtitleScale)
	overlay(stored, "subtitlePosition", &effective.SubtitlePosition)
	overlay(stored, "subtitleBackground", &effective.SubtitleBackground)
	overlay(stored, "subtitleColor", &effective.SubtitleColor)
	overlay(stored, "subtitleKeepStyling", &effective.SubtitleKeepStyling)
	overlay(stored, "episodeArtwork", &effective.EpisodeArtwork)
	overlay(stored, "accent", &effective.Accent)
	overlay(stored, "keep", &effective.Keep)
	overlay(stored, "keepDays", &effective.KeepDays)
	overlay(stored, "diskLimit", &effective.DiskLimit)
	overlay(stored, "prefetch", &effective.Prefetch)
	overlay(stored, "nextCountdown", &effective.NextCountdown)
	overlay(stored, "nextNotice", &effective.NextNotice)
	overlay(stored, "seekStep", &effective.SeekStep)
	overlay(stored, "downloadDir", &effective.DownloadDir)
	overlay(stored, "seed", &effective.Seed)
	overlay(stored, "uploadLimit", &effective.UploadLimit)
	overlay(stored, "downloadLimit", &effective.DownloadLimit)
	if effective.Keep == legacyKeep {
		effective.Keep, effective.KeepDays = "days", 30
	}
	return effective, nil
}

// Subscribe has fn called with the whole document after every change, before
// the change is answered: what applies a preference inside the core (the
// torrent client's limits, where downloads go) follows it without polling.
func (s *Service) Subscribe(fn func(Preferences)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.subscribers = append(s.subscribers, fn)
}

// Reset puts every preference back to its default.
func (s *Service) Reset(ctx context.Context) (Preferences, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	stored, err := s.store.Preferences(ctx)
	if err != nil {
		return Preferences{}, err
	}
	// Every stored row, known here or not: one an older core wrote is a
	// preference too, and after a reset none is left.
	changes := make(map[string]json.RawMessage, len(stored))
	for key := range stored {
		changes[key] = nil
	}
	return s.commit(ctx, changes)
}

// commit stores changes and tells the subscribers. The caller holds mu.
func (s *Service) commit(ctx context.Context, changes map[string]json.RawMessage) (Preferences, error) {
	if err := s.store.SetPreferences(ctx, changes); err != nil {
		return Preferences{}, err
	}
	prefs, err := s.Get(ctx)
	if err != nil {
		return Preferences{}, err
	}
	for _, fn := range s.subscribers {
		fn(prefs)
	}
	return prefs, nil
}

// overlay replaces the default with the stored value when there is one that
// decodes. One that does not is left as the default: a row somebody hand
// edited into nonsense must not take the whole document with it.
func overlay[T any](stored map[string]json.RawMessage, key string, into *T) {
	raw, ok := stored[key]
	if !ok {
		return
	}
	var value *T
	if json.Unmarshal(raw, &value) == nil && value != nil {
		*into = *value
	}
}

// languageCode is ISO 639-1 with an optional region: a country ("pt-BR") or
// one of the UN M.49 areas BCP 47 allows ("es-419"), which is how the
// language list this core offers names Latin American Spanish. Whatever
// Languages() offers has to pass here, or the picker offers what the core
// then refuses.
var languageCode = regexp.MustCompile(`^[a-z]{2}(-([A-Z]{2}|[0-9]{3}))?$`)

func (s *Service) Patch(ctx context.Context, body []byte) (Preferences, error) {
	var document map[string]json.RawMessage
	if err := json.Unmarshal(body, &document); err != nil || document == nil {
		return Preferences{}, invalidf("request body must be a JSON object")
	}

	changes := make(map[string]json.RawMessage, len(document))
	for key, raw := range document {
		// null is the reset, for every key alike.
		if string(raw) == "null" {
			if !known(key) {
				return Preferences{}, invalidf("unknown preference %q", key)
			}
			changes[key] = nil
			continue
		}
		var err error
		switch key {
		case "subtitleLanguages":
			changes[key], err = languageList(key, "subtitle", raw)
		case "audioLanguages":
			changes[key], err = languageList(key, "audio", raw)
		case "subtitleMode":
			changes[key], err = oneOf(key, raw, SubtitleModes)
		case "subtitleScale":
			changes[key], err = number(key, raw, 0.5, 2)
		case "subtitlePosition":
			changes[key], err = integer(key, raw, 70, 100)
		case "subtitleBackground":
			changes[key], err = oneOf(key, raw, SubtitleBackgrounds)
		case "subtitleColor":
			changes[key], err = oneOf(key, raw, SubtitleColors)
		case "subtitleKeepStyling", "prefetch", "seed":
			changes[key], err = boolean(key, raw)
		case "episodeArtwork":
			changes[key], err = oneOf(key, raw, []string{"show", "blur", "hide"})
		case "accent":
			changes[key], err = oneOf(key, raw, Accents)
		case "keep":
			if legacy(raw) {
				changes[key] = json.RawMessage(`"days"`)
				continue
			}
			changes[key], err = oneOf(key, raw, Keeps)
		case "keepDays":
			changes[key], err = integer(key, raw, 1, 365)
		case "diskLimit":
			changes[key], err = integer(key, raw, 0, 1<<50)
		case "nextCountdown":
			changes[key], err = integer(key, raw, 0, 60)
		case "nextNotice":
			changes[key], err = integer(key, raw, 5, 120)
		case "seekStep":
			changes[key], err = integer(key, raw, 1, 60)
		case "downloadDir":
			// Checked last, below: it makes the folder, which a document
			// refused for another key must not leave behind.
			continue
		case "uploadLimit", "downloadLimit":
			changes[key], err = integer(key, raw, 0, maxRate)
		default:
			err = invalidf("unknown preference %q", key)
		}
		if err != nil {
			return Preferences{}, err
		}
	}
	if legacy(document["keep"]) {
		if raw, ok := document["keepDays"]; ok {
			var days int
			if json.Unmarshal(raw, &days) != nil || days != 30 {
				return Preferences{}, invalidf("keep %q is keepDays 30, not %s", legacyKeep, raw)
			}
		}
		changes["keepDays"] = json.RawMessage(`30`)
	}
	if raw, ok := document["downloadDir"]; ok && string(raw) != "null" {
		var err error
		if changes["downloadDir"], err = directory("downloadDir", raw); err != nil {
			return Preferences{}, err
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if _, days := changes["keepDays"]; days && document["keep"] == nil {
		// A stored "30days" outranks keepDays when read, so a number of days
		// chosen on its own also has to retire it.
		stored, err := s.store.Preferences(ctx)
		if err != nil {
			return Preferences{}, err
		}
		if legacy(stored["keep"]) {
			changes["keep"] = json.RawMessage(`"days"`)
		}
	}
	return s.commit(ctx, changes)
}

func known(key string) bool {
	switch key {
	case "subtitleLanguages", "audioLanguages", "subtitleMode", "subtitleScale",
		"subtitlePosition", "subtitleBackground", "subtitleColor", "subtitleKeepStyling",
		"episodeArtwork", "accent", "keep", "keepDays", "diskLimit", "prefetch",
		"nextCountdown", "nextNotice", "seekStep", "downloadDir", "seed",
		"uploadLimit", "downloadLimit":
		return true
	}
	return false
}

// legacy says whether a value of keep is the old "30days".
func legacy(raw json.RawMessage) bool {
	var value string
	return json.Unmarshal(raw, &value) == nil && value == legacyKeep
}

// directory is an absolute path to download into, or "" for the core's own
// place. It is made if missing and must take a file: a folder the core cannot
// write to would fail each download started after it, long after the setting
// that caused it. Nothing is written but the folder asked for and a probe in
// it, removed again.
func directory(key string, raw json.RawMessage) (json.RawMessage, error) {
	var path string
	if err := json.Unmarshal(raw, &path); err != nil {
		return nil, invalidf("%s must be a string", key)
	}
	if path == "" {
		return json.RawMessage(`""`), nil
	}
	if strings.ContainsRune(path, 0) || !filepath.IsAbs(path) {
		return nil, invalidf("%s must be an absolute path", key)
	}
	path = filepath.Clean(path)
	// 0700 like the directories the core makes for itself: what someone
	// watches is nobody else's business.
	if err := os.MkdirAll(path, 0o700); err != nil {
		return nil, invalidf("%s: cannot create %s", key, path)
	}
	probe, err := os.CreateTemp(path, ".lumeo-probe-*")
	if err != nil {
		return nil, invalidf("%s: cannot write to %s", key, path)
	}
	name := probe.Name()
	closeErr := probe.Close()
	if err := errors.Join(closeErr, os.Remove(name)); err != nil {
		return nil, invalidf("%s: cannot write to %s", key, path)
	}
	encoded, _ := json.Marshal(path)
	return encoded, nil
}

// languageList normalises what a client sends — "eng", "RU", "pt-br" — into
// the codes the rest of the system speaks, once each, in the order given.
func languageList(key, noun string, raw json.RawMessage) (json.RawMessage, error) {
	var entries []string
	if err := json.Unmarshal(raw, &entries); err != nil || entries == nil {
		return nil, invalidf("%s must be an array of strings", key)
	}
	languages := make([]string, 0, len(entries))
	seen := make(map[string]bool, len(entries))
	for _, entry := range entries {
		normalized := subtitles.Language(entry)
		if !languageCode.MatchString(normalized) {
			return nil, invalidf("invalid %s language %q", noun, entry)
		}
		if !seen[normalized] {
			seen[normalized] = true
			languages = append(languages, normalized)
		}
	}
	encoded, _ := json.Marshal(languages)
	return encoded, nil
}

func number(key string, raw json.RawMessage, min, max float64) (json.RawMessage, error) {
	var value float64
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, invalidf("%s must be a number", key)
	}
	if value < min || value > max {
		return nil, invalidf("%s must be between %g and %g", key, min, max)
	}
	return append(json.RawMessage(nil), raw...), nil
}

// integer is number for a field that is stored as one: a fraction accepted
// here would be stored, fail to decode on the way back, and read as the
// default forever.
func integer(key string, raw json.RawMessage, min, max int) (json.RawMessage, error) {
	var value int
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, invalidf("%s must be a whole number", key)
	}
	if value < min || value > max {
		return nil, invalidf("%s must be between %d and %d", key, min, max)
	}
	return append(json.RawMessage(nil), raw...), nil
}

func boolean(key string, raw json.RawMessage) (json.RawMessage, error) {
	var value bool
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, invalidf("%s must be true or false", key)
	}
	return append(json.RawMessage(nil), raw...), nil
}

func oneOf(key string, raw json.RawMessage, allowed []string) (json.RawMessage, error) {
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, invalidf("%s must be a string", key)
	}
	for _, candidate := range allowed {
		if value == candidate {
			return append(json.RawMessage(nil), raw...), nil
		}
	}
	quoted := make([]string, len(allowed))
	for i, candidate := range allowed {
		quoted[i] = fmt.Sprintf("%q", candidate)
	}
	// Written the way the refusal reads: `"show", "blur", or "hide"`.
	last := len(quoted) - 1
	return nil, invalidf("%s must be %s, or %s", key, strings.Join(quoted[:last], ", "), quoted[last])
}
