package preferences

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

type fakeStore struct {
	values   map[string]json.RawMessage
	setCalls int
}

func (f *fakeStore) Preferences(context.Context) (map[string]json.RawMessage, error) {
	values := make(map[string]json.RawMessage, len(f.values))
	for key, value := range f.values {
		values[key] = append(json.RawMessage(nil), value...)
	}
	return values, nil
}

func (f *fakeStore) SetPreferences(_ context.Context, changes map[string]json.RawMessage) error {
	f.setCalls++
	if f.values == nil {
		f.values = make(map[string]json.RawMessage)
	}
	for key, value := range changes {
		if len(value) == 0 {
			delete(f.values, key)
		} else {
			f.values[key] = append(json.RawMessage(nil), value...)
		}
	}
	return nil
}

func TestGetOverlaysStoredPreferencesOnDefaults(t *testing.T) {
	store := &fakeStore{values: map[string]json.RawMessage{
		"subtitleLanguages": json.RawMessage(`["ru"]`),
	}}
	service := New(store, Preferences{SubtitleLanguages: []string{"en"}})

	got, err := service.Get(context.Background())
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	want := Preferences{SubtitleLanguages: []string{"ru"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %+v, want %+v", got, want)
	}
	if store.setCalls != 0 {
		t.Fatalf("SetPreferences calls = %d, want 0", store.setCalls)
	}
}

func TestGetIgnoresUndecodableStoredPreferences(t *testing.T) {
	store := &fakeStore{values: map[string]json.RawMessage{
		"subtitleLanguages": json.RawMessage(`null`),
		"subtitleScale":     json.RawMessage(`"big"`),
	}}
	want := Preferences{SubtitleLanguages: []string{"en"}}
	service := New(store, want)

	got, err := service.Get(context.Background())
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %+v, want %+v", got, want)
	}
}

func TestPatchValidPreferences(t *testing.T) {
	tests := []struct {
		name string
		body string
		want Preferences
	}{
		{
			name: "normalizes and deduplicates languages",
			body: `{"subtitleLanguages":["RU","eng","ru","pt-br"]}`,
			want: Preferences{SubtitleLanguages: []string{"ru", "en", "pt-BR"}},
		},
		{
			name: "empty language list",
			body: `{"subtitleLanguages":[]}`,
			want: Preferences{SubtitleLanguages: []string{}},
		},
		{
			name: "minimum subtitle scale",
			body: `{"subtitleScale":0.5}`,
			want: Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 0.5},
		},
		{
			name: "maximum subtitle scale",
			body: `{"subtitleScale":2}`,
			want: Preferences{SubtitleLanguages: []string{"en"}, SubtitleScale: 2},
		},
		{
			name: "empty object",
			body: `{}`,
			want: Preferences{SubtitleLanguages: []string{"en"}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := &fakeStore{}
			service := New(store, Preferences{SubtitleLanguages: []string{"en"}})
			got, err := service.Patch(context.Background(), []byte(tt.body))
			if err != nil {
				t.Fatalf("patch: %v", err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("preferences = %+v, want %+v", got, tt.want)
			}
			if store.setCalls != 1 {
				t.Fatalf("SetPreferences calls = %d, want 1", store.setCalls)
			}
		})
	}
}

func TestPatchNullResetsDefaults(t *testing.T) {
	store := &fakeStore{values: map[string]json.RawMessage{
		"subtitleLanguages": json.RawMessage(`["ru"]`),
		"subtitleScale":     json.RawMessage(`1.5`),
	}}
	want := Preferences{SubtitleLanguages: []string{"en"}}
	service := New(store, want)

	got, err := service.Patch(context.Background(), []byte(`{"subtitleLanguages":null,"subtitleScale":null}`))
	if err != nil {
		t.Fatalf("patch: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %+v, want %+v", got, want)
	}
	if len(store.values) != 0 {
		t.Fatalf("stored values = %v, want empty", store.values)
	}
}

// The soundtrack and the look of the subtitles are choices that follow the
// viewer to the next machine, so they are stored here with the languages.
func TestPatchTrackPreferencesStoreAndReset(t *testing.T) {
	store := &fakeStore{}
	defaults := testDefaults()
	service := New(store, defaults)
	got, err := service.Patch(context.Background(), []byte(
		`{"audioLanguages":["jpn","JA","en"],"subtitleMode":"foreign","subtitleScale":1.25,"subtitlePosition":85,"subtitleBackground":"box","subtitleColor":"cream","subtitleKeepStyling":false,"accent":"teal","keep":"days","keepDays":14,"diskLimit":107374182400,"prefetch":false,"nextCountdown":0,"nextNotice":45,"seekStep":10,"seed":false,"uploadLimit":1048576,"downloadLimit":0}`))
	if err != nil {
		t.Fatalf("patch: %v", err)
	}
	want := Preferences{
		AudioLanguages:     []string{"ja", "en"},
		SubtitleMode:       "foreign",
		SubtitleScale:      1.25,
		SubtitlePosition:   85,
		SubtitleBackground: "box",
		SubtitleColor:      "cream",
		Accent:             "teal",
		Keep:               "days",
		KeepDays:           14,
		DiskLimit:          100 << 30,
		Prefetch:           false,
		NextCountdown:      0,
		NextNotice:         45,
		SeekStep:           10,
		UploadLimit:        1 << 20,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("preferences = %+v, want %+v", got, want)
	}
	got, err = service.Patch(context.Background(), []byte(
		`{"audioLanguages":null,"subtitleMode":null,"subtitleScale":null,"subtitlePosition":null,"subtitleBackground":null,"subtitleColor":null,"subtitleKeepStyling":null,"accent":null,"keep":null,"keepDays":null,"diskLimit":null,"prefetch":null,"nextCountdown":null,"nextNotice":null,"seekStep":null,"seed":null,"uploadLimit":null,"downloadLimit":null}`))
	if err != nil {
		t.Fatalf("reset: %v", err)
	}
	if want = defaults; !reflect.DeepEqual(got, want) {
		t.Fatalf("after reset = %+v, want %+v", got, want)
	}
	if len(store.values) != 0 {
		t.Fatalf("stored values = %v, want empty", store.values)
	}
}

func TestPatchEpisodeArtworkStoresValidValueAndNullResets(t *testing.T) {
	store := &fakeStore{}
	service := New(store, Preferences{EpisodeArtwork: "blur"})
	got, err := service.Patch(context.Background(), []byte(`{"episodeArtwork":"hide"}`))
	if err != nil {
		t.Fatalf("patch: %v", err)
	}
	if got.EpisodeArtwork != "hide" {
		t.Fatalf("episodeArtwork = %q, want hide", got.EpisodeArtwork)
	}
	got, err = service.Patch(context.Background(), []byte(`{"episodeArtwork":null}`))
	if err != nil {
		t.Fatalf("reset: %v", err)
	}
	if got.EpisodeArtwork != "blur" {
		t.Fatalf("episodeArtwork = %q, want default blur", got.EpisodeArtwork)
	}
}

func TestPatchRejectsInvalidDocumentsWithoutWriting(t *testing.T) {
	tests := []struct {
		name    string
		body    string
		message string
	}{
		{name: "bad JSON", body: `{`, message: "request body must be a JSON object"},
		{name: "null", body: `null`, message: "request body must be a JSON object"},
		{name: "array", body: `[]`, message: "request body must be a JSON object"},
		{name: "string", body: `"preferences"`, message: "request body must be a JSON object"},
		{name: "unknown key", body: `{"foo":1}`, message: `unknown preference "foo"`},
		{name: "languages not array", body: `{"subtitleLanguages":"en"}`, message: "subtitleLanguages must be an array of strings"},
		{name: "languages contains non-string", body: `{"subtitleLanguages":["en",1]}`, message: "subtitleLanguages must be an array of strings"},
		{name: "invalid language", body: `{"subtitleLanguages":["english"]}`, message: `invalid subtitle language "english"`},
		{name: "subtitle scale not number", body: `{"subtitleScale":"big"}`, message: "subtitleScale must be a number"},
		{name: "subtitle scale too large", body: `{"subtitleScale":2.01}`, message: "subtitleScale must be between 0.5 and 2"},
		{name: "speed is no longer a preference", body: `{"playbackSpeed":1.5}`, message: `unknown preference "playbackSpeed"`},
		{name: "artwork not string", body: `{"episodeArtwork":1}`, message: "episodeArtwork must be a string"},
		{name: "invalid artwork", body: `{"episodeArtwork":"clear"}`, message: `episodeArtwork must be "show", "blur", or "hide"`},
		{name: "mixed document is atomic", body: `{"subtitleLanguages":["ru"],"subtitleScale":9}`, message: "subtitleScale must be between 0.5 and 2"},
		{name: "audio languages not array", body: `{"audioLanguages":"ja"}`, message: "audioLanguages must be an array of strings"},
		{name: "invalid audio language", body: `{"audioLanguages":["japanese"]}`, message: `invalid audio language "japanese"`},
		{name: "unknown subtitle mode", body: `{"subtitleMode":"smart"}`, message: `subtitleMode must be "always", "foreign", or "manual"`},
		{name: "subtitle scale too small", body: `{"subtitleScale":0.4}`, message: "subtitleScale must be between 0.5 and 2"},
		{name: "subtitle position off the picture", body: `{"subtitlePosition":101}`, message: "subtitlePosition must be between 70 and 100"},
		{name: "subtitle position not number", body: `{"subtitlePosition":"low"}`, message: "subtitlePosition must be a whole number"},
		{name: "subtitle position fraction", body: `{"subtitlePosition":85.5}`, message: "subtitlePosition must be a whole number"},
		{name: "subtitle background unknown", body: `{"subtitleBackground":"glow"}`, message: `subtitleBackground must be "none", "shadow", or "box"`},
		{name: "accent unknown", body: `{"accent":"green"}`, message: `accent must be "white", "amber", "red", "violet", "blue", or "teal"`},
		{name: "keep unknown", body: `{"keep":"week"}`, message: `keep must be "watched", "days", or "forever"`},
		{name: "keep days zero", body: `{"keepDays":0}`, message: "keepDays must be between 1 and 365"},
		{name: "keep days over a year", body: `{"keepDays":366}`, message: "keepDays must be between 1 and 365"},
		{name: "legacy keep with other days", body: `{"keep":"30days","keepDays":7}`, message: `keep "30days" is keepDays 30, not 7`},
		{name: "subtitle colour unknown", body: `{"subtitleColor":"green"}`, message: `subtitleColor must be "white", "yellow", "cream", or "cyan"`},
		{name: "keep styling not boolean", body: `{"subtitleKeepStyling":1}`, message: "subtitleKeepStyling must be true or false"},
		{name: "next notice too early", body: `{"nextNotice":4}`, message: "nextNotice must be between 5 and 120"},
		{name: "next notice too late", body: `{"nextNotice":121}`, message: "nextNotice must be between 5 and 120"},
		{name: "seek step zero", body: `{"seekStep":0}`, message: "seekStep must be between 1 and 60"},
		{name: "seek step fraction", body: `{"seekStep":2.5}`, message: "seekStep must be a whole number"},
		{name: "seed not boolean", body: `{"seed":"off"}`, message: "seed must be true or false"},
		{name: "upload limit negative", body: `{"uploadLimit":-1}`, message: "uploadLimit must be between 0 and 1099511627776"},
		{name: "download limit not number", body: `{"downloadLimit":"1M"}`, message: "downloadLimit must be a whole number"},
		{name: "download dir relative", body: `{"downloadDir":"films"}`, message: "downloadDir must be an absolute path"},
		{name: "download dir not string", body: `{"downloadDir":1}`, message: "downloadDir must be a string"},
		{name: "disk limit negative", body: `{"diskLimit":-1}`, message: "diskLimit must be between 0 and 1125899906842624"},
		{name: "prefetch not boolean", body: `{"prefetch":"yes"}`, message: "prefetch must be true or false"},
		{name: "next countdown too long", body: `{"nextCountdown":61}`, message: "nextCountdown must be between 0 and 60"},
		{name: "next countdown fraction", body: `{"nextCountdown":2.5}`, message: "nextCountdown must be a whole number"},
		{name: "null for unknown key", body: `{"foo":null}`, message: `unknown preference "foo"`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := &fakeStore{values: map[string]json.RawMessage{"subtitleScale": json.RawMessage(`1.5`)}}
			service := New(store, Preferences{SubtitleLanguages: []string{"en"}})
			_, err := service.Patch(context.Background(), []byte(tt.body))
			if !errors.Is(err, ErrInvalid) {
				t.Fatalf("error = %v, want ErrInvalid", err)
			}
			if err.Error() != tt.message {
				t.Fatalf("error = %q, want %q", err, tt.message)
			}
			if store.setCalls != 0 {
				t.Fatalf("SetPreferences calls = %d, want 0", store.setCalls)
			}
			if string(store.values["subtitleScale"]) != "1.5" || len(store.values) != 1 {
				t.Fatalf("stored values changed: %v", store.values)
			}
		})
	}
}

// The picker on a settings page is built from Languages(), so every code in
// it has to be one the core will store.
func TestPatchAcceptsEveryOfferedLanguage(t *testing.T) {
	store := &fakeStore{values: map[string]json.RawMessage{}}
	service := New(store, Preferences{})
	for _, language := range subtitles.Languages() {
		body := fmt.Sprintf(`{"subtitleLanguages":[%q]}`, language.Code)
		got, err := service.Patch(context.Background(), []byte(body))
		if err != nil {
			t.Fatalf("%s: %v", language.Code, err)
		}
		if len(got.SubtitleLanguages) != 1 || got.SubtitleLanguages[0] != language.Code {
			t.Fatalf("%s: stored as %v", language.Code, got.SubtitleLanguages)
		}
	}
}

// testDefaults are the defaults the core starts with.
func testDefaults() Preferences {
	return Preferences{
		SubtitleMode: "always", SubtitleScale: 1, SubtitlePosition: 100, SubtitleBackground: "none",
		SubtitleColor: "white", SubtitleKeepStyling: true, Accent: "white", Keep: "forever", KeepDays: 30,
		Prefetch: true, NextCountdown: 5, NextNotice: 30, SeekStep: 5, Seed: true,
	}
}

// "30days" was the only number of days before it was a preference of its own:
// stored, it reads back as the pair, and a client that still sends it gets
// the pair stored.
func TestLegacyThirtyDays(t *testing.T) {
	tests := []struct {
		name   string
		stored map[string]json.RawMessage
		patch  string
		want   map[string]string
	}{
		{
			name:   "stored",
			stored: map[string]json.RawMessage{"keep": json.RawMessage(`"30days"`)},
		},
		{
			name:   "stored beside a number of days",
			stored: map[string]json.RawMessage{"keep": json.RawMessage(`"30days"`), "keepDays": json.RawMessage(`7`)},
		},
		{
			name:  "patched",
			patch: `{"keep":"30days"}`,
			want:  map[string]string{"keep": `"days"`, "keepDays": `30`},
		},
		{
			name:  "patched with the same days",
			patch: `{"keep":"30days","keepDays":30}`,
			want:  map[string]string{"keep": `"days"`, "keepDays": `30`},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := &fakeStore{values: tt.stored}
			service := New(store, testDefaults())
			var got Preferences
			var err error
			if tt.patch != "" {
				got, err = service.Patch(context.Background(), []byte(tt.patch))
			} else {
				got, err = service.Get(context.Background())
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.Keep != "days" || got.KeepDays != 30 {
				t.Fatalf("keep = %q, keepDays = %d, want days and 30", got.Keep, got.KeepDays)
			}
			for key, value := range tt.want {
				if string(store.values[key]) != value {
					t.Fatalf("stored %s = %s, want %s", key, store.values[key], value)
				}
			}
		})
	}
}

// A number of days patched alone over a stored "30days" is the one that holds.
func TestDaysPatchedOverLegacyKeep(t *testing.T) {
	store := &fakeStore{values: map[string]json.RawMessage{"keep": json.RawMessage(`"30days"`)}}
	service := New(store, testDefaults())
	got, err := service.Patch(context.Background(), []byte(`{"keepDays":7}`))
	if err != nil {
		t.Fatal(err)
	}
	if got.Keep != "days" || got.KeepDays != 7 {
		t.Fatalf("keep = %q, keepDays = %d, want days and 7", got.Keep, got.KeepDays)
	}
	if string(store.values["keep"]) != `"days"` {
		t.Fatalf("stored keep = %s, want \"days\"", store.values["keep"])
	}
}

func TestPatchDownloadDir(t *testing.T) {
	root := t.TempDir()
	blocker := filepath.Join(root, "file")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name    string
		path    string
		want    string
		message string
	}{
		{name: "existing folder", path: root, want: root},
		{name: "made when missing", path: filepath.Join(root, "films", "new"), want: filepath.Join(root, "films", "new")},
		{name: "cleaned", path: root + string(filepath.Separator) + "a" + string(filepath.Separator) + ".." + string(filepath.Separator) + "b", want: filepath.Join(root, "b")},
		{name: "empty is the default", path: "", want: ""},
		{name: "under a file", path: filepath.Join(blocker, "films"), message: "downloadDir: cannot create " + filepath.Join(blocker, "films")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			store := &fakeStore{}
			service := New(store, testDefaults())
			body, _ := json.Marshal(map[string]string{"downloadDir": tt.path})
			got, err := service.Patch(context.Background(), body)
			if tt.message != "" {
				if !errors.Is(err, ErrInvalid) || err.Error() != tt.message {
					t.Fatalf("error = %v, want %q", err, tt.message)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.DownloadDir != tt.want {
				t.Fatalf("downloadDir = %q, want %q", got.DownloadDir, tt.want)
			}
			if tt.want == "" {
				return
			}
			if info, err := os.Stat(tt.want); err != nil || !info.IsDir() {
				t.Fatalf("%s is not a folder: %v", tt.want, err)
			}
			// The probe is gone again: nothing is left but the folder.
			if entries, _ := os.ReadDir(tt.want); slices.ContainsFunc(entries, func(e os.DirEntry) bool {
				return strings.HasPrefix(e.Name(), ".lumeo-probe")
			}) {
				t.Fatalf("probe left in %s", tt.want)
			}
		})
	}
}

// A document refused for another key makes no folder: the check of the
// folder, which creates it, runs only once everything else passed.
func TestRefusedPatchMakesNoDownloadDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "films")
	store := &fakeStore{}
	service := New(store, testDefaults())
	body, _ := json.Marshal(map[string]any{"downloadDir": dir, "seekStep": 0})
	if _, err := service.Patch(context.Background(), body); !errors.Is(err, ErrInvalid) {
		t.Fatalf("error = %v, want ErrInvalid", err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("%s was made: %v", dir, err)
	}
}

func TestResetForgetsEveryStoredPreference(t *testing.T) {
	store := &fakeStore{values: map[string]json.RawMessage{
		"accent":       json.RawMessage(`"red"`),
		"seed":         json.RawMessage(`false`),
		"uploadLimit":  json.RawMessage(`1000`),
		"removedLater": json.RawMessage(`1`),
	}}
	service := New(store, testDefaults())
	var told []Preferences
	service.Subscribe(func(p Preferences) { told = append(told, p) })
	got, err := service.Reset(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, testDefaults()) {
		t.Fatalf("after reset = %+v, want %+v", got, testDefaults())
	}
	if len(store.values) != 0 {
		t.Fatalf("stored values = %v, want empty", store.values)
	}
	if len(told) != 1 || !reflect.DeepEqual(told[0], got) {
		t.Fatalf("subscriber was told %+v, want the reset document once", told)
	}
}

// Subscribers hear every change, in order, with the whole document, and
// nothing about a refused one.
func TestSubscribersFollowChanges(t *testing.T) {
	service := New(&fakeStore{}, testDefaults())
	var limits []int64
	service.Subscribe(func(p Preferences) { limits = append(limits, p.UploadLimit) })
	for _, body := range []string{`{"uploadLimit":100}`, `{"seekStep":0}`, `{"uploadLimit":200}`, `{"uploadLimit":null}`} {
		_, _ = service.Patch(context.Background(), []byte(body))
	}
	if want := []int64{100, 200, 0}; !slices.Equal(limits, want) {
		t.Fatalf("subscriber saw %v, want %v", limits, want)
	}
}
