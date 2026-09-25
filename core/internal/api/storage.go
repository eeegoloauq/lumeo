package api

import (
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
	Dir    string         `json:"dir"`
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
	own, used := library.Usage(rows, s.downloads.Dirs)
	response.Used = used
	for _, row := range rows {
		if row.Locator.Scheme == "file" {
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
	var matches []acquire.Download
	for _, row := range s.downloads.List(r.Context()) {
		if row.Locator.Scheme == "file" {
			continue
		}
		if !oneItem || row.ItemID == wanted {
			matches = append(matches, row)
		}
	}
	if oneItem && len(matches) == 0 {
		writeError(w, http.StatusNotFound, "unknown item")
		return
	}
	var first error
	for _, row := range matches {
		if err := s.downloads.Remove(r.Context(), row.ID, true); err != nil && first == nil {
			first = err
		}
	}
	if first != nil {
		writeError(w, http.StatusInternalServerError, first.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
