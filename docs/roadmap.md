# Roadmap

What is next, not what was done: done work is in git and, where it set a
rule, in [decisions/](decisions/README.md). `[?]` marks a question to settle
before code.

## Remote core

A server is reached over HTTPS, through a reverse proxy or with the core's
own certificate, with one-time pairing and revocable device credentials
([setup](remote-core.md)). The client keeps every server it paired with,
full or media, beside its local mode; switching applies on restart so
in-flight requests and final playback progress stay with their original core.
The server has a confined systemd unit or container image and console
administration.

Switching without a restart is not planned: it would trade a restart of a
few seconds, for a choice made rarely, for every store, request and playback
proving it stays with its core. A media server's link is read when the local
core starts, so that core would restart anyway. Reconsider when someone
switches often enough to mind.

Later: a management web UI, HTTP and WebDAV sources, phone and TV clients.

Much later, after the apps: playback in that web UI without transcoding video.
First, with no FFmpeg, offer a browser only the sources it plays as they are
(MP4 with H.264 or AV1 and AAC, mostly film releases), with external subtitles
as WebVTT. Then, if that proves too few: remux MKV and convert the audio
through FFmpeg, where seeking is the hard part. Everything else opens in the
app. This revises "No browser playback" in decisions/foundations.md.

## Library and storage

- Trakt import and export. A first-watched time needs a column of its own:
  `progress.updated_at` moves with a rewatch.
- A folder of films the user already has, scanned as a library of its own on
  the home screen.
- A series' episodes as a vertical list on a scrolling page. The banner
  holds the title and playback actions; below it, metadata and the series
  synopsis sit beside cast and genres, followed by season tabs and a season
  download action. Each row has an episode number, a 16:9 still with watched
  progress and an on-disk mark, then title, rating and runtime. Episode
  synopses take up to two lines, for watched episodes and the next one only.
  This is an alternative to the current horizontal cards; review the layout
  before implementation.
- Freeing a pack episode costs ~250 ms (copying the two boundary pieces) and
  holds `startMu`, so a Play at that moment waits. Left as is until someone
  notices; the fix then is punching holes in place (`fallocate`,
  `FSCTL_SET_ZERO_DATA`) with the copy as fallback.

## Player

- "Identify as…" for a file matched to the wrong title or none (`[?]`).
- A copy that is not the episode (another cut, a short), told by mpv's
  `duration` against the catalogue runtime. Only if somebody asks.

## Application

- Community translations through Weblate, committing to Forgejo (the GitHub
  mirror is overwritten by pushes). Runtime as minutes from the core, so the
  client says it in the viewer's language.
- A title never opened, on a slow Cinemeta: draw the page from the catalog
  row at once and fill episodes and cast in later.
- Settings to add: an external player for what our mpv cannot open;
  subtitle outline; mpv's network timeout and cache.
- The home hero rotates every ~10 s, paused under the pointer (mockup first).
- A web demo on the share site, to try the app without installing it: the
  client itself built with Qt for WebAssembly, single-threaded (GitHub Pages
  cannot send the headers threads need). One network manager answers from an
  invented catalogue bundled into the page, its JSON checked against the
  core's types as `tests/fixtures/` is; My list and progress stay in memory.
  No playback and no downloads: Play says the app does that. First a size
  check of a build of the shell, compressed as Pages serves it: about 10 MB
  is fine, much more and this is reconsidered.
- Typing in search from a gamepad, which drives every other page: the
  system's on-screen keyboard where there is one, or one of our own.

## Metadata: TMDB

`[?]` TMDB as an optional provider with the user's own key
(decisions/foundations.md, Metadata). It brings what Cinemeta lacks:

- collection shelf on a film's page;
- season posters, also in Continue watching;
- More like this from recommendations;
- original-language audio as the default track;
- a season's own trailer, where TMDB has one (Cinemeta names the title's only).

## Anime specials through Kitsu

Cinemeta lists an anime's OVAs, films and shorts as one Specials season with
no type, from TVDB, which lags on what is airing: Re:Zero has 70 specials of
89, its fourth season's shorts missing. Anime Kitsu (`anime-kitsu.strem.fun`)
speaks the same addon protocol with no key, keeps every OVA, film and short
series as an entry of its own with its type, and maps each episode to IMDb as
`imdbSeason`/`imdbEpisode`, in Cinemeta's own numbering of season 0 (Memory
Snow is 26 in both; Break Time's fourth season goes on from 71).

Cinemeta keeps the page, the seasons, search and sharing; Kitsu sorts and
completes season 0.

- Kitsu has no lookup by IMDb id, so a series in Cinemeta's Animation genre
  searches Kitsu by its Cinemeta name and keeps the entries whose `imdb_id` is
  the title's. None found: not anime, the page stays as it is. The search
  returns at most 20 and ignores `skip`, so a large franchise can come back
  short; what it misses stays in the remainder below.
- Kitsu episodes with `imdbSeason` 0 become the Specials tabs, one per entry
  in airing order, each with its type and own numbering. Cinemeta's season-0
  episodes no Kitsu episode claims stay in one tab after them. Episodes above
  season 0 are Cinemeta's seasons and are dropped (Attack on Titan's Final
  Chapters, a "special" in Kitsu, is season 4).
- A special keeps its IMDb key (`S00E26`), so progress needs no migration.
  Its sources are asked for `kitsu:<id>:<episode>`, which Torrentio answers.
- `[?]` Openings and endings from AniSkip (`api.aniskip.com`, by MAL id and
  episode) as chapter marks on a release that has none: data where the
  dropped audio detection had to guess. Needs the MAL id, which Kitsu's meta
  does not give.

## Sources and the swarm

- SOCKS5 for torrent traffic, with TCP and TCP + UDP modes and no direct
  fallback. Scope, failure behaviour, dependency questions and required tests
  are in [the planned work](torrent-proxy.md). Separate from remote-core access;
  support on the real proxy still needs verification.
- anacrolix/torrent is pinned to a master commit, the first with its bencode
  depth limit (GHSA, a crafted info dict crashed the core). Move to the
  release that follows v1.61.0 once it is out.
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
