package subtitles

import (
	"sort"
	"strings"
)

// Subtitle databases speak ISO 639-2/B ("ger", "fre"), the rest of the system
// speaks ISO 639-1 ("de", "fr"), and the audio languages a source declares are
// already 639-1 — so language preferences would silently never match without
// this table. The odd ones out are OpenSubtitles' own: "pob" for Brazilian
// Portuguese, "zht" for traditional Chinese.
var iso6392 = map[string]string{
	"alb": "sq", "ara": "ar", "arm": "hy", "aze": "az", "baq": "eu", "bel": "be",
	"ben": "bn", "bos": "bs", "bul": "bg", "bur": "my", "cat": "ca", "chi": "zh",
	"cze": "cs", "dan": "da", "dut": "nl", "ell": "el", "eng": "en", "epo": "eo",
	"est": "et", "fin": "fi", "fre": "fr", "geo": "ka", "ger": "de", "gle": "ga",
	"glg": "gl", "gre": "el", "heb": "he", "hin": "hi", "hrv": "hr", "hun": "hu",
	"ice": "is", "ind": "id", "ita": "it", "jpn": "ja", "kaz": "kk", "khm": "km",
	"kor": "ko", "lav": "lv", "lit": "lt", "mac": "mk", "may": "ms", "mal": "ml",
	"mon": "mn", "nor": "no", "per": "fa", "pol": "pl", "por": "pt", "rum": "ro",
	"rus": "ru", "sin": "si", "slo": "sk", "slv": "sl", "spa": "es", "srp": "sr",
	"swe": "sv", "tam": "ta", "tel": "te", "tha": "th", "tur": "tr", "ukr": "uk",
	"urd": "ur", "vie": "vi",
	// The same languages again in ISO 639-2/T, which is what half the
	// providers send for the two dozen languages where the two standards
	// disagree. Without these a Dutch track arrives as "nld" and gets shown
	// as a code nobody recognises.
	"sqi": "sq", "hye": "hy", "eus": "eu", "mya": "my", "zho": "zh",
	"ces": "cs", "nld": "nl", "fra": "fr", "kat": "ka",
	"deu": "de", "isl": "is", "mkd": "mk", "msa": "ms", "fas": "fa",
	"ron": "ro", "slk": "sk", "bod": "bo", "cym": "cy",
	// Provider dialects, kept apart because a viewer who wants one is not
	// served by the other.
	"pob": "pt-BR", "pom": "pt", "zht": "zh-TW", "zhe": "zh",
	// OpenSubtitles' own code for Latin American Spanish, which is a
	// different translation rather than a different accent.
	"spl": "es-419",
}

var languageNames = map[string]string{
	"ar": "Arabic", "be": "Belarusian", "bg": "Bulgarian", "bn": "Bengali",
	"bs": "Bosnian", "ca": "Catalan", "cs": "Czech", "da": "Danish",
	"de": "German", "el": "Greek", "en": "English", "eo": "Esperanto",
	"es": "Spanish", "et": "Estonian", "eu": "Basque", "fa": "Persian",
	"fi": "Finnish", "fr": "French", "ga": "Irish", "gl": "Galician",
	"he": "Hebrew", "hi": "Hindi", "hr": "Croatian", "hu": "Hungarian",
	"hy": "Armenian", "id": "Indonesian", "is": "Icelandic", "it": "Italian",
	"ja": "Japanese", "ka": "Georgian", "kk": "Kazakh", "km": "Khmer",
	"ko": "Korean", "lt": "Lithuanian", "lv": "Latvian", "mk": "Macedonian",
	"ml": "Malayalam", "mn": "Mongolian", "ms": "Malay", "my": "Burmese",
	"nl": "Dutch", "no": "Norwegian", "pl": "Polish", "pt": "Portuguese",
	"pt-BR": "Portuguese (BR)", "ro": "Romanian", "ru": "Russian",
	"si": "Sinhala", "sk": "Slovak", "sl": "Slovenian", "sq": "Albanian",
	"sr": "Serbian", "sv": "Swedish", "ta": "Tamil", "te": "Telugu",
	"th": "Thai", "tr": "Turkish", "uk": "Ukrainian", "ur": "Urdu",
	"vi": "Vietnamese", "zh": "Chinese", "zh-TW": "Chinese (traditional)",
	"es-419": "Spanish (Latin America)", "bo": "Tibetan", "cy": "Welsh",
}

// Language names the codes this core can print a name for, sorted by name.
type NamedLanguage struct {
	Code string `json:"code"`
	Name string `json:"name"`
	// Aliases are the other codes the same language arrives under — the ISO
	// 639-2 ones a container writes on its tracks and a provider sends back.
	// A client matching a track against a preference needs the same table
	// this core normalises with, and this is how it gets it without a copy.
	Aliases []string `json:"aliases,omitempty"`
}

func Languages() []NamedLanguage {
	aliases := make(map[string][]string, len(languageNames))
	for alias, code := range iso6392 {
		aliases[code] = append(aliases[code], alias)
	}
	languages := make([]NamedLanguage, 0, len(languageNames))
	for code, name := range languageNames {
		sort.Strings(aliases[code])
		languages = append(languages, NamedLanguage{Code: code, Name: name, Aliases: aliases[code]})
	}
	sort.Slice(languages, func(i, j int) bool {
		if languages[i].Name == languages[j].Name {
			return languages[i].Code < languages[j].Code
		}
		return languages[i].Name < languages[j].Name
	})
	return languages
}

// Language normalises whatever a provider calls a language into the code the
// rest of the system uses. An unknown code is passed through rather than
// dropped: a track we cannot name is still a track someone may want.
func Language(code string) string {
	code = strings.TrimSpace(code)
	if code == "" {
		return ""
	}
	lower := strings.ToLower(code)
	if mapped, ok := iso6392[lower]; ok {
		return mapped
	}
	// Some addons already send 639-1, with or without a region.
	if base, region, ok := strings.Cut(lower, "-"); ok && len(base) == 2 {
		return base + "-" + strings.ToUpper(region)
	}
	if len(lower) == 2 {
		return lower
	}
	return code
}

// LanguageName is what to print for a code, and "" when we have no name for
// it — the caller shows the code itself rather than an invented name.
func LanguageName(code string) string { return languageNames[code] }
