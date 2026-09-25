package subtitles

import (
	"bytes"
	"compress/gzip"
	"testing"
)

// Half of what subtitle databases hold predates Unicode. Nothing declares it,
// so a player handed the bytes shows mojibake and the viewer blames the film.
func TestToUTF8DecodesByLanguageWhenNothingIsDeclared(t *testing.T) {
	// "Привет" in windows-1251, the code page Russian subtitles were written
	// in for twenty years.
	cp1251 := []byte{0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2}
	if got := string(toUTF8(cp1251, "", "ru")); got != "Привет" {
		t.Errorf("got %q, want %q", got, "Привет")
	}
}

// A declared charset beats the guess from the language, which is the point of
// carrying it out of the provider's response.
func TestToUTF8BelievesTheDeclaredCharset(t *testing.T) {
	koi8r := []byte{0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4}
	if got := string(toUTF8(koi8r, "KOI8-R", "ru")); got != "Привет" {
		t.Errorf("got %q, want %q", got, "Привет")
	}
}

// Text that is already UTF-8 must survive untouched, BOM aside: guessing at
// it would break every modern subtitle to fix the old ones.
func TestToUTF8LeavesUnicodeAlone(t *testing.T) {
	body := append([]byte("\ufeff"), []byte("Привет — 1080p")...)
	if got := string(toUTF8(body, "CP1251", "ru")); got != "Привет — 1080p" {
		t.Errorf("got %q", got)
	}
}

func TestDecompressUnwrapsGzip(t *testing.T) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write([]byte("1\n00:00:01,000 --> 00:00:02,000\nhello\n")); err != nil {
		t.Fatal(err)
	}
	zw.Close()

	got, err := decompress(buf.Bytes())
	if err != nil {
		t.Fatalf("decompress: %v", err)
	}
	if !bytes.HasPrefix(got, []byte("1\n00:00:01,000")) {
		t.Errorf("got %q", got)
	}
}

func TestDecompressPassesPlainTextThrough(t *testing.T) {
	body := []byte("WEBVTT\n\n00:01.000 --> 00:02.000\nhello\n")
	got, err := decompress(body)
	if err != nil {
		t.Fatalf("decompress: %v", err)
	}
	if !bytes.Equal(got, body) {
		t.Errorf("got %q", got)
	}
}

func TestFormatFallsBackToTheFileItself(t *testing.T) {
	cases := []struct {
		name string
		sub  Subtitle
		body string
		want string
	}{
		{"provider says so", Subtitle{Format: "ass"}, "whatever", "ass"},
		{"from the url", Subtitle{SourceURL: "https://x/y/file.vtt?token=1"}, "", "vtt"},
		{"webvtt header", Subtitle{SourceURL: "https://x/download/1234"}, "WEBVTT\n", "vtt"},
		{"ass header", Subtitle{SourceURL: "https://x/download/1234"}, "[Script Info]\n", "ass"},
		{"anything else is srt", Subtitle{SourceURL: "https://x/download/1234"}, "1\n00:00:01,000", "srt"},
	}
	for _, c := range cases {
		if got := format(c.sub, []byte(c.body)); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestLanguageNormalisesProviderCodes(t *testing.T) {
	cases := map[string]string{
		"eng": "en", "rus": "ru", "ger": "de", "pob": "pt-BR",
		// The same languages in the other three-letter standard: providers
		// mix the two freely and a code that survives as a code is a row in
		// the picker nobody can read.
		"deu": "de", "nld": "nl", "ron": "ro", "zho": "zh", "spl": "es-419",
		"en": "en", "pt-br": "pt-BR", "klingon": "klingon", "": "",
	}
	for in, want := range cases {
		if got := Language(in); got != want {
			t.Errorf("Language(%q): got %q, want %q", in, got, want)
		}
	}
}
