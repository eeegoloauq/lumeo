package subtitles

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/release"
)

const (
	// keepEvery is how often a pass looks for downloads without their
	// subtitles. A pass with nothing to do reads one small file a download.
	keepEvery = time.Minute
	// retryNone is how long a language no provider had is left before it is
	// asked for again: uploads for a new episode come in over days.
	retryNone = 24 * time.Hour
	// keepHashWait bounds the wait for the ends of a file still arriving; a
	// later pass tries again.
	keepHashWait = 10 * time.Second
	// lookupsPerPass keeps a library's first pass, after an update or a
	// long time offline, from asking a provider about every download at once.
	lookupsPerPass = 5
	indexName      = "subtitles.json"
)

// Downloads is what the Keeper needs of the download manager.
type Downloads interface {
	List(context.Context) []acquire.Download
	File(ctx context.Context, id string, wait time.Duration) (acquire.File, error)
	Extras(id string, fn func(dir string) error) error
}

// Items turns a download's item id into what a provider looks subtitles up by.
type Items interface {
	Item(context.Context, string) (catalog.MediaItem, error)
}

// Keeper keeps subtitles with each download, so they play offline and do not
// wait on a provider at every open: once a download knows its file, the best
// match for each wanted language, by the file's hash, is fetched once, made
// UTF-8 like any other (Service.fetch) and written to the download's extras
// directory, which goes with it. Names are ours, never the provider's.
type Keeper struct {
	service   *Service
	downloads Downloads
	items     Items
	// languages are the ones wanted for a title, best first.
	languages func(ctx context.Context, itemID string) []string
	log       *slog.Logger
	now       func() time.Time

	// While no provider answers, passes back off from a minute to an hour.
	failures int
	resume   time.Time
}

// errNoAnswer is a lookup no provider answered.
var errNoAnswer = errors.New("subtitles: no provider answered")

func NewKeeper(service *Service, downloads Downloads, items Items, languages func(context.Context, string) []string, log *slog.Logger) *Keeper {
	return &Keeper{service: service, downloads: downloads, items: items, languages: languages, log: log, now: time.Now}
}

// Run keeps subtitles at start and every keepEvery until ctx ends.
func (k *Keeper) Run(ctx context.Context) {
	ticker := time.NewTicker(keepEvery)
	defer ticker.Stop()
	for {
		k.Pass(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// Pass keeps what is missing for every download. A download that cannot be
// served yet (no file, the ends not arrived, no provider answering) is left
// for a later pass.
func (k *Keeper) Pass(ctx context.Context) {
	// No provider says nothing about any language: not recorded as missing.
	if len(k.service.providers()) == 0 || k.now().Before(k.resume) {
		return
	}
	lookups := 0
	for _, d := range k.downloads.List(ctx) {
		if ctx.Err() != nil || lookups == lookupsPerPass {
			return
		}
		asked, err := k.keep(ctx, d)
		if errors.Is(err, errNoAnswer) {
			k.failures++
			k.resume = k.now().Add(min(keepEvery<<k.failures, time.Hour))
			k.log.Debug("keeping subtitles", "download", d.ID, "err", err, "resume", k.resume)
			return
		}
		if asked {
			lookups++
			k.failures = 0
		}
		if err != nil {
			k.log.Debug("keeping subtitles", "download", d.ID, "err", err)
		}
	}
}

// index is what a download's extras directory says about its subtitles.
type index struct {
	Files []keptFile `json:"files"`
	// Tried is when a language was last asked for and no provider had it.
	Tried map[string]time.Time `json:"tried,omitempty"`
}

type keptFile struct {
	Subtitle
	File string `json:"file"`
}

// keep keeps what d is missing, and says whether it asked the providers.
func (k *Keeper) keep(ctx context.Context, d acquire.Download) (bool, error) {
	dir := d.ExtrasDir()
	if dir == "" || d.ItemID == "" || d.FilePath == "" || d.State == acquire.StateFailed {
		return false, nil
	}
	idx, err := readIndex(dir)
	if err != nil {
		return false, err
	}
	var missing []string
	for _, lang := range k.languages(ctx, d.ItemID) {
		kept := slices.ContainsFunc(idx.Files, func(f keptFile) bool { return f.Language == lang })
		if !kept && k.now().Sub(idx.Tried[lang]) >= retryNone && !slices.Contains(missing, lang) {
			missing = append(missing, lang)
		}
	}
	if len(missing) == 0 {
		return false, nil
	}

	file, err := k.downloads.File(ctx, d.ID, 0)
	if err != nil {
		return false, nil // nothing to hash yet
	}
	hash, err := hashFile(ctx, file)
	if err != nil {
		return false, nil // the ends are still on their way
	}
	item, err := k.items.Item(ctx, d.ItemID)
	if err != nil {
		return false, err
	}
	if item.IMDbID() == "" {
		return false, nil
	}
	found, err := k.service.find(ctx, Query{
		Kind:        item.Kind,
		IMDbID:      item.IMDbID(),
		Season:      d.Season,
		Episode:     d.Episode,
		Filename:    filepath.Base(file.Path()),
		VideoSize:   file.Size(),
		VideoHash:   hash,
		Release:     release.Parse(d.Name),
		ReleaseName: d.Name,
		Languages:   missing,
	})
	if err != nil {
		return true, fmt.Errorf("%w: %w", errNoAnswer, err)
	}

	type fetched struct {
		sub  Subtitle
		text Text
	}
	var got []fetched
	var none []string
	for _, lang := range missing {
		i := slices.IndexFunc(found, func(s Subtitle) bool { return languageRank(s.Language, map[string]int{lang: 0}) == 0 })
		if i < 0 {
			none = append(none, lang)
			continue
		}
		sub := found[i]
		text, err := k.service.fetch(ctx, sub)
		if err != nil {
			k.log.Debug("fetching a subtitle to keep", "download", d.ID, "err", err)
			continue
		}
		// Recorded under the language asked for: a regional variant kept for
		// it answers for it.
		sub.Language = lang
		got = append(got, fetched{sub, text})
	}
	if len(got) == 0 && len(none) == 0 {
		return true, nil
	}

	// Written with the download held, and the index read again there: a
	// Remove since deletes the directory rather than meeting new files in it.
	return true, k.downloads.Extras(d.ID, func(dir string) error {
		idx, err := readIndex(dir)
		if err != nil {
			return err
		}
		if idx.Tried == nil {
			idx.Tried = map[string]time.Time{}
		}
		for _, lang := range none {
			idx.Tried[lang] = k.now()
		}
		for _, f := range got {
			name := fmt.Sprintf("%d.%s", len(idx.Files)+1, extension(f.text.Format))
			if err := writeFile(filepath.Join(dir, name), f.text.Body); err != nil {
				return err
			}
			f.sub.Format, f.sub.URL, f.sub.SourceURL, f.sub.Encoding = f.text.Format, "", "", ""
			idx.Files = append(idx.Files, keptFile{Subtitle: f.sub, File: name})
			delete(idx.Tried, f.sub.Language)
		}
		body, err := json.Marshal(idx)
		if err != nil {
			return err
		}
		return writeFile(filepath.Join(dir, indexName), body)
	})
}

func hashFile(ctx context.Context, file acquire.File) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, keepHashWait)
	defer cancel()
	r, err := file.Open(ctx)
	if err != nil {
		return "", err
	}
	defer r.Close()
	return Hash(r, file.Size())
}

// Kept is the subtitles kept in a download's extras directory, their URL the
// path the API serves them at under prefix.
func Kept(dir, prefix string) []Subtitle {
	if dir == "" {
		return nil
	}
	idx, err := readIndex(dir)
	if err != nil {
		return nil
	}
	var out []Subtitle
	for _, f := range idx.Files {
		if _, err := os.Stat(filepath.Join(dir, f.File)); err != nil {
			continue
		}
		sub := f.Subtitle
		sub.Kept, sub.URL = true, prefix+f.File
		out = append(out, sub)
	}
	return out
}

// KeptFile is the path and format of a kept subtitle by the name Kept gave
// it; only names the index lists are answered.
func KeptFile(dir, name string) (path, format string, ok bool) {
	if dir == "" {
		return "", "", false
	}
	idx, err := readIndex(dir)
	if err != nil {
		return "", "", false
	}
	for _, f := range idx.Files {
		if f.File == name {
			return filepath.Join(dir, f.File), f.Format, true
		}
	}
	return "", "", false
}

func readIndex(dir string) (index, error) {
	var idx index
	body, err := os.ReadFile(filepath.Join(dir, indexName))
	if errors.Is(err, fs.ErrNotExist) {
		return idx, nil
	}
	if err != nil {
		return idx, err
	}
	return idx, json.Unmarshal(body, &idx)
}

// writeFile writes whole or not at all, and never executable.
func writeFile(path string, body []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	_, err = tmp.Write(body)
	if err = errors.Join(err, tmp.Sync(), tmp.Close()); err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		os.Remove(tmp.Name())
	}
	return err
}

// extension is a file name's ending from the few formats the player reads; a
// provider's word for the format never reaches a file name.
func extension(format string) string {
	switch format {
	case "vtt", "ass", "ssa", "sub":
		return format
	default:
		return "srt"
	}
}
