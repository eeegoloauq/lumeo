# Foundations

## Core in Go, one binary, SQLite

No PostgreSQL, no Redis, no separate downloader service. The deployment target
is `single binary + SQLite + a media directory + optional FFmpeg`. Silo is the
cautionary example: a good Go media server whose infrastructure is heavier than
what a home user should have to run.

## The client always speaks HTTP to the core

Even in local mode, where both live in the same process tree. This is what makes
server mode a deployment choice rather than a rewrite, and it has to hold from
the first commit — retrofitting a network boundary later never works.

## Flutter + media_kit for the client, not a webview

libmpv cannot be embedded inside a webview, which rules out Tauri and Electron:
they would leave mpv as a separate window floating over the UI, which is broken
on Wayland and is a bodge regardless. media_kit renders libmpv directly into a
widget, and the same UI code later reaches Android and Android TV. Qt/QML was
the runner-up (Jellyfin Media Player does exactly that) but is desktop-only in
practice and a language nobody here writes.

## No browser playback, and therefore no transcoding

A browser cannot play what actually shows up in sources: MKV containers, HEVC,
DTS/TrueHD audio, PGS/VOBSUB subtitles, styled ASS. Supporting a web player
means server-side remux and transcode for nearly every file — the single largest
piece of work in this space, and the thing that made Jellyfin what it is. mpv
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
names ourselves. That parser is also what separates our source list from
Stremio's wall of truncated text, and it serves any future indexer unchanged.

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
