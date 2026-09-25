package stremio

import (
	"context"
	"fmt"
	"path"
	"strconv"
	"strings"

	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
)

var _ subtitles.Provider = (*Addon)(nil)

type subtitleObject struct {
	ID   string `json:"id"`
	URL  string `json:"url"`
	Lang string `json:"lang"`
	// The v3 OpenSubtitles addon states the code page of the file it links
	// to, which is the one thing that makes pre-Unicode subtitles readable.
	SubEncoding string `json:"SubEncoding"`
	// Match is that addon's word for how it found this file: "h" means the
	// hash of the video matched, "i" that only the title did. Not in the
	// protocol, and the most useful thing in the response.
	Match string `json:"m"`
	// The release the file was timed for, and what it was called. Also
	// outside the protocol; addons that have them send them.
	MovieReleaseName string  `json:"movieReleaseName"`
	SubtitleFileName string  `json:"subtitleFileName"`
	ReleaseGroup     string  `json:"releaseGroup"`
	FPSMilli         float64 `json:"fpsMilli"`
	Title            string  `json:"title"`
	Name             string  `json:"name"`
	Filename         string  `json:"filename"`
}

// Subtitles asks the addon's subtitles resource. The extras carry the file
// being played — its hash, its size, its name — because a subtitle database
// keyed by hash answers with tracks timed to this exact encode, and one keyed
// by title answers with everything anyone ever uploaded for the film.
func (a *Addon) Subtitles(ctx context.Context, q subtitles.Query) ([]subtitles.Subtitle, error) {
	if q.IMDbID == "" {
		return nil, fmt.Errorf("stremio: subtitle query needs an IMDb id")
	}
	id := q.IMDbID
	if q.Kind == catalog.KindSeries {
		id = fmt.Sprintf("%s:%d:%d", q.IMDbID, q.Season, q.Episode)
	}
	u := fmt.Sprintf("%s/subtitles/%s/%s%s.json", a.baseURL, q.Kind, id, subtitleExtras(q))

	var body struct {
		Subtitles []subtitleObject `json:"subtitles"`
	}
	if err := a.getJSON(ctx, u, &body); err != nil {
		return nil, err
	}

	out := make([]subtitles.Subtitle, 0, len(body.Subtitles))
	for _, s := range body.Subtitles {
		if s.URL == "" {
			continue
		}
		lang := subtitles.Language(s.Lang)
		out = append(out, subtitles.Subtitle{
			ProviderID:   a.id,
			ID:           s.ID,
			Language:     lang,
			LanguageName: subtitles.LanguageName(lang),
			Name: firstNonEmpty(s.MovieReleaseName, s.SubtitleFileName,
				s.Title, s.Name, s.Filename),
			Format:    firstNonEmpty(subtitleFormat(s.URL), subtitleFormat(s.SubtitleFileName)),
			HashMatch: strings.EqualFold(s.Match, "h"),
			FPS:       s.FPSMilli / 1000,
			SourceURL: s.URL,
			Encoding:  s.SubEncoding,
		})
	}
	return out, nil
}

// subtitleExtras is the same path-embedded querystring the catalog resource
// uses, with the keys the subtitles resource defines.
func subtitleExtras(q subtitles.Query) string {
	var parts []string
	if q.VideoHash != "" {
		parts = append(parts, "videoHash="+escapeExtra(q.VideoHash))
	}
	if q.VideoSize > 0 {
		parts = append(parts, "videoSize="+strconv.FormatInt(q.VideoSize, 10))
	}
	if q.Filename != "" {
		parts = append(parts, "filename="+escapeExtra(q.Filename))
	}
	if len(parts) == 0 {
		return ""
	}
	return "/" + strings.Join(parts, "&")
}

func subtitleFormat(rawURL string) string {
	if i := strings.IndexAny(rawURL, "?#"); i >= 0 {
		rawURL = rawURL[:i]
	}
	switch ext := strings.TrimPrefix(strings.ToLower(path.Ext(rawURL)), "."); ext {
	case "srt", "vtt", "ass", "ssa", "sub":
		return ext
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v = strings.TrimSpace(v); v != "" {
			return v
		}
	}
	return ""
}
