package subtitles

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"path"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/unicode"
)

// decompress unwraps the gzip some databases serve subtitles as. Anything
// else is passed through: the file itself is text, and guessing further would
// only turn a readable error into a broken track.
func decompress(body []byte) ([]byte, error) {
	if len(body) < 2 || body[0] != 0x1f || body[1] != 0x8b {
		return body, nil
	}
	zr, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("subtitles: gunzip: %w", err)
	}
	defer zr.Close()
	out, err := io.ReadAll(io.LimitReader(zr, maxFileSize))
	if err != nil {
		return nil, fmt.Errorf("subtitles: gunzip: %w", err)
	}
	return out, nil
}

// format decides what the player is about to be handed. The provider's word
// comes first, then the URL, and only then the file itself — by which point
// the answer matters mostly for the Content-Type.
func format(sub Subtitle, body []byte) string {
	if sub.Format != "" {
		return sub.Format
	}
	if ext := strings.TrimPrefix(strings.ToLower(path.Ext(pathOf(sub.SourceURL))), "."); ext != "" {
		switch ext {
		case "srt", "vtt", "ass", "ssa", "sub":
			return ext
		}
	}
	switch {
	case bytes.HasPrefix(bytes.TrimLeft(body, "\ufeff \n\r\t"), []byte("WEBVTT")):
		return "vtt"
	case bytes.Contains(body[:min(len(body), 512)], []byte("[Script Info]")):
		return "ass"
	default:
		return "srt"
	}
}

func pathOf(rawURL string) string {
	if i := strings.IndexAny(rawURL, "?#"); i >= 0 {
		rawURL = rawURL[:i]
	}
	return rawURL
}

// toUTF8 turns whatever a subtitle database holds into text a player can
// render. Most of these files predate Unicode and carry no declaration of
// what they are, so the order is: believe the file (valid UTF-8 nearly always
// is UTF-8), then the provider's declared charset, then the single-byte page
// that language was written in before UTF-8 existed.
func toUTF8(body []byte, declared, language string) []byte {
	if len(body) >= 2 {
		switch {
		case body[0] == 0xff && body[1] == 0xfe, body[0] == 0xfe && body[1] == 0xff:
			decoder := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).NewDecoder()
			if out, err := decoder.Bytes(body); err == nil {
				return trimBOM(out)
			}
		}
	}
	if utf8.Valid(body) {
		return trimBOM(body)
	}
	enc := charsetByName(declared)
	if enc == nil {
		enc = charsetByLanguage(language)
	}
	out, err := enc.NewDecoder().Bytes(body)
	if err != nil {
		return body // undecodable: the player's own guess is as good as ours
	}
	return trimBOM(out)
}

func trimBOM(b []byte) []byte { return bytes.TrimPrefix(b, []byte("\ufeff")) }

// charsetByName reads the charset a provider declares — OpenSubtitles sends
// things like "CP1251" and "ISO-8859-2" alongside the file.
func charsetByName(name string) encoding.Encoding {
	key := strings.NewReplacer("-", "", "_", "", " ", "").Replace(strings.ToLower(name))
	key = strings.TrimPrefix(strings.TrimPrefix(key, "windows"), "cp")
	switch key {
	case "1250":
		return charmap.Windows1250
	case "1251":
		return charmap.Windows1251
	case "1252":
		return charmap.Windows1252
	case "1253":
		return charmap.Windows1253
	case "1254":
		return charmap.Windows1254
	case "1255":
		return charmap.Windows1255
	case "1256":
		return charmap.Windows1256
	case "1257":
		return charmap.Windows1257
	case "iso88591", "latin1":
		return charmap.ISO8859_1
	case "iso88592", "latin2":
		return charmap.ISO8859_2
	case "iso88595":
		return charmap.ISO8859_5
	case "iso88597":
		return charmap.ISO8859_7
	case "iso88599", "latin5":
		return charmap.ISO8859_9
	case "koi8r":
		return charmap.KOI8R
	case "koi8u":
		return charmap.KOI8U
	}
	return nil
}

// charsetByLanguage is the last resort: the code page that language's
// subtitles were written in when they were not UTF-8.
func charsetByLanguage(language string) encoding.Encoding {
	base, _, _ := strings.Cut(language, "-")
	switch base {
	case "ru", "uk", "bg", "sr", "be", "mk":
		return charmap.Windows1251
	case "cs", "sk", "pl", "hu", "ro", "hr", "sl", "sq", "bs":
		return charmap.Windows1250
	case "el":
		return charmap.Windows1253
	case "tr":
		return charmap.Windows1254
	case "he":
		return charmap.Windows1255
	case "ar", "fa", "ur":
		return charmap.Windows1256
	case "lt", "lv", "et":
		return charmap.Windows1257
	default:
		return charmap.Windows1252
	}
}
