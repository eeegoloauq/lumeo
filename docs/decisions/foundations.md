# Foundations

## Core in Go, one binary, SQLite

No PostgreSQL, no Redis, no separate downloader service. The deployment target
is `single binary + SQLite + a media directory + optional FFmpeg`. Silo is the
cautionary example: a good Go media server whose infrastructure is heavier than
what a home user should have to run.

## Schema migrations are kept, so any version upgrades to any later one

Every package channel (Flatpak, Arch, the Windows build) installs only the
latest release, so the core has to migrate a database from any earlier one.
That is why `core/internal/store/migrations/` keeps every file: one change per
file, never edited once released. A new preference is a new key with a default
and needs no migration. Rejected for now: squashing into a baseline with a
minimum version, which refuses a database that skipped the baseline release.
Revisit only if the files get in the way, at a 0.x step, and then refuse such
a database with a clear message rather than lose its data.

## The client always speaks HTTP to the core

Even in local mode, where both live in the same process tree. This is what makes
server mode a deployment choice rather than a rewrite, and it has to hold from
the first commit — retrofitting a network boundary later never works.

## Qt Quick + libmpv for the desktop client, not Flutter or a webview

Decided 2026-10-25; the Flutter client in `client/` ships until the Qt one
replaces it, in the order [qt-port.md](../qt-port.md) sets out.

The client is a video player first, and on the desktop the toolkit that
players embedding libmpv are built on is Qt Quick: mpv renders through its
render API on Qt Quick's own render thread, in desktop GL, through an
integration other players maintain. Flutter was chosen first because
media_kit drew libmpv into a widget and the same code would reach Android.
Two months of it showed where that costs:

- Everything between mpv and the compositor on Linux was one package's C++
  with no newer version, so we own a fork of it (video-output.md): a
  deadlock, stale frames after a long pause, a render thread of our own.
- Flutter's Linux embedder runs Dart on the GTK thread, so any call that waits
  on mpv stalls the whole interface, and mpv draws in GLES inside Flutter's
  share group, where NVIDIA reads textures at `mediump` (Anime4K turns
  orange green).
- On Windows the libmpv is media_kit's: mpv 0.36 from 2023 without Lua, so
  mpv's console and statistics cannot work.
- Flutter's desktop is the part Google handed to Canonical at I/O 2026;
  multi-window was still experimental in 3.44.

Qt Quick brings desktop GL, a render thread that is not the one drawing the
interface, our own current libmpv on Windows, and a tray, single instance,
native folder dialogs and input methods that are the toolkit's rather than
ours. It costs the whole client and its tests, which is why it is done now,
at 24k lines, and not later. What it does not bring is gpu-next or HDR: mpv
still draws through the render API.

Qt Quick and not Qt Widgets: the player's bar floats over the picture, and
the interface is drawn and animated like the one it replaces. Logic that
holds state (the core's API, the stores, mpv) is C++; the views are QML.
Qt 6.12, the LTS from 2026-09-30.

Rejected with it: a webview (Tauri, Electron), because it cannot draw mpv's
picture under the page and a separate mpv window over it is broken on
Wayland; Rust toolkits (Slint, Iced), young and without an mpv integration;
and a native client per platform, which is two or three clients. Phones and
TVs stay open: Qt builds for Android, and a desktop on a TV is this client
with a remote.

## No browser playback, and therefore no transcoding

A browser cannot play what actually shows up in sources: MKV containers, HEVC,
DTS/TrueHD audio, PGS/VOBSUB subtitles, styled ASS. Supporting a web player
means server-side remux and transcode for nearly every file — the single largest
piece of work in this space. mpv
direct-plays all of it for free. A web UI for *managing* the server (library,
downloads, settings) needs no video and stays on the table.

## Sources are pluggable; BitTorrent is one provider among several

The core knows `Provider -> []MediaSource` and nothing about where bytes come
from. Local files, HTTP, WebDAV and BitTorrent are all implementations. This is
better architecture and it keeps the project's identity general-purpose.

## First provider speaks the Stremio addon protocol

A documented `GET /stream/{type}/{id}.json` gives immediate access to the whole
addon ecosystem instead of weeks spent writing a scraper. Writing our own
indexer stays possible later; nothing in the interface assumes addons.

Consequence: addons return almost no structured data. Quality, codec, HDR,
audio, language and group exist only inside a free-text release name, plus
seeders and size rendered as emoji text. So `internal/release` parses release
names ourselves. That parser is also what turns the source list into columns
instead of a wall of truncated text, and it serves any future indexer unchanged.

## One protocol client covers catalogs, metadata, streams and subtitles

The addon protocol serves four resource types, not one: `catalog` (the rows on a
home screen), `meta` (an item with its episodes), `stream` (playable sources)
and `subtitles`. So a single client implementation gives us:

    catalog + meta   Cinemeta            top / year / imdbRating / calendar
    stream           whichever the user adds
    subtitles        OpenSubtitles v3    UTF-8 .srt, keyless

None of it needs an API key or an account, so the one setup step is pasting
the address of a source addon. The subtitles response carries `movieReleaseName`, `releaseGroup` and
`fpsMilli`, so subtitles get matched to the exact release being played instead
of "some English track" — that is what stops the out-of-sync subtitle problem
users hit in Stremio.

## Metadata: Cinemeta, no API key; TMDB is out of scope

Requiring an API key to see a poster is a terrible first run, and shipping our
own TMDB key in a public repo means answering for whoever scrapes it out.

Cinemeta speaks the same addon protocol we already implement and needs no key
at all. One request returns poster, background, **logo**, description, genres,
cast, IMDb rating and the full episode list with per-episode overview, air date
and thumbnail — plus `moviedb_id` and `tvdb_id`, which fills our external-id map
for free.

TMDB is therefore not being built. It would buy localisation, more artwork
choices and fresher data on new releases, at the cost of every user needing an
account. Revisit only if Cinemeta turns out to be measurably insufficient, and
then as a provider the user configures with their own key.

Cinemeta is a free third-party service with no SLA and thinner data than TMDB,
so metadata is cached hard in SQLite and sits behind a provider interface, the
same way sources do. `MediaItem` keeps its own id and a map of external ids
(imdb, tmdb, tvdb) so the provider can be swapped without touching the library.
