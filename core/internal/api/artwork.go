package api

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/addons"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/egress"
)

var artworkLimit int64 = 512 << 20

// artworkClient fetches what addons name, so only on public addresses.
var artworkClient = &http.Client{Transport: egress.Addressed, Timeout: 20 * time.Second}

// artworkURL is where a client fetches an image an addon named: through the
// cache, or as it is when there is no cache. Anything but a web address
// (file:, data:, javascript:) is dropped: an addon's string is not the
// client's to interpret.
func (s *Server) artworkURL(r *http.Request, raw string, urls map[string]string) string {
	if !webURL(raw) {
		return ""
	}
	key := s.artworkKey(raw, urls)
	if key == "" {
		return raw
	}
	return "http://" + r.Host + "/api/v1/artwork/" + key
}

func webURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}

// artworkKey registers raw in urls and returns its key, or "" when raw is
// not something the cache can fetch.
func (s *Server) artworkKey(raw string, urls map[string]string) string {
	if s.artwork == nil || !webURL(raw) {
		return ""
	}
	// Keyed by the token, so a key cannot be worked out from a poster's
	// address: the artwork route asks for nothing else.
	mac := hmac.New(sha256.New, []byte(s.token))
	mac.Write([]byte(raw))
	key := hex.EncodeToString(mac.Sum(nil)[:16])
	urls[key] = raw
	return key
}

func (s *Server) rewriteItem(r *http.Request, item *catalog.MediaItem, urls map[string]string) {
	item.Poster = s.artworkURL(r, item.Poster, urls)
	item.Background = s.artworkURL(r, item.Background, urls)
	item.Logo = s.artworkURL(r, item.Logo, urls)
	item.Episodes = append([]catalog.Episode(nil), item.Episodes...)
	for i := range item.Episodes {
		s.rewriteEpisode(r, &item.Episodes[i], urls)
	}
}

// rewriteEpisode points the still at the cache, with its fallback as ?or=,
// which the artwork route serves when the still itself is missing.
func (s *Server) rewriteEpisode(r *http.Request, e *catalog.Episode, urls map[string]string) {
	thumbnail := s.artworkURL(r, e.Thumbnail, urls)
	if thumbnail != e.Thumbnail {
		if key := s.artworkKey(e.ThumbnailFallback, urls); key != "" {
			thumbnail += "?or=" + key
		}
	}
	e.Thumbnail, e.ThumbnailFallback = thumbnail, ""
}

func (s *Server) rewriteItems(r *http.Request, items []catalog.MediaItem) error {
	urls := make(map[string]string)
	for i := range items {
		s.rewriteItem(r, &items[i], urls)
	}
	return s.registerArtwork(r, urls)
}

func (s *Server) rewriteAddons(r *http.Request, list []addons.Addon) error {
	urls := make(map[string]string)
	for i := range list {
		list[i].Logo = s.artworkURL(r, list[i].Logo, urls)
	}
	return s.registerArtwork(r, urls)
}

func (s *Server) registerArtwork(r *http.Request, urls map[string]string) error {
	if s.artwork == nil {
		return nil
	}
	return s.artwork.RegisterArtwork(r.Context(), urls)
}

func (s *Server) artworkDir() string { return filepath.Join(s.cacheDir, "artwork") }

func (s *Server) handleArtwork(w http.ResponseWriter, r *http.Request) {
	if s.artwork == nil {
		http.NotFound(w, r)
		return
	}
	file, code, err := s.artworkFile(r.Context(), r.PathValue("key"))
	if code == http.StatusNotFound {
		if fallback := r.URL.Query().Get("or"); fallback != "" {
			file, code, err = s.artworkFile(r.Context(), fallback)
		}
	}
	if code == http.StatusNotFound {
		http.NotFound(w, r)
		return
	}
	if err != nil {
		if r.Context().Err() == nil {
			writeError(w, code, err.Error())
		}
		return
	}
	defer file.Close()
	s.serveArtwork(w, r, file)
}

// artworkFile opens the cached file for key, fetching it on first use. The
// status is 404 when the key is unknown or its source has no such image.
func (s *Server) artworkFile(ctx context.Context, key string) (*os.File, int, error) {
	if len(key) != 32 || strings.Trim(key, "0123456789abcdef") != "" {
		return nil, http.StatusNotFound, nil
	}
	raw, missingUntil, err := s.artwork.Artwork(ctx, key)
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	if raw == "" {
		return nil, http.StatusNotFound, nil
	}
	path := filepath.Join(s.artworkDir(), key)
	if file, err := os.Open(path); err == nil {
		return file, http.StatusOK, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, http.StatusInternalServerError, err
	}
	if missingUntil > time.Now().Unix() {
		return nil, http.StatusNotFound, nil
	}
	// One fetch per image however many tiles show it, and it runs on after a
	// client that scrolled past has gone: what it asked for still belongs in
	// the cache, and artworkClient's timeout bounds the fetch.
	code, err := s.artworkFetches.Do(ctx, key, func(ctx context.Context) (int, error) {
		return s.fetchArtwork(ctx, key, raw)
	})
	if err != nil || code != http.StatusOK {
		return nil, code, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	return file, http.StatusOK, nil
}

// fetchArtwork downloads raw into the cache under key, and answers with the
// status artworkFile passes on.
func (s *Server) fetchArtwork(ctx context.Context, key, raw string) (int, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return http.StatusBadGateway, err
	}
	request.Header.Set("User-Agent", egress.UserAgent)
	response, err := artworkClient.Do(request)
	if err != nil {
		return http.StatusBadGateway, err
	}
	defer response.Body.Close()
	if response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusGone {
		if err := s.artwork.MarkArtworkMissing(ctx, key, time.Now().Add(7*24*time.Hour).Unix()); err != nil {
			return http.StatusInternalServerError, err
		}
		return http.StatusNotFound, nil
	}
	if response.StatusCode != http.StatusOK || !strings.HasPrefix(strings.ToLower(response.Header.Get("Content-Type")), "image/") {
		return http.StatusBadGateway, errors.New("invalid artwork response")
	}
	if err := os.MkdirAll(s.artworkDir(), 0o700); err != nil {
		return http.StatusInternalServerError, err
	}
	tmp, err := os.CreateTemp(s.artworkDir(), ".artwork-*")
	if err != nil {
		return http.StatusInternalServerError, err
	}
	defer os.Remove(tmp.Name())
	n, copyErr := io.Copy(tmp, io.LimitReader(response.Body, (20<<20)+1))
	var header [512]byte
	if copyErr == nil && n <= 20<<20 {
		if _, err := tmp.Seek(0, io.SeekStart); err == nil {
			count, readErr := tmp.Read(header[:])
			if readErr != nil && !errors.Is(readErr, io.EOF) {
				copyErr = readErr
			} else if !strings.HasPrefix(http.DetectContentType(header[:count]), "image/") {
				copyErr = errors.New("artwork is not a supported image")
			}
		} else {
			copyErr = err
		}
	}
	closeErr := tmp.Close()
	if copyErr != nil || closeErr != nil || n > 20<<20 {
		return http.StatusBadGateway, errors.New("artwork download failed or exceeded 20 MiB")
	}
	if err := os.Rename(tmp.Name(), filepath.Join(s.artworkDir(), key)); err != nil {
		return http.StatusInternalServerError, err
	}
	if err := s.evictArtwork(key); err != nil {
		s.log.Warn("evicting artwork failed", "err", err)
	}
	return http.StatusOK, nil
}

func (s *Server) serveArtwork(w http.ResponseWriter, r *http.Request, file *os.File) {
	info, err := file.Stat()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	now := time.Now()
	_ = os.Chtimes(file.Name(), now, now) // the eviction order is last use
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	http.ServeContent(w, r, "", info.ModTime(), file)
}

func (s *Server) artworkSize() (int64, error) {
	entries, err := os.ReadDir(s.artworkDir())
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	var size int64
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return 0, err
		}
		size += info.Size()
	}
	return size, nil
}

// evictArtwork removes the least recently used files over the limit, except
// keep: the image just fetched, which its callers open after this returns.
func (s *Server) evictArtwork(keep string) error {
	entries, err := os.ReadDir(s.artworkDir())
	if err != nil {
		return err
	}
	type cached struct {
		name  string
		size  int64
		mtime time.Time
	}
	var files []cached
	var total int64
	for _, entry := range entries {
		if entry.IsDir() || len(entry.Name()) != 32 {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		total += info.Size()
		if entry.Name() != keep {
			files = append(files, cached{entry.Name(), info.Size(), info.ModTime()})
		}
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mtime.Before(files[j].mtime) })
	for _, file := range files {
		if total <= artworkLimit {
			break
		}
		if err := os.Remove(filepath.Join(s.artworkDir(), file.name)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		total -= file.size
	}
	return nil
}

func (s *Server) handleClearCache(w http.ResponseWriter, r *http.Request) {
	if s.artwork == nil {
		writeError(w, http.StatusServiceUnavailable, "artwork cache unavailable")
		return
	}
	if err := os.RemoveAll(s.artworkDir()); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := s.artwork.ResetArtworkMissing(r.Context()); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
