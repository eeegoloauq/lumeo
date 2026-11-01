package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
)

// A core linked to a server forwards to it what the server owns: addons,
// sources, downloads, streams, storage and the subtitles of a download. The
// viewer's own data (progress, scores, My list, searches, preferences, the
// copy chosen) stays here, and so does the catalogue, which takes the server
// as its one metadata provider. Item ids are minted by each core, so a
// forwarded request carries the server's id and the answer comes back with
// ours, the two matched by IMDb id. What a server answer would read from the
// viewer's data, this core works out on its own side: it ranks the server's
// copies by its own languages and choice.

// errNoIMDb is a title the server cannot be asked about.
var errNoIMDb = errors.New("item has no IMDb id, the server cannot look it up")

// forwarded is local, or remote when this core forwards to a server.
func (s *Server) forwarded(local, remote http.HandlerFunc) http.HandlerFunc {
	if s.remote != nil {
		return remote
	}
	return local
}

// forward passes the request on as it is.
func (s *Server) forward(w http.ResponseWriter, r *http.Request) {
	s.remote.Forward(w, r, r.URL.Path, nil)
}

// serverID is the server's id for one of ours, and our item.
func (s *Server) serverID(ctx context.Context, localID string) (string, catalog.MediaItem, error) {
	if s.catalog == nil {
		return "", catalog.MediaItem{}, catalog.ErrNoProviders
	}
	found, err := s.catalog.ItemsByIDs(ctx, []string{localID})
	if err != nil {
		return "", catalog.MediaItem{}, err
	}
	if len(found) == 0 {
		return "", catalog.MediaItem{}, catalog.ErrNotFound
	}
	item := found[0]
	if item.IMDbID() == "" {
		return "", item, errNoIMDb
	}
	if id, ok := s.remote.ServerID(item.IMDbID()); ok {
		return id, item, nil
	}
	theirs, err := s.remote.Find(ctx, item.Kind, item.IMDbID())
	return theirs.ID, item, err
}

// localID is our id for one of the server's, the title added to our
// catalogue the first time.
func (s *Server) localID(ctx context.Context, serverID string) (string, error) {
	if s.catalog == nil {
		return "", catalog.ErrNoProviders
	}
	title, ok := s.remote.TitleOf(serverID)
	if !ok {
		item, err := s.remote.Item(ctx, serverID)
		if err != nil {
			return "", err
		}
		if title = (remote.Title{IMDb: item.IMDbID(), Kind: item.Kind}); title.IMDb == "" {
			return "", errNoIMDb
		}
	}
	return s.catalog.IDFor(ctx, catalog.NamespaceIMDb, title.Kind, title.IMDb)
}

// localIDs translates the server's ids, each once; one it cannot translate
// becomes "".
type localIDs struct {
	s    *Server
	seen map[string]string
}

func (s *Server) newLocalIDs() *localIDs { return &localIDs{s: s, seen: make(map[string]string)} }

func (l *localIDs) of(ctx context.Context, serverID string) string {
	if serverID == "" {
		return ""
	}
	if id, ok := l.seen[serverID]; ok {
		return id
	}
	id, err := l.s.localID(ctx, serverID)
	if err != nil {
		// A file the server opened that nothing matched has no title to
		// translate to; that is no failure.
		level := slog.LevelWarn
		if se, ok := errors.AsType[*remote.StatusError](err); ok && se.Code == http.StatusNotFound || errors.Is(err, errNoIMDb) {
			level = slog.LevelDebug
		}
		l.s.log.Log(ctx, level, "translating the server's item id failed", "item", serverID, "err", err)
		id = ""
	}
	l.seen[serverID] = id
	return id
}

// writeRemoteError answers with what went wrong asking the server. Its own
// refusals go to the client as they are, except a refused credential: a 401
// would tell the client its token for this core is wrong.
func (s *Server) writeRemoteError(w http.ResponseWriter, r *http.Request, err error) {
	se, isStatus := errors.AsType[*remote.StatusError](err)
	switch {
	case r.Context().Err() != nil:
		return
	case remote.Unauthorized(err):
		writeError(w, http.StatusBadGateway, remote.RefusedMessage)
	case isStatus:
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(se.Code)
		_, _ = w.Write(se.Body)
	case errors.Is(err, catalog.ErrNotFound):
		writeError(w, http.StatusNotFound, "unknown item")
	case errors.Is(err, errNoIMDb):
		writeError(w, http.StatusUnprocessableEntity, err.Error())
	case errors.Is(err, remote.ErrUnreachable):
		writeError(w, http.StatusBadGateway, remote.ErrUnreachable.Error())
	default:
		s.log.Warn("asking the server failed", "path", r.URL.Path, "err", err)
		writeError(w, http.StatusBadGateway, err.Error())
	}
}

// localDownload says whether a download is this core's: one opened from this
// machine, or begun before the core was linked.
func (s *Server) localDownload(ctx context.Context, id string) bool {
	if s.downloads == nil {
		return false
	}
	_, err := s.downloads.Get(ctx, id)
	return err == nil
}

// eitherDownload serves a download's route here when the download is this
// core's, and from the server otherwise.
func (s *Server) eitherDownload(local, remote http.HandlerFunc) http.HandlerFunc {
	return s.forwarded(local, func(w http.ResponseWriter, r *http.Request) {
		if s.localDownload(r.Context(), r.PathValue("id")) {
			local(w, r)
			return
		}
		remote(w, r)
	})
}

func (s *Server) remoteHealth(w http.ResponseWriter, r *http.Request) {
	var answer struct {
		Providers int `json:"providers"`
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	if err := s.remote.Do(ctx, http.MethodGet, "/healthz", nil, nil, &answer); err != nil {
		answer.Providers = len(s.sources())
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "providers": answer.Providers})
}

// remoteSources lists the server's copies, and the ones on this machine, in
// the order this core's viewer would have them: by their languages and the
// copy they chose. The server says how far it has each copy and whether it
// fits its disk. While the server cannot be asked, the copies here are the
// list and the server is named as the provider that failed.
func (s *Server) remoteSources(w http.ResponseWriter, r *http.Request) {
	params := r.URL.Query()
	season, _ := strconv.Atoi(params.Get("season"))
	episode, _ := strconv.Atoi(params.Get("episode"))
	query := url.Values{"season": {strconv.Itoa(season)}, "episode": {strconv.Itoa(episode)}}
	kind := kindOr(params.Get("kind"), catalog.KindMovie)
	itemID := params.Get("item")
	// The server's id needs the server when it was not seen yet; without it
	// the list is the copies here.
	var lookupErr error
	if itemID != "" {
		serverID, item, err := s.serverID(r.Context(), itemID)
		if err != nil && !errors.Is(err, remote.ErrUnreachable) && !remote.Unauthorized(err) {
			s.writeRemoteError(w, r, err)
			return
		}
		kind, lookupErr = item.Kind, err
		query.Set("item", serverID)
	} else {
		imdb := params.Get("imdb")
		if imdb == "" {
			writeError(w, http.StatusBadRequest, "item or imdb parameter is required")
			return
		}
		if !imdbID.MatchString(imdb) {
			writeError(w, http.StatusBadRequest, "imdb is not an IMDb title id")
			return
		}
		query.Set("imdb", imdb)
		query.Set("kind", string(kind))
	}

	var answer struct {
		Sources   []listedSource   `json:"sources"`
		Failed    []failedProvider `json:"failed"`
		Providers int              `json:"providers"`
	}
	failed := []failedProvider{}
	err := lookupErr
	if err == nil {
		err = s.remote.Do(r.Context(), http.MethodGet, "/api/v1/sources", query, nil, &answer)
	}
	if err != nil {
		if r.Context().Err() != nil {
			return
		}
		if se, ok := errors.AsType[*remote.StatusError](err); ok && se.Code < 500 && se.Code != http.StatusUnauthorized {
			s.writeRemoteError(w, r, err)
			return
		}
		s.log.Warn("asking the server for sources failed", "err", err)
		reason := "no answer"
		if remote.Unauthorized(err) {
			reason = remote.RefusedMessage
		}
		failed = append(failed, failedProvider{Provider: "Server", Reason: reason})
		answer.Providers = 1
	}
	failed = append(failed, answer.Failed...)

	theirs := func(src sources.MediaSource) (listedSource, bool) {
		for _, l := range answer.Sources {
			if l.Locator.Same(src.Locator) {
				return l, true
			}
		}
		return listedSource{}, false
	}
	here := s.onDiskState(r.Context())
	state := func(src sources.MediaSource) string {
		if local := here(src); local != "" {
			return local
		}
		l, _ := theirs(src)
		return l.Local
	}
	fits := func(src sources.MediaSource) bool {
		if src.Locator.Scheme == "file" || here(src) != "" {
			return true
		}
		l, ok := theirs(src)
		return !ok || l.Fits == nil || *l.Fits
	}

	all := make([]sources.MediaSource, 0, len(answer.Sources))
	for _, l := range answer.Sources {
		all = append(all, l.MediaSource)
	}
	if itemID != "" {
		all = append(all, s.onDisk(r.Context(), itemID, season, episode, all)...)
	}
	subs, audio := s.viewerLanguages(r.Context())
	rankSources(all, subs, audio, fits)
	listed := s.preferKnown(r.Context(), itemID, kind == catalog.KindSeries, all, fits, state)
	writeJSON(w, http.StatusOK, map[string]any{"sources": listed, "failed": failed, "providers": answer.Providers})
}

// remoteDownloads is the server's downloads and this core's together, newest
// first. While the server cannot be asked, the list is this core's.
func (s *Server) remoteDownloads(w http.ResponseWriter, r *http.Request) {
	rows := s.serverDownloads(r.Context())
	ids := s.newLocalIDs()
	for i := range rows {
		rows[i].ItemID = ids.of(r.Context(), rows[i].ItemID)
	}
	if s.downloads != nil {
		rows = append(rows, s.downloads.List(r.Context())...)
	}
	slices.SortStableFunc(rows, func(a, b acquire.Download) int { return b.CreatedAt.Compare(a.CreatedAt) })
	writeJSON(w, http.StatusOK, map[string]any{"downloads": rows})
}

// serverDownloads is the server's list, with its ids, or none when it cannot
// be asked.
func (s *Server) serverDownloads(ctx context.Context) []acquire.Download {
	var answer struct {
		Downloads []acquire.Download `json:"downloads"`
	}
	if err := s.remote.Do(ctx, http.MethodGet, "/api/v1/downloads", nil, nil, &answer); err != nil {
		if ctx.Err() == nil {
			s.log.Warn("asking the server for downloads failed", "err", err)
		}
		return []acquire.Download{}
	}
	return answer.Downloads
}

// remoteDownload reads or pauses one of the server's downloads.
func (s *Server) remoteDownload(w http.ResponseWriter, r *http.Request) {
	var body any
	if r.Method == http.MethodPatch {
		var patch map[string]json.RawMessage
		if !readJSON(w, r, &patch) {
			return
		}
		body = patch
	}
	var d acquire.Download
	if err := s.remote.Do(r.Context(), r.Method, r.URL.Path, nil, body, &d); err != nil {
		s.writeRemoteError(w, r, err)
		return
	}
	d.ItemID = s.newLocalIDs().of(r.Context(), d.ItemID)
	writeJSON(w, http.StatusOK, d)
}

// remoteStartDownload starts a copy on the server, unless it is a file on
// this machine or a download this core already has, and keeps the pick here.
func (s *Server) remoteStartDownload(w http.ResponseWriter, r *http.Request) {
	var req startDownloadRequest
	if !readJSON(w, r, &req) {
		return
	}
	if req.Source.Locator.Scheme == "" {
		writeError(w, http.StatusBadRequest, "source.locator is required")
		return
	}
	if s.downloads != nil {
		if _, ok := s.downloads.Find(r.Context(), req.Source.Locator); ok || req.Source.Locator.Scheme == "file" {
			s.startDownload(w, r, req)
			return
		}
	}
	theirs := req
	if req.ItemID != "" {
		serverID, _, err := s.serverID(r.Context(), req.ItemID)
		if err != nil {
			s.writeRemoteError(w, r, err)
			return
		}
		theirs.ItemID = serverID
	}
	var d acquire.Download
	if err := s.remote.Do(r.Context(), http.MethodPost, "/api/v1/downloads", nil, theirs, &d); err != nil {
		s.writeRemoteError(w, r, err)
		return
	}
	s.rememberPick(r.Context(), req)
	d.ItemID = req.ItemID
	writeJSON(w, http.StatusCreated, d)
}

// remoteStorage is the server's storage, by our titles.
func (s *Server) remoteStorage(w http.ResponseWriter, r *http.Request) {
	var answer storageResponse
	if err := s.remote.Do(r.Context(), http.MethodGet, "/api/v1/storage", nil, nil, &answer); err != nil {
		s.writeRemoteError(w, r, err)
		return
	}
	ids := s.newLocalIDs()
	for i := range answer.Titles {
		answer.Titles[i].ItemID = ids.of(r.Context(), answer.Titles[i].ItemID)
	}
	writeJSON(w, http.StatusOK, answer)
}

// remoteClearStorage frees a title, or everything, on the server and of what
// this core still has from before it was linked.
func (s *Server) remoteClearStorage(w http.ResponseWriter, r *http.Request) {
	itemID, oneItem := r.URL.Query()["item"]
	var wanted string
	if oneItem {
		wanted = itemID[0]
	}
	matched := 0
	if s.downloads != nil {
		var err error
		if matched, err = s.clearStorage(r.Context(), wanted, oneItem); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	var query url.Values
	if oneItem {
		serverID, _, err := s.serverID(r.Context(), wanted)
		if err != nil {
			if matched > 0 && (errors.Is(err, catalog.ErrNotFound) || errors.Is(err, errNoIMDb)) {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			s.writeRemoteError(w, r, err)
			return
		}
		query = url.Values{"item": {serverID}}
	}
	err := s.remote.Do(r.Context(), http.MethodDelete, "/api/v1/storage", query, nil, nil)
	if se, ok := errors.AsType[*remote.StatusError](err); ok && se.Code == http.StatusNotFound && matched > 0 {
		err = nil
	}
	if err != nil {
		s.writeRemoteError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// remoteClearCache empties this core's artwork cache and the server's.
func (s *Server) remoteClearCache(w http.ResponseWriter, r *http.Request) {
	if s.artwork != nil {
		if err := s.clearArtwork(r.Context()); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
	}
	if err := s.remote.Do(r.Context(), http.MethodDelete, "/api/v1/cache", nil, nil, nil); err != nil {
		s.writeRemoteError(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// remoteSubtitles asks the server for the subtitles of a title or of one of
// its downloads, in this core's viewer's languages; a file on this machine
// has its subtitles looked up here.
func (s *Server) remoteSubtitles(w http.ResponseWriter, r *http.Request) {
	params := r.URL.Query()
	if id := params.Get("download"); id != "" && s.localDownload(r.Context(), id) {
		s.handleSubtitles(w, r)
		return
	}
	query := url.Values{}
	for _, key := range []string{"kind", "imdb", "season", "episode", "download", "lang"} {
		if value := params.Get(key); value != "" {
			query.Set(key, value)
		}
	}
	if itemID := params.Get("item"); itemID != "" {
		serverID, _, err := s.serverID(r.Context(), itemID)
		if err != nil {
			s.writeRemoteError(w, r, err)
			return
		}
		query.Set("item", serverID)
	}
	if query.Get("lang") == "" && s.prefs != nil {
		if prefs, err := s.prefs.Get(r.Context()); err == nil && len(prefs.SubtitleLanguages) > 0 {
			query.Set("lang", strings.Join(prefs.SubtitleLanguages, ","))
		}
	}
	s.remote.Forward(w, r, r.URL.Path, query)
}

// remoteSubtitleFile serves a track this core found, and forwards the rest.
func (s *Server) remoteSubtitleFile(w http.ResponseWriter, r *http.Request) {
	token, _, _ := strings.Cut(r.PathValue("token"), ".")
	if s.subtitles != nil && s.subtitles.Known(token) {
		s.handleSubtitleFile(w, r)
		return
	}
	s.forward(w, r)
}

// remoteFolders is the releases of a title on the server's disk and on this
// machine's, the one Play continues from by the choice kept here.
func (s *Server) remoteFolders(w http.ResponseWriter, r *http.Request) {
	if !s.haveProgress(w) {
		return
	}
	itemID := r.PathValue("id")
	choice, err := s.progress.Choice(r.Context(), itemID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	var folders []folder
	if s.downloads != nil {
		folders = foldersOf(s.downloads.List(r.Context()), itemID, choice.Pack)
	}
	var answer struct {
		Folders []folder `json:"folders"`
	}
	serverID, _, err := s.serverID(r.Context(), itemID)
	if err == nil {
		err = s.remote.Do(r.Context(), http.MethodGet, "/api/v1/items/"+url.PathEscape(serverID)+"/folders", nil, nil, &answer)
	}
	if err != nil && r.Context().Err() == nil {
		s.log.Warn("asking the server for folders failed", "item", itemID, "err", err)
	}
	for _, f := range answer.Folders {
		f.Current = holds(choice.Pack, f.Source)
		if i := slices.IndexFunc(folders, func(have folder) bool { return folderKey(have.Source) == folderKey(f.Source) }); i >= 0 {
			for _, mark := range f.Episodes {
				if !slices.Contains(folders[i].Episodes, mark) {
					folders[i].Episodes = append(folders[i].Episodes, mark)
				}
			}
			continue
		}
		folders = append(folders, f)
	}
	if folders == nil {
		folders = []folder{}
	}
	sortFolders(folders)
	writeJSON(w, http.StatusOK, map[string]any{"folders": folders, "chosen": choice.Pack != (progress.Pack{})})
}

// KeepWatchedMarks tells the server which of its downloads are of episodes
// watched here, the progress being kept here: the server's keep policy frees
// only what was watched. It compares the two on every change of progress and
// every few minutes, so a mark missed while the server was away is sent once
// it is back. It returns when ctx ends, and at once on a core without a
// server.
func (s *Server) KeepWatchedMarks(ctx context.Context) {
	if s.remote == nil || s.progress == nil {
		return
	}
	ticker := time.NewTicker(watchedEvery)
	defer ticker.Stop()
	for {
		if err := s.syncWatched(ctx); err != nil && ctx.Err() == nil {
			s.log.Warn("telling the server what was watched failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		case <-s.watchedKick:
		}
	}
}

// watchedEvery is how often the marks are compared with nothing changing
// here: the server's own pass runs this often too.
const watchedEvery = 10 * time.Minute

// progressChanged asks for the watched marks to be compared again.
func (s *Server) progressChanged(next http.HandlerFunc) http.HandlerFunc {
	if s.remote == nil {
		return next
	}
	return func(w http.ResponseWriter, r *http.Request) {
		next(w, r)
		select {
		case s.watchedKick <- struct{}{}:
		default:
		}
	}
}

func (s *Server) syncWatched(ctx context.Context) error {
	var answer struct {
		Downloads []acquire.Download `json:"downloads"`
	}
	if err := s.remote.Do(ctx, http.MethodGet, "/api/v1/downloads", nil, nil, &answer); err != nil {
		return err
	}
	entries, err := s.progress.AllProgress(ctx)
	if err != nil {
		return err
	}
	// Watched as the keep policy reads it: the latch with no position. One
	// with a position is a rewatch under way, and its file stays.
	type episode struct {
		item            string
		season, episode int
	}
	watched := make(map[episode]bool)
	for _, e := range entries {
		if e.Watched && e.Position == 0 {
			watched[episode{e.ItemID, e.Season, e.Episode}] = true
		}
	}
	ids := s.newLocalIDs()
	for _, row := range answer.Downloads {
		if row.ItemID == "" {
			continue
		}
		local := ids.of(ctx, row.ItemID)
		if local == "" {
			continue
		}
		want := watched[episode{local, row.Season, row.Episode}]
		if want == !row.WatchedAt.IsZero() {
			continue
		}
		if err := s.remote.Do(ctx, http.MethodPatch, "/api/v1/downloads/"+url.PathEscape(row.ID), nil, map[string]bool{"watched": want}, nil); err != nil {
			return err
		}
	}
	return nil
}
