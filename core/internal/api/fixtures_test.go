package api

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/addons"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/config"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
	"github.com/eeegoloauq/lumeo/core/internal/update"
)

func TestClientFixturesMatchResponses(t *testing.T) {
	for _, tc := range []struct {
		file  string
		value any
	}{
		{"items.json", &[]catalog.MediaItem{}},
		{"catalogs.json", &[]catalog.Row{}},
		{"sources.json", &[]sources.MediaSource{}},
		{"addons.json", &[]addons.Addon{}},
		{"storage-titles.json", &[]storageTitle{}},
		{"preferences.json", &preferences.Preferences{}},
		{"languages.json", &[]subtitles.NamedLanguage{}},
		{"download.json", &acquire.Download{}},
		{"about.json", &About{}},
		{"update.json", &update.Release{}},
	} {
		t.Run(tc.file, func(t *testing.T) {
			path := filepath.Join("..", "..", "..", "client", "test", "fixtures", "core", tc.file)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("%s: read: %v", tc.file, err)
			}
			decoder := json.NewDecoder(bytes.NewReader(data))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(tc.value); err != nil {
				t.Fatalf("%s: decode into response type: %v", tc.file, err)
			}
			result, err := json.Marshal(tc.value)
			if err != nil {
				t.Fatalf("%s: marshal response type: %v", tc.file, err)
			}
			var fixture, roundTrip any
			if err := json.Unmarshal(data, &fixture); err != nil {
				t.Fatalf("%s: decode fixture: %v", tc.file, err)
			}
			if err := json.Unmarshal(result, &roundTrip); err != nil {
				t.Fatalf("%s: decode marshaled response: %v", tc.file, err)
			}
			if !reflect.DeepEqual(fixture, roundTrip) {
				t.Fatalf("%s: fixture = %v; response = %v", tc.file, fixture, roundTrip)
			}
			if tc.file == "addons.json" {
				// The fixture is a fresh core's addons and then what the viewer added.
				t.Setenv("LUMEO_ADDONS", "")
				defaults := config.FromEnv().Addons
				fixture := *tc.value.(*[]addons.Addon)
				if len(fixture) < len(defaults) {
					t.Fatalf("%s: %d addons, a fresh core has %d", tc.file, len(fixture), len(defaults))
				}
				for i, want := range defaults {
					if fixture[i].ID != want.ID || fixture[i].URL != want.BaseURL {
						t.Errorf("%s[%d] = %s %s; a fresh core starts with %s %s", tc.file, i, fixture[i].ID, fixture[i].URL, want.ID, want.BaseURL)
					}
				}
			}
			if tc.file == "languages.json" && !reflect.DeepEqual(*tc.value.(*[]subtitles.NamedLanguage), subtitles.Languages()) {
				t.Fatalf("%s: fixture = %v; core = %v", tc.file, *tc.value.(*[]subtitles.NamedLanguage), subtitles.Languages())
			}
		})
	}
}
