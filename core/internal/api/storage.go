package api

import (
	"context"
	"errors"
	"net/http"
	"os"
	"sort"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/library"
)

type storageDownload struct {
	ID      string        `json:"id"`
	Season  int           `json:"season"`
	Episode int           `json:"episode"`
	Name    string        `json:"name"`
	State   acquire.State `json:"state"`
	OnDisk  int64         `json:"onDisk"`
}

type storageTitle struct {
	ItemID    string            `json:"itemId"`
	Title     string            `json:"title"`
	Poster    string            `json:"poster"`
	Kind      catalog.Kind      `json:"kind"`
	OnDisk    int64             `json:"onDisk"`
	Downloads []storageDownload `json:"downloads"`
}

type storageResponse struct {
	// Dir is where new downloads go, left out for a device of a media
	// server: the folder is its owner's.
	Dir    string         `json:"dir,omitempty"`
	Disk   *library.Disk  `json:"disk,omitempty"`
	Used   int64          `json:"used"`
	Cache  int64          `json:"cache"`
	Titles []storageTitle `json:"titles"`
}

func (s *Server) handleStorage(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	rows := s.downloads.List(r.Context())
	items := make(map[string]catalog.MediaItem)
	if s.catalog != nil {
		var ids []string
		seen := make(map[string]bool)
		for _, row := range rows {
			if row.Locator.Scheme != "file" && row.ItemID != "" && !seen[row.ItemID] {
				seen[row.ItemID] = true
				ids = append(ids, row.ItemID)
			}
		}
		if found, err := s.catalog.ItemsByIDs(r.Context(), ids); err == nil {
			for _, item := range found {
				items[item.ID] = item
			}
		} else {
			s.log.Warn("reading storage metadata failed", "err", err)
		}
	}

	groups := make(map[string]*storageTitle)
	var order []string
	response := storageResponse{Dir: s.downloads.Dir(), Titles: []storageTitle{}}
	size, err := s.artworkSize()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	response.Cache = size
	if disk, err := library.DiskUsage(response.Dir); err == nil {
		response.Disk = &disk
	}
	if !s.viewerHere(r) {
		response.Dir = ""
	}
	own, used := library.Usage(rows, s.downloads.Dirs)
	response.Used = used
	for _, row := range rows {
		// What a device let go of is not its storage any more, though its
		// bytes stay in Used while another device holds it.
		if row.Locator.Scheme == "file" || s.releasedBy(r, row) {
			continue
		}
		onDisk := own[row.ID]
		// A download whose file was deleted outside the app is a record and a
		// few bytes of torrent state, not an episode on disk; listing it kept
		// the episode count as it was. Its bytes stay in Used: Free all frees them.
		// An empty FilePath is not "deleted": a crash can lose it after bytes landed.
		if row.FilePath != "" && row.State != acquire.StateActive {
			if _, err := os.Stat(row.FilePath); errors.Is(err, os.ErrNotExist) {
				continue
			}
		}
		key := row.ItemID
		if key == "" {
			key = "\x00" + row.ID
		}
		group := groups[key]
		if group == nil {
			group = &storageTitle{ItemID: row.ItemID, Title: row.Name, Downloads: []storageDownload{}}
			if item, ok := items[row.ItemID]; ok {
				group.Title, group.Poster, group.Kind = item.Title, item.Poster, item.Kind
			}
			groups[key] = group
			order = append(order, key)
		}
		group.OnDisk += onDisk
		group.Downloads = append(group.Downloads, storageDownload{
			ID: row.ID, Season: row.Season, Episode: row.Episode, Name: row.Name, State: row.State, OnDisk: onDisk,
		})
	}
	for _, key := range order {
		response.Titles = append(response.Titles, *groups[key])
	}
	sort.SliceStable(response.Titles, func(i, j int) bool { return response.Titles[i].OnDisk > response.Titles[j].OnDisk })
	urls := make(map[string]string)
	for i := range response.Titles {
		response.Titles[i].Poster = s.artworkURL(r, response.Titles[i].Poster, urls)
	}
	if err := s.registerArtwork(r, urls); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleClearStorage(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) {
		return
	}
	itemID, oneItem := r.URL.Query()["item"]
	var wanted string
	if oneItem {
		wanted = itemID[0]
	}
	if !s.viewerHere(r) {
		s.releaseStorage(w, r, wanted, oneItem)
		return
	}
	matched, err := s.clearStorage(r.Context(), wanted, oneItem)
	if oneItem && matched == 0 {
		writeError(w, http.StatusNotFound, "unknown item")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// clearStorage deletes the downloads of one title, or of all when oneItem is
// false, with their data; files on this machine stay. matched is how many
// there were, and err the first removal that failed.
func (s *Server) clearStorage(ctx context.Context, itemID string, oneItem bool) (matched int, err error) {
	var matches []acquire.Download
	for _, row := range s.downloads.List(ctx) {
		if row.Locator.Scheme == "file" {
			continue
		}
		if !oneItem || row.ItemID == itemID {
			matches = append(matches, row)
		}
	}
	for _, row := range matches {
		if removeErr := s.downloads.Remove(ctx, row.ID, true); removeErr != nil && err == nil {
			err = removeErr
		}
	}
	return len(matches), err
}

// releaseStorage lets a device of this media server go of the downloads of
// one title, or of all it holds or could, as deleting each would: the
// owner's own stay, and a title of nothing else is refused.
func (s *Server) releaseStorage(w http.ResponseWriter, r *http.Request, itemID string, oneItem bool) {
	matched, released := 0, 0
	var failed error
	for _, row := range s.downloads.List(r.Context()) {
		if row.Locator.Scheme == "file" || oneItem && row.ItemID != itemID || s.releasedBy(r, row) {
			continue
		}
		matched++
		switch err := s.releaseDownload(r.Context(), row.ID, deviceOf(r)); {
		case err == nil:
			released++
		case errors.Is(err, acquire.ErrNotHeld), errors.Is(err, acquire.ErrNotFound):
		case failed == nil:
			failed = err
		}
	}
	switch {
	case failed != nil:
		writeError(w, http.StatusInternalServerError, failed.Error())
	case oneItem && matched == 0:
		writeError(w, http.StatusNotFound, "unknown item")
	case oneItem && released == 0:
		writeError(w, http.StatusForbidden, errOwnersDownload)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
