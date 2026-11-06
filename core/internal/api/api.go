// Package api is the only way anything talks to the core. The desktop client
// uses it over localhost, a remote client over the network — same handlers,
// which is what makes server mode a deployment choice rather than a rewrite.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	"github.com/eeegoloauq/lumeo/core/internal/addons"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/flight"
	"github.com/eeegoloauq/lumeo/core/internal/library"
	"github.com/eeegoloauq/lumeo/core/internal/local"
	"github.com/eeegoloauq/lumeo/core/internal/personal"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
	"github.com/eeegoloauq/lumeo/core/internal/remote"
	"github.com/eeegoloauq/lumeo/core/internal/searches"
	"github.com/eeegoloauq/lumeo/core/internal/sources"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
	"github.com/eeegoloauq/lumeo/core/internal/update"
	"github.com/eeegoloauq/lumeo/core/internal/watchlist"
)

type Server struct {
	sources     func() []sources.Provider
	catalog     *catalog.Service
	downloads   *acquire.Manager
	library     *library.Service
	local       *local.Service
	addr        string
	subtitles   *subtitles.Service
	prefs       *preferences.Service
	progress    *progress.Service
	watchlist   *watchlist.Service
	ratings     *ratings.Service
	addons      *addons.Service
	searches    *searches.Service
	personal    *personal.Service
	about       About
	updates     *update.Checker
	token       string
	publicURL   string
	devices     *store.DB
	certificate []byte
	pairMu      sync.Mutex
	pairCode    string
	pairUntil   time.Time
	log         *slog.Logger
	artwork     *store.DB
	cacheDir    string
	dataDir     string
	remote      *remote.Server
	// mode is remote.ModeMedia on a server that leaves its devices'
	// personal data on them (mode.go).
	mode string
	// holdsKick asks KeepHolds for a pass.
	holdsKick chan struct{}
	// artworkFetches joins the requests for an image not cached yet.
	artworkFetches *flight.Group[int]

	// hashes remembers the video hash of a download. Computing it reads the
	// last 64 KiB of a file that is arriving front to back, so it is worth
	// doing once and never again: the bytes behind a download never change.
	hashMu sync.Mutex
	hashes map[string]string
}

// About is what the core says about itself to a settings screen: facts
// about the machine it runs on that a client cannot know from its own side.
type About struct {
	// Version is the release this core was built as, "dev" otherwise. A client
	// compares it with its own: the launcher reuses any core already on the
	// port, which after an update can be the previous release.
	Version string `json:"version"`
	// Addr is the address the core listens on.
	Addr    string `json:"addr"`
	DataDir string `json:"dataDir,omitempty"`
	// DownloadDir is where new downloads go; a core with downloads answers
	// with theirs, which the preferences can move while it runs.
	DownloadDir string `json:"downloadDir,omitempty"`
	// Linked is a core forwarding to a media server, where its downloads go
	// and which keeps them by this device's keep rules: its own folder,
	// limits and keep policy hold nothing new.
	Linked bool `json:"linked,omitempty"`
	// LogPath is the file the core's log goes to, when it is one; a log
	// that goes to the journal or a terminal has no path to show.
	LogPath string `json:"logPath,omitempty"`
}

// Deps is what the server is built on. Every service is optional: a core
// without a catalog still serves sources, one without an acquisition backend
// still browses, and a route whose service is missing says so with a 503.
type Deps struct {
	// Sources are asked for on every request: the addon list is edited
	// while the core runs.
	Sources     func() []sources.Provider
	Catalog     *catalog.Service
	Downloads   *acquire.Manager
	Library     *library.Service
	Local       *local.Service
	Addr        string
	Subtitles   *subtitles.Service
	Preferences *preferences.Service
	Progress    *progress.Service
	Watchlist   *watchlist.Service
	Ratings     *ratings.Service
	Addons      *addons.Service
	Searches    *searches.Service
	Personal    *personal.Service
	About       About
	Updates     *update.Checker
	// Token is what every request but artwork has to present, as
	// "Authorization: Bearer <token>". Empty turns the check off, which only
	// tests do; the core does not start without one.
	Token string
	// PublicURL is a validated external HTTPS origin. Forwarded headers are
	// ignored: direct callers must not choose the public origin.
	PublicURL string
	Devices   *store.DB
	Artwork   *store.DB
	CacheDir  string
	// DataDir holds the link to a server (remote.FileName), which the
	// client sets through /link; empty refuses those routes.
	DataDir string
	// Remote is the server this core forwards to, nil for one that holds
	// everything itself (remote.go).
	Remote *remote.Server
	// Mode is "media" for a server whose devices keep their viewers' data
	// themselves; "full" or empty keeps it here.
	Mode string
	// Certificate is the DER of the core's own TLS certificate, nil when it
	// serves plain HTTP: pairing binds the code to it (remote.DeviceProof).
	Certificate []byte
}

func New(deps Deps, log *slog.Logger) *Server {
	if deps.Sources == nil {
		deps.Sources = func() []sources.Provider { return nil }
	}
	return &Server{
		sources:     deps.Sources,
		catalog:     deps.Catalog,
		downloads:   deps.Downloads,
		library:     deps.Library,
		local:       deps.Local,
		addr:        deps.Addr,
		subtitles:   deps.Subtitles,
		prefs:       deps.Preferences,
		progress:    deps.Progress,
		watchlist:   deps.Watchlist,
		ratings:     deps.Ratings,
		addons:      deps.Addons,
		searches:    deps.Searches,
		personal:    deps.Personal,
		about:       deps.About,
		updates:     deps.Updates,
		token:       deps.Token,
		publicURL:   deps.PublicURL,
		certificate: deps.Certificate,
		devices:     deps.Devices,
		log:         log,
		artwork:     deps.Artwork,
		cacheDir:    deps.CacheDir,
		dataDir:     deps.DataDir,
		hashes:      make(map[string]string),
		remote:      deps.Remote,
		mode:        deps.Mode,

		holdsKick: make(chan struct{}, 1),

		artworkFetches: flight.New[int](),
	}
}

// Close cancels the fetches still running behind requests that have
// answered, and waits for them: they write to the store.
func (s *Server) Close() {
	s.artworkFetches.Close()
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/pairings", s.handlePairing)
	mux.HandleFunc("GET /api/v1/devices", s.handleDevices)
	mux.HandleFunc("DELETE /api/v1/devices/{id}", s.handleRevokeDevice)
	mux.HandleFunc("GET /api/v1/link", s.handleLink)
	mux.HandleFunc("PUT /api/v1/link", s.handlePutLink)
	mux.HandleFunc("PATCH /api/v1/link", s.handleUseLink)
	mux.HandleFunc("DELETE /api/v1/link", s.handleUnlink)
	mux.HandleFunc("GET /healthz", s.forwarded(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "providers": len(s.sources())})
	}, s.remoteHealth))
	mux.HandleFunc("GET /api/v1/catalogs", s.handleCatalogs)
	mux.HandleFunc("GET /api/v1/catalog", s.handleCatalog)
	mux.HandleFunc("GET /api/v1/search", s.handleSearch)
	mux.HandleFunc("GET /api/v1/searches", s.viewerData(s.handleSearches))
	mux.HandleFunc("POST /api/v1/searches", s.viewerData(s.handleRecordSearch))
	mux.HandleFunc("DELETE /api/v1/searches", s.viewerData(s.handleForgetSearches))
	mux.HandleFunc("GET /api/v1/find", s.handleFind)
	mux.HandleFunc("GET /api/v1/items/{id}", s.handleItem)
	mux.HandleFunc("GET /api/v1/items/{id}/after", s.handleEpisodeAfter)
	mux.HandleFunc("GET /api/v1/items/{id}/folders", s.forwarded(s.handleFolders, s.remoteFolders))
	mux.HandleFunc("POST /api/v1/items/{id}/folders", s.viewerData(s.handleLinkFolder))
	mux.HandleFunc("GET /api/v1/sources", s.forwarded(s.handleSources, s.remoteSources))
	mux.HandleFunc("GET /api/v1/subtitles", s.forwarded(s.handleSubtitles, s.remoteSubtitles))
	mux.HandleFunc("GET /api/v1/subtitles/{token}", s.forwarded(s.handleSubtitleFile, s.remoteSubtitleFile))
	mux.HandleFunc("GET /api/v1/downloads/{id}/subtitles", s.eitherDownload(s.handleKeptSubtitles, s.forward))
	mux.HandleFunc("GET /api/v1/downloads/{id}/subtitles/{file}", s.eitherDownload(s.handleKeptSubtitle, s.forward))
	mux.HandleFunc("GET /api/v1/preferences", s.viewerData(s.handlePreferences))
	mux.HandleFunc("PATCH /api/v1/preferences", s.viewerData(s.holdsChange(s.handlePatchPreferences)))
	mux.HandleFunc("DELETE /api/v1/preferences", s.viewerData(s.holdsChange(s.handleResetPreferences)))
	mux.HandleFunc("GET /api/v1/preferences/languages", s.handlePreferenceLanguages)
	mux.HandleFunc("GET /api/v1/about", s.handleAbout)
	mux.HandleFunc("GET /api/v1/update", s.handleUpdate)
	mux.HandleFunc("GET /api/v1/storage", s.forwarded(s.handleStorage, s.remoteStorage))
	mux.HandleFunc("DELETE /api/v1/cache", s.forwarded(s.handleClearCache, s.remoteClearCache))
	mux.HandleFunc("DELETE /api/v1/storage", s.forwarded(s.handleClearStorage, s.remoteClearStorage))
	mux.HandleFunc("PUT /api/v1/progress/{id}", s.viewerData(s.holdsChange(s.handlePutProgress)))
	mux.HandleFunc("GET /api/v1/progress/{id}", s.viewerData(s.handleProgress))
	mux.HandleFunc("POST /api/v1/progress/{id}/watched-through", s.viewerData(s.holdsChange(s.handleWatchedThrough)))
	mux.HandleFunc("DELETE /api/v1/progress/{id}", s.viewerData(s.holdsChange(s.handleDeleteProgress)))
	mux.HandleFunc("GET /api/v1/continue", s.viewerData(s.handleContinue))
	mux.HandleFunc("DELETE /api/v1/continue/{id}", s.viewerData(s.handleHideFromContinue))
	mux.HandleFunc("GET /api/v1/history", s.viewerData(s.handleHistory))
	mux.HandleFunc("GET /api/v1/finished", s.viewerData(s.handleFinished))
	mux.HandleFunc("GET /api/v1/personal", s.viewerData(s.handleExportPersonal))
	mux.HandleFunc("POST /api/v1/personal", s.viewerData(s.holdsChange(s.handleImportPersonal)))
	mux.HandleFunc("GET /api/v1/list", s.viewerData(s.handleList))
	mux.HandleFunc("GET /api/v1/list/{id}", s.viewerData(s.handleListEntry))
	mux.HandleFunc("PUT /api/v1/list/{id}", s.viewerData(s.handleAddToList))
	mux.HandleFunc("DELETE /api/v1/list/{id}", s.viewerData(s.handleRemoveFromList))
	mux.HandleFunc("GET /api/v1/new-episodes", s.viewerData(s.shelf((*watchlist.Service).NewEpisodes)))
	mux.HandleFunc("GET /api/v1/coming-up", s.viewerData(s.shelf((*watchlist.Service).ComingUp)))
	mux.HandleFunc("GET /api/v1/ratings/{id}", s.viewerData(s.handleRatings))
	// A score marks what was scored as watched (markScored).
	mux.HandleFunc("PUT /api/v1/ratings/{id}", s.viewerData(s.holdsChange(s.handleRate)))
	mux.HandleFunc("DELETE /api/v1/ratings/{id}", s.viewerData(s.handleUnrate))
	mux.HandleFunc("GET /api/v1/choices/{id}", s.viewerData(s.handleChoice))
	// A subtitle track picked is a language to keep with the downloads.
	mux.HandleFunc("PATCH /api/v1/choices/{id}", s.viewerData(s.holdsChange(s.handlePatchChoice)))
	mux.HandleFunc("GET /api/v1/addons", s.forwarded(s.handleAddons, s.forward))
	mux.HandleFunc("POST /api/v1/addons", s.forwarded(s.handleAddAddon, s.forward))
	mux.HandleFunc("PATCH /api/v1/addons/{id}", s.forwarded(s.handlePatchAddon, s.forward))
	mux.HandleFunc("DELETE /api/v1/addons/{id}", s.forwarded(s.handleRemoveAddon, s.forward))
	mux.HandleFunc("POST /api/v1/downloads", s.forwarded(s.handleStartDownload, s.remoteStartDownload))
	mux.HandleFunc("POST /api/v1/local", s.viewerData(s.handleLocal))
	mux.HandleFunc("GET /api/v1/downloads", s.forwarded(s.handleDownloads, s.remoteDownloads))
	mux.HandleFunc("GET /api/v1/downloads/{id}", s.eitherDownload(s.handleDownload, s.remoteDownload))
	mux.HandleFunc("PATCH /api/v1/downloads/{id}", s.eitherDownload(s.handlePatchDownload, s.remoteDownload))
	mux.HandleFunc("PUT /api/v1/downloads/{id}/hold", s.handlePutHold)
	mux.HandleFunc("DELETE /api/v1/downloads/{id}", s.eitherDownload(s.handleRemoveDownload, s.forward))
	// GET also serves HEAD, which players use to learn the size before they
	// commit to a byte range.
	mux.HandleFunc("GET /api/v1/downloads/{id}/stream", s.eitherDownload(s.handleStream, s.forward))
	root := http.NewServeMux()
	root.HandleFunc("POST /api/v1/pair", s.handlePair)
	// Artwork is the one route without the token: an image widget fetches
	// it by address alone. The address is the credential instead, its key an
	// HMAC under the token (artworkKey), so only a client that listed a title
	// knows where its pictures are.
	root.HandleFunc("GET /api/v1/artwork/{key}", s.handleArtwork)
	root.Handle("/", s.requireToken(mux))
	// A browser must not be a way in either. A page on another site cannot
	// read the token, so its requests fail it; this refuses them before that
	// (Sec-Fetch-Site, Origin), whatever the route, as a second wall. The
	// client and mpv are not browsers and send neither header.
	var handler http.Handler = http.NewCrossOriginProtection().Handler(root)
	// And on loopback only loopback names: a page that rebinds its own domain
	// to 127.0.0.1 would otherwise read the API, local files included.
	listenHost, _, err := net.SplitHostPort(s.addr)
	if ip := net.ParseIP(listenHost); err != nil || listenHost != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return s.stampMode(handler)
	}
	publicHost := ""
	if public, err := url.Parse(s.publicURL); err == nil {
		publicHost = public.Hostname()
	}
	return s.stampMode(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host := r.Host
		if h, _, err := net.SplitHostPort(host); err == nil {
			host = h
		}
		host = strings.Trim(host, "[]")
		if host != "localhost" && host != "127.0.0.1" && host != "::1" &&
			(publicHost == "" || !strings.EqualFold(host, publicHost)) {
			writeError(w, http.StatusForbidden, "invalid host")
			return
		}
		handler.ServeHTTP(w, r)
	}))
}

// requireToken lets through the requests that carry the token.
func (s *Server) requireToken(next http.Handler) http.Handler {
	if s.token == "" {
		return next
	}
	want := []byte("Bearer " + s.token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		valid := subtle.ConstantTimeCompare(got, want) == 1
		if !valid && s.devices != nil && strings.HasPrefix(string(got), "Bearer ") {
			device, found, err := s.devices.DeviceByToken(r.Context(), strings.TrimPrefix(string(got), "Bearer "))
			if err != nil {
				s.log.Error("check device token", "err", err)
				writeError(w, http.StatusServiceUnavailable, "authentication unavailable")
				return
			}
			if valid = found; valid {
				r = r.WithContext(context.WithValue(r.Context(), deviceKey{}, device))
			}
		}
		if !valid {
			w.Header().Set("WWW-Authenticate", "Bearer")
			writeError(w, http.StatusUnauthorized, "missing or wrong api token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleAbout(w http.ResponseWriter, r *http.Request) {
	about := s.about
	about.Linked = s.remote != nil
	if s.downloads != nil {
		about.DownloadDir = s.downloads.Dir()
	}
	// The folders of a media server are its owner's, on the owner's machine.
	if !s.viewerHere(r) {
		about.DataDir, about.DownloadDir = "", ""
	}
	writeJSON(w, http.StatusOK, about)
}

// readJSON decodes a small JSON body, answering the request itself when it
// cannot, and reports whether the caller should carry on.
func readJSON(w http.ResponseWriter, r *http.Request, dest any) bool {
	mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "content type must be application/json")
		return false
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		writeError(w, http.StatusBadRequest, "malformed request body")
		return false
	}
	if err := json.Unmarshal(body, dest); err != nil {
		writeError(w, http.StatusBadRequest, "request body must be a JSON object")
		return false
	}
	return true
}

// resolveItem translates one of our ids into the IMDb id and kind that source
// and subtitle providers speak. It answers the request itself when it cannot,
// and reports whether the caller should carry on.
func (s *Server) resolveItem(w http.ResponseWriter, r *http.Request, itemID string) (string, catalog.Kind, bool) {
	if !s.haveCatalog(w) {
		return "", "", false
	}
	item, err := s.catalog.Item(r.Context(), itemID)
	if err != nil {
		s.writeItemError(w, err)
		return "", "", false
	}
	if item.IMDbID() == "" {
		writeError(w, http.StatusUnprocessableEntity, "item has no IMDb id, no provider can look it up")
		return "", "", false
	}
	return item.IMDbID(), item.Kind, true
}

func (s *Server) haveDownloads(w http.ResponseWriter) bool {
	if s.downloads == nil {
		writeError(w, http.StatusServiceUnavailable, "no acquisition backend configured")
		return false
	}
	return true
}

func (s *Server) haveCatalog(w http.ResponseWriter) bool {
	if s.catalog == nil {
		writeError(w, http.StatusServiceUnavailable, "no metadata provider configured")
		return false
	}
	return true
}

func (s *Server) havePreferences(w http.ResponseWriter) bool {
	if s.prefs == nil {
		writeError(w, http.StatusServiceUnavailable, "preferences are not configured")
		return false
	}
	return true
}

func (s *Server) haveProgress(w http.ResponseWriter) bool {
	if s.progress == nil {
		writeError(w, http.StatusServiceUnavailable, "watch progress is not configured")
		return false
	}
	return true
}

func (s *Server) haveAddons(w http.ResponseWriter) bool {
	if s.addons == nil {
		writeError(w, http.StatusServiceUnavailable, "addons are not configured")
		return false
	}
	return true
}

func (s *Server) writeItemError(w http.ResponseWriter, err error) {
	if errors.Is(err, catalog.ErrNotFound) {
		writeError(w, http.StatusNotFound, "unknown item")
		return
	}
	writeError(w, http.StatusInternalServerError, err.Error())
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
