// Package release parses scene/p2p release names into structured metadata.
//
// Source providers (Stremio addons, indexers) hand us a single human-oriented
// string per result. Everything the UI wants to sort and filter on — resolution,
// codec, HDR, audio, language, group — only exists inside that string, so the
// parser is what separates a usable source list from a wall of text.
package release

import (
	"regexp"
	"strconv"
	"strings"
)

type Info struct {
	Title      string   `json:"title,omitempty"`
	Year       int      `json:"year,omitempty"`
	Season     int      `json:"season,omitempty"`
	Episode    int      `json:"episode,omitempty"`
	Resolution string   `json:"resolution,omitempty"` // 2160p, 1080p, 720p
	Source     string   `json:"source,omitempty"`     // BluRay, WEB-DL, WEBRip, HDTV, DVDRip
	VideoCodec string   `json:"videoCodec,omitempty"` // AVC, HEVC, AV1, XviD
	BitDepth   int      `json:"bitDepth,omitempty"`   // 8, 10, 12
	HDR        []string `json:"hdr,omitempty"`        // HDR10, HDR10+, DV, HLG
	AudioCodec string   `json:"audioCodec,omitempty"` // AAC, AC3, EAC3, DTS, DTS-HD, TrueHD, FLAC, Opus
	Channels   string   `json:"channels,omitempty"`   // 2.0, 5.1, 7.1
	Atmos      bool     `json:"atmos,omitempty"`
	Languages  []string `json:"languages,omitempty"` // ISO-639-1 where recognised
	MultiSub   bool     `json:"multiSub,omitempty"`
	MultiAudio bool     `json:"multiAudio,omitempty"`
	Repack     bool     `json:"repack,omitempty"`
	Proper     bool     `json:"proper,omitempty"`
	Remux      bool     `json:"remux,omitempty"`
	Group      string   `json:"group,omitempty"`
	Container  string   `json:"container,omitempty"`
}

var (
	reBracketGroup = regexp.MustCompile(`^\[([^\]]{1,30})\]`)
	reDashGroup    = regexp.MustCompile(`-([A-Za-z0-9_.]{2,20})$`)
	reYear         = regexp.MustCompile(`\b(19\d{2}|20\d{2})\b`)
	reSeasonEp     = regexp.MustCompile(`(?i)\bS(\d{1,3})[\s._-]?E(\d{1,4})\b`)
	reSeasonOnly   = regexp.MustCompile(`(?i)\bS(\d{1,3})\b`)
	reSeasonWord   = regexp.MustCompile(`(?i)\b(\d{1,2})(?:st|nd|rd|th)\s+season\b|\bseason\s+(\d{1,2})\b`)
	reXEp          = regexp.MustCompile(`\b(\d{1,2})x(\d{1,3})\b`)
	reAbsEp        = regexp.MustCompile(`\s-\s(\d{1,4})\s`)
	reResolution   = regexp.MustCompile(`(?i)\b(4320p|2160p|1440p|1080p|720p|576p|480p|4k|uhd)\b`)
	reBitDepth     = regexp.MustCompile(`(?i)\b(8|10|12)[\s._-]?bits?\b`)
	// Audio layout arrives glued to its codec ("DDP5.1", "AAC2.0") or standing
	// alone after another tag ("TrueHD Atmos 7.1"), so both shapes are matched.
	reAudioCh     = regexp.MustCompile(`(?i)\b(ddp|dd\+|dd|eac3|ac3|aac|dts-hd\s?ma|dts-hd|dts-x|dtshd|dts|truehd|flac|opus|mp3)[\s._-]?([1-8])[\s._-]([0-2])\b`)
	reChannels    = regexp.MustCompile(`\b([1-8])\.([0-2])\b`)
	reDottedCodec = regexp.MustCompile(`(?i)\b([hx])\.(26[45])\b`)
	reContainer   = regexp.MustCompile(`(?i)\.(mkv|mp4|avi|ts|m2ts)$`)
	reSeparators  = regexp.MustCompile(`[._]+`)
)

// token → canonical value tables. Order inside a table does not matter; the
// scan walks the name left to right and takes the first hit per field.
var (
	sourceTokens = map[string]string{
		"bluray": "BluRay", "blu-ray": "BluRay", "bdrip": "BDRip", "brrip": "BRRip",
		"bdremux": "BluRay", "remux": "BluRay",
		"webdl": "WEB-DL", "web-dl": "WEB-DL", "web": "WEB-DL", "webrip": "WEBRip",
		"hdtv": "HDTV", "pdtv": "HDTV", "dvdrip": "DVDRip", "dvd": "DVD",
		"hdrip": "HDRip", "cam": "CAM", "ts": "TS", "telesync": "TS",
	}
	videoTokens = map[string]string{
		"x264": "AVC", "h264": "AVC", "h.264": "AVC", "avc": "AVC",
		"x265": "HEVC", "h265": "HEVC", "h.265": "HEVC", "hevc": "HEVC",
		"av1": "AV1", "vp9": "VP9", "xvid": "XviD", "divx": "DivX", "mpeg2": "MPEG-2",
	}
	audioTokens = map[string]string{
		"aac": "AAC", "ac3": "AC3", "dd": "AC3", "dd5": "AC3",
		"eac3": "EAC3", "ddp": "EAC3", "dd+": "EAC3",
		"dts": "DTS", "dts-hd": "DTS-HD", "dtshd": "DTS-HD", "dts-x": "DTS-X",
		"truehd": "TrueHD", "flac": "FLAC", "opus": "Opus", "mp3": "MP3", "pcm": "PCM",
	}
	hdrTokens = map[string]string{
		"hdr": "HDR10", "hdr10": "HDR10", "hdr10+": "HDR10+", "hdr10plus": "HDR10+",
		"dv": "DV", "dovi": "DV", "dolbyvision": "DV", "hlg": "HLG",
	}
	langTokens = map[string]string{
		"english": "en", "eng": "en", "russian": "ru", "rus": "ru", "japanese": "ja",
		"jap": "ja", "jpn": "ja", "french": "fr", "fre": "fr", "german": "de",
		"ger": "de", "spanish": "es", "spa": "es", "italian": "it", "ita": "it",
		"portuguese": "pt", "por": "pt", "korean": "ko", "kor": "ko",
		"chinese": "zh", "chi": "zh", "ukrainian": "uk", "ukr": "uk",
	}
)

// Parse extracts what it can from a release name. It never fails: an
// unrecognisable name yields an Info with only Title set.
func Parse(name string) Info {
	var in Info
	raw := strings.TrimSpace(name)
	if raw == "" {
		return in
	}

	if m := reContainer.FindStringSubmatch(raw); m != nil {
		in.Container = strings.ToLower(m[1])
		raw = raw[:len(raw)-len(m[0])]
	}
	// "H.264" would lose its identity once dots become spaces.
	raw = reDottedCodec.ReplaceAllString(raw, "${1}${2}")

	// The leading tag is the group, not the first word of the title.
	titleFrom := 0
	if m := reBracketGroup.FindStringSubmatch(raw); m != nil {
		in.Group = m[1]
		titleFrom = len(m[0])
	}

	// Bracketed tags carry real metadata in anime releases; flatten them so the
	// token scan sees their contents, then normalise . and _ to spaces.
	flat := reSeparators.ReplaceAllString(flatten(raw), " ")

	if m := reSeasonEp.FindStringSubmatch(flat); m != nil {
		in.Season, _ = strconv.Atoi(m[1])
		in.Episode, _ = strconv.Atoi(m[2])
	} else if m := reXEp.FindStringSubmatch(flat); m != nil {
		in.Season, _ = strconv.Atoi(m[1])
		in.Episode, _ = strconv.Atoi(m[2])
	} else if m := reSeasonWord.FindStringSubmatch(flat); m != nil {
		v := m[1]
		if v == "" {
			v = m[2]
		}
		in.Season, _ = strconv.Atoi(v)
		if e := reAbsEp.FindStringSubmatch(flat); e != nil {
			in.Episode, _ = strconv.Atoi(e[1])
		}
	} else {
		if m := reSeasonOnly.FindStringSubmatch(flat); m != nil {
			in.Season, _ = strconv.Atoi(m[1])
		}
		if m := reAbsEp.FindStringSubmatch(flat); m != nil {
			in.Episode, _ = strconv.Atoi(m[1])
		}
	}
	if m := reYear.FindStringSubmatch(flat); m != nil {
		in.Year, _ = strconv.Atoi(m[1])
	}
	if m := reResolution.FindStringSubmatch(flat); m != nil {
		switch r := strings.ToLower(m[1]); r {
		case "4k", "uhd":
			in.Resolution = "2160p"
		default:
			in.Resolution = r
		}
	}
	if m := reBitDepth.FindStringSubmatch(flat); m != nil {
		in.BitDepth, _ = strconv.Atoi(m[1])
	}

	lower := strings.ToLower(flat)
	in.Remux = strings.Contains(lower, "remux")
	in.Repack = strings.Contains(lower, "repack")
	in.Proper = strings.Contains(lower, "proper")
	in.Atmos = strings.Contains(lower, "atmos")
	in.MultiSub = strings.Contains(lower, "multi sub") || strings.Contains(lower, "multisub") ||
		strings.Contains(lower, "multi-subs") || strings.Contains(lower, "multi subs")
	in.MultiAudio = strings.Contains(lower, "multi audio") || strings.Contains(lower, "dual audio")

	seenLang := map[string]bool{}
	for _, field := range strings.Fields(lower) {
		field = strings.Trim(field, ",;:|/\\-")
		if field == "" {
			continue
		}
		// A token may still carry the group glued on ("h264-ntb"), so the whole
		// token is tried first and its dash-separated parts second.
		toks := []string{field}
		if parts := strings.Split(field, "-"); len(parts) > 1 {
			toks = append(toks, parts...)
		}
		for _, tok := range toks {
			if v, ok := sourceTokens[tok]; ok && in.Source == "" {
				in.Source = v
			}
			if v, ok := videoTokens[tok]; ok && in.VideoCodec == "" {
				in.VideoCodec = v
			}
			if v, ok := audioTokens[tok]; ok && in.AudioCodec == "" {
				in.AudioCodec = v
			}
			if v, ok := hdrTokens[tok]; ok {
				if !contains(in.HDR, v) {
					in.HDR = append(in.HDR, v)
				}
			}
			if v, ok := langTokens[tok]; ok && !seenLang[v] {
				seenLang[v] = true
				in.Languages = append(in.Languages, v)
			}
		}
	}
	if m := reAudioCh.FindStringSubmatch(raw); m != nil {
		if v, ok := audioTokens[strings.ToLower(strings.ReplaceAll(m[1], " ", ""))]; ok {
			in.AudioCodec = v
		}
		in.Channels = m[2] + "." + m[3]
	}
	if in.Channels == "" {
		if m := reChannels.FindStringSubmatch(raw); m != nil {
			in.Channels = m[1] + "." + m[2]
		}
	}
	if in.Remux && in.Source == "" {
		in.Source = "BluRay"
	}

	if in.Group == "" {
		if m := reDashGroup.FindStringSubmatch(strings.TrimSpace(raw)); m != nil {
			in.Group = m[1]
		}
	}
	in.Title = guessTitle(reSeparators.ReplaceAllString(flatten(raw[titleFrom:]), " "))
	return in
}

// guessTitle keeps the words before the first metadata token. A local file is
// looked up in the catalogue by it, so a separator left dangling before the
// episode ("Show - S01E02") is not part of it.
func guessTitle(flat string) string {
	fields := strings.Fields(flat)
	var out []string
	for _, f := range fields {
		t := strings.ToLower(strings.Trim(f, ",;:|/\\-"))
		if _, ok := sourceTokens[t]; ok {
			break
		}
		if _, ok := videoTokens[t]; ok {
			break
		}
		if reResolution.MatchString(t) || reSeasonEp.MatchString(t) || reXEp.MatchString(t) {
			break
		}
		if reYear.MatchString(t) && len(out) > 0 {
			break
		}
		out = append(out, f)
	}
	return strings.TrimRight(strings.Join(out, " "), " -")
}

func flatten(s string) string {
	return strings.NewReplacer("[", " ", "]", " ", "(", " ", ")", " ").Replace(s)
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}
