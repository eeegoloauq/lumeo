package subtitles

import (
	"reflect"
	"testing"
)

func TestLanguagesNamesEveryCodeAndSortsByName(t *testing.T) {
	languages := Languages()
	if len(languages) != len(languageNames) {
		t.Fatalf("language count = %d, want %d", len(languages), len(languageNames))
	}
	for i, language := range languages {
		if language.Name != languageNames[language.Code] {
			t.Errorf("language %q has name %q, want %q", language.Code, language.Name, languageNames[language.Code])
		}
		if i > 0 && languages[i-1].Name > language.Name {
			t.Fatalf("languages are not sorted by name: %q before %q", languages[i-1].Name, language.Name)
		}
		for _, alias := range language.Aliases {
			if Language(alias) != language.Code {
				t.Errorf("alias %q of %q normalises to %q", alias, language.Code, Language(alias))
			}
		}
	}
}

// A container writes ISO 639-2 on its tracks, in whichever of the two
// standards its muxer knew, so the client has to be told both.
func TestLanguagesCarryEveryAlias(t *testing.T) {
	want := map[string][]string{"de": {"deu", "ger"}, "en": {"eng"}, "pt-BR": {"pob"}, "zh-TW": {"zht"}}
	for _, language := range Languages() {
		if aliases, ok := want[language.Code]; ok && !reflect.DeepEqual(language.Aliases, aliases) {
			t.Errorf("aliases of %q = %v, want %v", language.Code, language.Aliases, aliases)
		}
	}
}
