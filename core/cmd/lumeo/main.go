// Command lumeo runs the core: the same binary backs the desktop app's local
// mode and a standalone home server.
package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/eeegoloauq/lumeo/core/internal/acquire"
	acquirelocal "github.com/eeegoloauq/lumeo/core/internal/acquire/local"
	acquiretorrent "github.com/eeegoloauq/lumeo/core/internal/acquire/torrent"
	"github.com/eeegoloauq/lumeo/core/internal/addons"
	"github.com/eeegoloauq/lumeo/core/internal/api"
	"github.com/eeegoloauq/lumeo/core/internal/catalog"
	"github.com/eeegoloauq/lumeo/core/internal/config"
	"github.com/eeegoloauq/lumeo/core/internal/library"
	"github.com/eeegoloauq/lumeo/core/internal/local"
	"github.com/eeegoloauq/lumeo/core/internal/preferences"
	"github.com/eeegoloauq/lumeo/core/internal/progress"
	"github.com/eeegoloauq/lumeo/core/internal/ratings"
	"github.com/eeegoloauq/lumeo/core/internal/searches"
	"github.com/eeegoloauq/lumeo/core/internal/store"
	"github.com/eeegoloauq/lumeo/core/internal/subtitles"
	"github.com/eeegoloauq/lumeo/core/internal/token"
	"github.com/eeegoloauq/lumeo/core/internal/watchlist"
)

// Set by packaging/build-dist.sh.
var version = "dev"

func main() {
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	return serve(config.FromEnv(), os.Stdin, log)
}

// serve runs the core until a signal, or until stdin closes when cfg says so.
func serve(cfg config.Config, stdin io.Reader, log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if cfg.ExitOnStdinEOF {
		// Nothing is ever sent on it: EOF, or a read error on a pipe whose
		// other end is gone, is the parent saying it has ended.
		go func() {
			_, _ = io.Copy(io.Discard, stdin)
			log.Info("stdin closed, stopping")
			stop()
		}()
	}

	// Taken first and deferred first, so it is let go only once everything
	// below has closed.
	lock, err := lockDataDir(ctx, cfg.DataDir, cfg.ExitOnStdinEOF, log)
	if err != nil {
		if ctx.Err() != nil {
			return nil // stopped while waiting for the lock
		}
		return err
	}
	defer lock.Close()

	// Written before the core listens: a client told 401 by this core finds
	// the token this core expects already in the file.
	secret, err := token.Load(cfg.DataDir)
	if err != nil {
		return err
	}

	// Listening comes before everything else the core opens, so the app that
	// started it can ask at once: a request that arrives early waits in the
	// backlog for the handler rather than being refused.
	listener, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return err
	}
	defer listener.Close()

	db, err := store.Open(cfg.DBPath(), version)
	if err != nil {
		return err
	}
	defer db.Close()
	log.Info("store opened", "path", cfg.DBPath())

	// One list of addons, and what each is for is read from its manifest:
	// the same URL serves catalogs, streams or subtitles depending on what
	// it lists, and the list is edited over the API while the core runs.
	installed := addons.New(db, log)
	var seed []addons.Seed
	for _, a := range cfg.Addons {
		seed = append(seed, addons.Seed{ID: a.ID, Name: a.Name, URL: a.BaseURL})
	}
	if err := installed.Load(ctx, seed); err != nil {
		return err
	}
	for _, a := range installed.List() {
		log.Info("addon installed", "id", a.ID, "url", a.URL, "enabled", a.Enabled)
	}
	// Manifests are refreshed in the background: a core that waited on three
	// remote hosts before listening would not start on a train, and the
	// stored copies already say what each addon is for.
	refreshing := make(chan struct{})
	go func() {
		defer close(refreshing)
		installed.Run(ctx)
	}()
	// A refresh writes to the store, so it ends before the store closes.
	defer func() {
		stop()
		<-refreshing
	}()

	cat := catalog.NewService(installed.Metadata, db, log)
	defer cat.Close()
	subs := subtitles.NewService(installed.Subtitles, cfg.SubtitleLanguages, log)

	prefs := preferences.New(db, preferences.Preferences{
		SubtitleLanguages:   cfg.SubtitleLanguages,
		SubtitleMode:        "always",
		SubtitleScale:       1,
		SubtitlePosition:    100,
		SubtitleBackground:  "none",
		SubtitleColor:       "white",
		SubtitleKeepStyling: true,
		EpisodeArtwork:      cfg.EpisodeArtwork,
		Accent:              "white",
		Keep:                "forever",
		KeepDays:            30,
		Prefetch:            true,
		NextCountdown:       5,
		NextNotice:          30,
		SeekStep:            5,
		Seed:                cfg.Seed,
	})
	// Read before the torrent client starts, so a download resumed at boot is
	// held to the limits from its first block.
	current, err := prefs.Get(ctx)
	if err != nil {
		return err
	}
	downloadDir := func(p preferences.Preferences) string {
		if p.DownloadDir != "" {
			return p.DownloadDir
		}
		return cfg.DownloadDir()
	}
	torrents, err := acquiretorrent.New(acquiretorrent.Config{
		Port:          cfg.TorrentPort,
		Seed:          current.Seed,
		UploadLimit:   current.UploadLimit,
		DownloadLimit: current.DownloadLimit,
		DataDir:       cfg.DataDir,
	})
	if err != nil {
		return err
	}
	downloads := acquire.NewManager(downloadDir(current), []acquire.Backend{torrents, acquirelocal.Backend{}}, db, log)
	// The preferences only the core can apply follow every change of them.
	prefs.Subscribe(func(p preferences.Preferences) {
		torrents.SetSeed(p.Seed)
		torrents.SetLimits(p.UploadLimit, p.DownloadLimit)
		downloads.SetDir(downloadDir(p))
	})
	localFiles := local.New(cat, downloads, log)
	defer func() {
		if err := downloads.Close(); err != nil {
			log.Warn("stopping downloads", "err", err)
		}
	}()
	// Deferred after the downloads' Close, so it runs first.
	defer localFiles.Close()
	// Whatever was running when the core stopped starts again here; nothing
	// else in the system is allowed to notice that it ever stopped.
	if err := downloads.Resume(ctx); err != nil {
		return err
	}
	// Ends before the downloads close: it restarts their tasks.
	watching, stopWatching := context.WithCancel(ctx)
	watched := make(chan struct{})
	go func() {
		defer close(watched)
		downloads.WatchNetwork(watching)
	}()
	defer func() {
		stopWatching()
		<-watched
	}()
	watchProgress := progress.New(db, cat)
	scores := ratings.New(db, cat)
	list := watchlist.New(db, cat, db, scores)
	lib := library.New(downloads, db, prefs, log)
	cleaning, stopCleaning := context.WithCancel(ctx)
	cleaned := make(chan struct{})
	go func() {
		defer close(cleaned)
		lib.Run(cleaning)
	}()
	// Deferred after the downloads' Close, so it runs first: a pass removing
	// a download must not meet a closed manager.
	defer func() {
		stopCleaning()
		<-cleaned
	}()
	about := api.About{
		Version: version,
		Addr:    listener.Addr().String(),
		DataDir: cfg.DataDir,
		LogPath: logFile(os.Stderr),
	}

	handler := api.New(api.Deps{
		Sources:     installed.Sources,
		Catalog:     cat,
		Downloads:   downloads,
		Library:     lib,
		Local:       localFiles,
		Addr:        cfg.Addr,
		Subtitles:   subs,
		Preferences: prefs,
		Progress:    watchProgress,
		Watchlist:   list,
		Ratings:     scores,
		Addons:      installed,
		Searches:    searches.New(db),
		About:       about,
		Token:       secret,
		Artwork:     db,
		CacheDir:    cfg.CacheDir,
	}, log)
	defer handler.Close()
	srv := &http.Server{
		Handler:           handler.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		// Deliberately no WriteTimeout: a response here is a film being
		// played, and a deadline on it would cut playback off mid-scene.
		// Readers are bounded by the request context instead.
		IdleTimeout: 2 * time.Minute,
	}

	errc := make(chan error, 1)
	go func() {
		log.Info("lumeo core listening", "addr", cfg.Addr, "version", version)
		if err := srv.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errc <- err
		}
	}()

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}
