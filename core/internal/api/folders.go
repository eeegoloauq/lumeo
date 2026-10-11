package api

import (
	"cmp"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/local"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/release"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// folder is one release of a title on disk: a folder of a pack, a run of
// single-episode releases from one group, or a folder on this machine.
type folder struct {
	// Source is one of its copies, sent back to pick the folder.
	Source sources.MediaSource `json:"source"`
	// Folder is the folder inside the pack, Dir the one on this machine.
	Folder       string        `json:"folder,omitempty"`
	Dir          string        `json:"dir,omitempty"`
	Episodes     []episodeMark `json:"episodes"`
	DirectorsCut bool          `json:"directorsCut,omitempty"`
	// Current is the folder Play continues from.
	Current bool `json:"current,omitempty"`
}

type episodeMark struct {
	Season  int `json:"season"`
	Episode int `json:"episode"`
}

// handleFolders lists the releases of a title that are on disk, the one Play
// continues from first. Chosen says whether any release is picked for it at
// all, or Play takes the ranking's best for each episode.
func (s *Server) handleFolders(w http.ResponseWriter, r *http.Request) {
	if !s.haveDownloads(w) || !s.haveProgress(w) {
		return
	}
	itemID := r.PathValue("id")
	choice, err := s.progress.Choice(r.Context(), itemID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"folders": foldersOf(s.downloads.List(r.Context()), itemID, choice.Pack),
		"chosen":  choice.Pack != progress.Pack{},
	})
}

func foldersOf(rows []acquire.Download, itemID string, chosen progress.Pack) []folder {
	byKey := map[string]*folder{}
	var order []string
	// Rows come newest first, so a folder is described by its latest copy.
	for _, row := range rows {
		if row.ItemID != itemID || row.State != acquire.StateDone {
			continue
		}
		src := sources.MediaSource{
			ProviderID: "local",
			RawName:    row.Name,
			Release:    release.Parse(row.Name),
			Size:       row.Size,
			Filename:   row.Name,
			Path:       row.PackPath,
			BingeGroup: row.BingeGroup,
			Locator:    row.Locator,
		}
		key := folderKey(src)
		f, ok := byKey[key]
		if !ok {
			f = &folder{Source: src, Folder: src.Folder(), DirectorsCut: src.DirectorsCut(), Current: holds(chosen, src)}
			if src.Locator.Scheme == "file" {
				f.Folder, f.Dir = "", filepath.Dir(src.Locator.Path)
			}
			byKey[key] = f
			order = append(order, key)
		}
		mark := episodeMark{row.Season, row.Episode}
		if !slices.Contains(f.Episodes, mark) {
			f.Episodes = append(f.Episodes, mark)
		}
	}
	out := make([]folder, 0, len(order))
	for _, key := range order {
		f := byKey[key]
		slices.SortFunc(f.Episodes, func(a, b episodeMark) int {
			return cmp.Or(cmp.Compare(a.Season, b.Season), cmp.Compare(a.Episode, b.Episode))
		})
		out = append(out, *f)
	}
	slices.SortStableFunc(out, func(a, b folder) int {
		if a.Current != b.Current {
			if a.Current {
				return -1
			}
			return 1
		}
		return cmp.Compare(len(b.Episodes), len(a.Episodes))
	})
	return out
}

// folderKey groups the copies on disk the way a choice tells them apart: by
// pack and folder in it, the pack named by its group, or by its torrent when
// the provider gave none; by folder for files on this machine.
func folderKey(src sources.MediaSource) string {
	switch {
	case src.Locator.Scheme == "file":
		return "dir\x00" + filepath.Dir(src.Locator.Path)
	case src.BingeGroup != "":
		return "group\x00" + src.BingeGroup + "\x00" + path.Dir(src.Path)
	case src.Locator.Scheme == "torrent":
		return "torrent\x00" + src.Locator.InfoHash + "\x00" + path.Dir(src.Path)
	}
	return "name\x00" + src.RawName
}

// handleLinkFolder makes the episodes of a series in a folder on this machine
// its copies there, and that folder the one Play continues from.
func (s *Server) handleLinkFolder(w http.ResponseWriter, r *http.Request) {
	if s.local == nil {
		writeError(w, http.StatusServiceUnavailable, "local files are not configured")
		return
	}
	if !s.haveDownloads(w) || !s.haveProgress(w) {
		return
	}
	var body struct {
		Path string `json:"path"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	itemID := r.PathValue("id")
	found, err := s.local.Link(r.Context(), itemID, body.Path)
	switch {
	case errors.Is(err, local.ErrNotFolder):
		writeError(w, http.StatusBadRequest, err.Error())
		return
	case errors.Is(err, os.ErrNotExist):
		writeError(w, http.StatusNotFound, err.Error())
		return
	case err != nil:
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	case found == 0:
		writeError(w, http.StatusUnprocessableEntity, "no episodes of this title in the folder")
		return
	}
	if err := s.progress.RememberSource(r.Context(), itemID, progress.Pack{Dir: filepath.Clean(body.Path), Picked: true}); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	s.handleFolders(w, r)
}

// chosenSource reads the source field of a choice patch: absent leaves the
// pack alone, null goes back to the ranking's best for each episode, and a
// copy makes its pack the one Play continues from.
func chosenSource(raw json.RawMessage) (pack *progress.Pack, err error) {
	if raw == nil {
		return nil, nil
	}
	if string(raw) == "null" {
		return &progress.Pack{}, nil
	}
	var src sources.MediaSource
	if err := json.Unmarshal(raw, &src); err != nil {
		return nil, err
	}
	if src.Locator.Scheme == "" {
		return nil, errors.New("source.locator is required")
	}
	p := packOf(src)
	p.Picked = true
	return &p, nil
}
