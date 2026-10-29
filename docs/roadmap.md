# Roadmap

What is next, not what was done: done work is in git and, where it set a
rule, in [decisions/](decisions/README.md). `[?]` marks a question to settle
before code.

## Remote core

The client already speaks HTTP to the core, so a core on another machine is a
deployment, not a rewrite. Before anyone runs one:

- Pairing: the core shows a one-time code, the client trades it with the
  address for a token of its own, revocable per device.
- TLS in the core: a self-signed certificate whose fingerprint the client
  pins at pairing (mpv gets it as `tls-ca-file`); a reverse proxy with a
  real certificate also works.
- A confined deployment shipped with the binary: a systemd unit and a
  container, unprivileged, writing to the data directory only.
- More than one core address in the client, switchable, each with its token
  (`Core`'s address changing at runtime).

Later: a management web UI, HTTP and WebDAV sources, phone and TV clients.

Much later, after the apps: playback in that web UI without transcoding video.
First, with no FFmpeg, offer a browser only the sources it plays as they are
(MP4 with H.264 or AV1 and AAC, mostly film releases), with external subtitles
as WebVTT. Then, if that proves too few: remux MKV and convert the audio
through FFmpeg, where seeking is the hard part. Everything else opens in the
app. This revises "No browser playback" in decisions/foundations.md.

## Library and storage

- Films on Coming up: the catalogue keeps a film's year, not its release
  date, which Cinemeta's meta has.
- Default download folder `Videos/Lumeo`, laid out
  `Title (Year)/Season NN/<torrent name>/`. Only the directories above the
  torrent's are ours: renaming its files breaks seeding.
- Trakt import and export. A first-watched time needs a column of its own:
  `progress.updated_at` moves with a rewatch.
- A folder of films the user already has, scanned as a library of its own on
  the home screen.
- A series' episodes as a vertical list under the banner (still, length,
  synopsis for watched and next only). Mockup first: canvas "Series page ·
  release picker", page "Others' layouts".
- Freeing a pack episode costs ~250 ms (copying the two boundary pieces) and
  holds `startMu`, so a Play at that moment waits. Left as is until someone
  notices; the fix then is punching holes in place (`fallocate`,
  `FSCTL_SET_ZERO_DATA`) with the copy as fallback.

## Player

- mpv's window requests (clipboard, window size, minimise, on-top): answer
  each through an observed property, as `fullscreen` is.
- "Identify as…" for a file matched to the wrong title or none (`[?]`).
- A copy that is not the episode (another cut, a short), told by mpv's
  `duration` against the catalogue runtime. Only if somebody asks.
- "Reduce loud sounds", off by default, in Settings › Audio: ffmpeg's
  `dynaudnorm` through mpv's `af`, nothing to bundle. A release has no
  loudness standard, and a 5.1 mix folded to stereo buries the voices.

## Application

- Community translations through Weblate, committing to Forgejo (the GitHub
  mirror is overwritten by pushes). Runtime as minutes from the core, so the
  client says it in the viewer's language.
- A title never opened, on a slow Cinemeta: draw the page from the catalog
  row at once and fill episodes and cast in later. Retry a failed poster with
  a backoff.
- Settings to add: what opens at startup; pausing when minimised (X11 and
  Windows only: Wayland never says); an external player for what
  our mpv cannot open; surround passthrough; subtitle outline; whether a
  newer release exists; mpv's network timeout and cache, `hwdec`.
- The home hero rotates every ~10 s, paused under the pointer (mockup first).
- A web demo on the share site, to try the app without installing it: a
  page of its own in HTML and JS, as the share page is, over answers recorded
  from the real core in CI: the home rows, those titles' pages and artwork.
  Search runs over the recording; My list and progress stay in the browser;
  Play and downloads open the title in an installed Lumeo. The client does
  not build for a browser well: Qt's is a large WebAssembly download.
- Gamepad support.
- My list as a `GridView` with the new-episodes shelf as its header: posters
  made only as they come into view, and the view's own arrow keys in place of
  `LibraryPage`'s `move`/`focusTile`. Search keeps its `Flow`, since the best
  match spans cells. `reuseItems` only if scrolling a long grid stutters.
- The player's notice line is a second `Toast` (top, wrapped, 8 s): one
  component with those as properties.

## Metadata: TMDB

`[?]` TMDB as an optional provider with the user's own key
(decisions/foundations.md, Metadata). It brings what Cinemeta lacks:

- collection shelf on a film's page;
- season posters, also in Continue watching;
- More like this from recommendations;
- original-language audio as the default track;
- a season's own trailer, where TMDB has one (Cinemeta names the title's only).

## Anime through Kitsu

Cinemeta folds an anime's sequels into seasons of the first title, its OVAs,
films and shorts into one Specials list with no type, and lags on what is
airing: Re:Zero has 70 specials of 89, its fourth season's shorts missing.
Anime Kitsu (`anime-kitsu.strem.fun`) speaks the same addon protocol with no
key, keeps every season, part, OVA, film and short as an entry of its own with
its type and numbering, and gives each entry its IMDb id and each episode its
`imdbSeason`/`imdbEpisode`.

- A title is anime when the anime ID map lists its IMDb id: Fribb/anime-lists
  (Kitsu, MAL, AniDB ↔ IMDb, TVDB; 1.2 MB gzipped), fetched by the core and
  refreshed weekly. Genre and country do not tell. `[?]` The list carries no
  licence: fetch it at run time, never commit it.
- The page stays the IMDb title, so links, My list and the share page keep one
  id. Its tabs are the Kitsu entries under that id in airing order, each with
  its type and own numbering. Kitsu's Prequel and Sequel links lead to entries
  under other ids (a film, a recut).
- Search and rows keep Cinemeta's order. Kitsu's results group by IMDb id: a
  group whose title Cinemeta also returned is that card, the others follow in
  Kitsu's order, an entry with no IMDb id as a card of its own. No popularity
  is compared across catalogs.
- Sources are asked for `kitsu:<id>:<episode>`, which Torrentio answers.
  Subtitles still go by IMDb through the episode's mapping; an episode
  Cinemeta lacks gets none from OpenSubtitles.
- Progress keys an anime episode by its Kitsu id; what was kept by IMDb season
  and episode moves over through the same mapping, in a migration.
- `[?]` Openings and endings from AniSkip (`api.aniskip.com`, by MAL id and
  episode) as chapter marks on a release that has none: data where the
  dropped audio detection had to guess.

## Sources and the swarm

- anacrolix/torrent v1.61.0 can freeze a download from few peers for up to a
  minute (#1070, fixed on master). Update to the first release with the fix
  and drop the skip in `TestBackendStreamsFromLocalPeer`.
- Playback jumping to the end of an episode, cause unknown. Next time: the
  core's `stream cut short` warning and `mpv.log` in `~/.local/state/lumeo`.
- `[?]` A proxy per addon, beyond `HTTP_PROXY`.
- `[?]` Ranking by language flags for live action, where the flags are
  mostly dubs.

## Shipping

- Copr, arm64, a self-hosted Flatpak remote.
- `[?]` The Linux CI jobs' apt packages baked into an image on GHCR, pinned
  by digest in `ci.yml` and `release.yml`: apt then runs when a dependency
  changes, not on every run, and a slow Ubuntu mirror stops holding up a tag
  (beta.12's apt step hung past its limit). Until then a stalled run is
  re-run.
- Windows: a signed installer if SmartScreen costs users; Snap Layouts on the
  maximise button.
- Keep the Windows libmpv in a repository the push mirror does not own, at the
  next libmpv bump: the mirror deletes tags origin lacks, so the release
  `build-windows.sh` downloads from needs its tag on origin first.

## To check by hand

A film playing past the screen's blanking time keeps it on: Windows, GNOME
and KDE.

A filtered line without a VPN: blank posters fill in within about 30 s.

## Open questions

- A demo source without copyrighted content.
- Whether a first-party indexer is worth writing once addon gaps are known.
