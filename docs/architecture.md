# Architecture

    metadata provider (Cinemeta, addon protocol)
              |
    +---------v---------+
    |     Go core       |   SQLite: library, downloads, watch progress,
    |                   |   My list, ratings
    |  catalog          |   HTTP API, streaming, storage policy
    |  sources          |
    |  acquisition      |
    +---------+---------+
              | HTTP
      +-------+-------+
      |       |       |
   desktop  mobile   TV

## Packages in core

    internal/config    runtime knobs; local vs server mode differ only here
    internal/api       the only entry point; same handlers for both modes
    internal/catalog   the domain model — MediaItem, Episode, our ids — plus
                       the metadata Provider interface and the cached Service
                       every catalog request goes through
    internal/store     SQLite: schema, migrations, catalog cache and the map
                       from our ids to external ones
    internal/acquire   Backend/Task/File interfaces and the Manager that owns
                       downloads: what exists, where its bytes are, which
                       backend is moving them
    internal/acquire/torrent
                       the only backend so far: anacrolix/torrent, sequential
                       pieces and readahead behind a plain ReadSeekCloser
    internal/sources   Provider interface, MediaSource, Locator
    internal/subtitles Provider interface, the OpenSubtitles video hash, and
                       the Service that ranks candidates and is the only thing
                       that fetches a subtitle file
    internal/stremio   Stremio addon protocol client: catalog, meta, stream
                       and subtitles resources from one implementation, which
                       is why it sits beside sources rather than inside it
    internal/addons    the installed addons: one list in the database, each
                       a URL whose manifest says which of those resources it
                       serves; the catalog, subtitle and source services ask
                       it for their providers on every call
    internal/preferences
                       settings shared by every client, with the environment
                       as the default and the stored value winning
    internal/progress  watch positions per film or episode, what an item
                       should play next — the latest entry if unfinished, else
                       the episode after the latest watched one — and the
                       history, which is a query over the same rows
    internal/watchlist My list, how far the viewer is into each title on it,
                       and the new episodes of the series they follow
    internal/ratings   the viewer's own scores, 1 to 10, of titles and
                       episodes
    internal/searches  what the viewer searched for, the last ten, once per
                       word: recorded when a search is submitted or one of
                       its answers opened, never per keystroke
    internal/token     the API token in the data directory
    internal/release   release-name parser (the structure addons do not give us)
    internal/library   the keep policy: frees watched downloads when Keep or
                       the disk limit says so, and measures what downloads
                       take on disk for it and for Storage

## Ids

`internal/catalog` is the bottom of the import graph: sources, store and api
all speak its types. Every item gets an id we mint on first sight, kept in
`external_ids` alongside the imdb/tmdb/tvdb ids providers know it by. The
client only ever sees ours — `/api/v1/sources?item=<our id>` translates to the
IMDb id the source addons need — so swapping the metadata provider does not
touch the library.

## Caching

Catalog pages and item metadata are cached in SQLite with a TTL (6h and 24h).
Cinemeta is free, has no SLA and, without a VPN in some countries, can take
the full 15 s to fail, so a cached copy is always the answer: past the TTL it
is served at once and Cinemeta is asked in the background, and the next open
shows what came back. Only a page or title never fetched waits for Cinemeta,
and falls back to what the cache has (a title's catalog row) when it fails.
Requests for the same page or title while one is out join it: opening a
title asks for it three times at once (the page, its progress, its sources).
The request runs on the catalog's own context (`internal/flight`), so a page
closed before Cinemeta answered still gets its answer cached.

The cache holds what the core's code made of Cinemeta's answer, so a core of
another version starts with all of it expired rather than stale: expired
copies wait for Cinemeta like missing ones, and a parser change takes effect
on the next open, not a day later.

Lists of titles nobody is opening right now — My list, the series whose new
episodes are looked for — are answered from the cache as it is, whatever the
age of each title, and the stale ones are asked for behind the answer, four
at a time. Waiting on each would make the library as slow as its slowest
title, and asking for forty at once is how a free service learns to refuse
us.

Artwork URLs in API responses point to `GET /api/v1/artwork/{key}`. The core
registers each URL in SQLite and caches fetched images under the XDG cache
directory (or `LUMEO_CACHE`), up to 512 MiB with least recently used eviction.
Tiles asking for one image not yet cached share one fetch.
`GET /api/v1/storage` reports artwork bytes as `cache`; `DELETE /api/v1/cache`
clears the files and retries previously missing images.

## Acquisition

The core hands a `sources.Locator` to whichever `acquire.Backend` claims its
scheme and gets back a `Task`: progress cheap enough to poll per request, and a
`File` whose `Open()` returns a reader that blocks until the bytes it needs
have arrived. That reader is the whole point — it is what makes the pieces be
fetched in the order a player asks for them, so playback starts long before the
download finishes, and it is a plain `io.ReadSeekCloser`, so an HTTP backend
later needs no new concept.

Acquired downloads own a directory `<id>` under the download directory and a
row in SQLite. The download directory is `<data>/downloads` unless the
`downloadDir` preference names another; a change of it takes the downloads
started after it, and the episodes of a pack already begun stay with their
torrent. `/about` and `/storage` report the one in effect. Progress is not
persisted: it is cheaper to ask the backend than to keep a stale number honest.
The exception is a pause, which freezes it. A download says `resolved` once the backend knows
which file it is (a magnet's metadata has arrived), so the client can tell
"Finding peers" (nobody yet) from "Fetching metadata" (peers, no file yet)
from bytes arriving. The client's list of downloads is a poll, slow while
nothing moves; a download this client starts is put in it from the start
call's answer, not from the next poll. Stopping a download and discarding what it fetched
are separate intentions and separate calls.

What the download JSON says about the transfer, besides `progress.completed`,
`total`, `peers`, `seeders` and `rate`:

- `waitingSince` (RFC 3339): while an active download gets nothing (no
  metadata yet, no peers, or ten seconds without a byte), since when: the
  last byte, or the start. Absent while bytes arrive.
- `progress.eta`: whole seconds to the end at a rate smoothed over about
  twenty seconds, only while bytes arrive, so never beside `waitingSince`.
- `pausedByUser`: the `paused` state came from a pause somebody asked for,
  not from a finished file gone missing.
- `release`: the name read by the release parser the source list uses
  (`resolution`, `hdr`, …), derived on every read and never stored.

`PATCH /api/v1/downloads/{id}` takes `{"paused": true}` or `{"paused": false}`
and answers with the download. A pause stops the transfer, keeps the bytes and
how far it had got, and lasts until it is resumed or played, restarts of the
core included. Resuming a failed download retries it. A finished download, or a
file on this machine, has nothing to pause: 400, as is any other body; an
unknown id is 404. Pausing one episode of a pack stops asking the swarm for
that episode; the torrent runs on for the others.

## Preferences

`GET /api/v1/preferences` is the whole document, each key at its stored value
or its default; `PATCH` sets the keys it names, `null` putting one back to its
default, and refuses the whole document for one bad value; `DELETE` puts every
key back and answers with the defaults. A choice that should follow the viewer
to another client is a key here; a fact about one machine or screen stays in
the client's own `client.json`.

The keys the client applies (subtitles, accent, `seekStep`, `nextNotice`,
`nextCountdown`) the core only validates and stores. The ones only the core can
apply it applies itself, before the change is answered: `keep`, `keepDays` and
`diskLimit` run a pass of the keep policy; `downloadDir` is checked on the
spot (absolute, made if missing, a probe file written and removed) and moves
where new downloads go; `seed`, `uploadLimit` and `downloadLimit` change the
running torrent client. Whatever applies a preference subscribes to the
service (`preferences.Service.Subscribe`); nothing reads a global copy. An
earlier `keep: "30days"` reads back, and is still taken, as `keep: "days"`
with `keepDays: 30`.

`GET /api/v1/about` is what a settings page cannot learn from its own side:
`version`, `addr` (where the core listens), `dataDir`, `downloadDir` (in
effect), and `logPath` when the core's log goes to a file (on Windows the app
hands it `core.log`; the journal and a terminal have no path, and the key is
left out).

## Local files

"Open with Lumeo" on a video sends its path to `POST /api/v1/local`, and the
core makes it a download of the `file` scheme (`internal/acquire/local`): done
from the start, streamed like any other, so the player, watch progress,
Continue watching, subtitles by hash and the next episode need nothing new.
A file Lumeo downloaded itself is recognised by its path and answered with
that download.

`internal/local` names the title the way media servers do, from the file
name: the release parser gives a title, year and SxxEyy, and the parent
folders fill in what the name lacks (`Show/Season 2/…`). The title is looked
up in the catalogue. A match has to share a word with the name, and a film
with no year has to carry the name exactly, because a search answers with
whatever it has; a series match has to have that episode. An episode number
with no season counts through the regular seasons, as fansub releases number
a show. The other episodes of the show in the same folder are registered with
it, so the next one plays from the folder rather than from a swarm. A file
nothing matches still plays, and keeps its position under its OpenSubtitles
hash (`local:<hash>`), outside Continue watching.

The request does not wait for that: the download is registered with no title
and answered at once, and the lookup runs behind it, as slow as the provider.
The player plays it meanwhile and reports no progress until the download has
a title, which it reads on its next poll along with the name it shows.

The file is the user's: it gets no directory under `<data>/downloads`,
Storage and Free leave it out, and removing its download removes the row
only. A title's source list offers it first, as a finished copy.

The core reads such a file by a path a caller gave it, and a caller is any
process of the user's that holds the API token, so the path is trusted for
nothing. A file is read only
while it holds a video container, checked on the open file that is then
served (a link called film.mkv to a key file is refused, and so is a video
swapped for one after it was opened), and a download request cannot name a
file: only `POST /api/v1/local` adds one. Because the
core reads files by path, on a loopback listener it answers only
loopback `Host` names: a page that rebinds its own domain to 127.0.0.1 would
otherwise read them. A request a browser sends from another site that would
change something is refused on its `Sec-Fetch-Site` or `Origin` header,
whatever its content type.

## The API token

Every request carries `Authorization: Bearer <token>`, and the core answers
401 without it. The core keeps the token in `<data>/api-token`, mode 0600,
created on the first start and the same after (`internal/token`); it is
written before the core listens, so a client refused by a core finds that
core's token in the file. Only the user's own processes can read it, which is
exactly the set that may control the core; other accounts on the machine
reach the port and get nothing.

The client reads the file from the data directory the core picks (LUMEO_DATA
first, as the core does) when it talks to the default address, and never
sends it to an address set by hand. It reads the file again after a 401 and
retries once if the token changed: a core started for the first time writes
it after the client may have looked. mpv gets it as `http-header-fields`,
through `Media.httpHeaders` for the player and as an option for the frame
grabbers.

Artwork is the one route without it: an image widget fetches by address
alone. The address is the credential instead, its key an HMAC of the
picture's source address under the token, so it cannot be worked out from a
poster URL and reaches only a client that listed the title.

## Streaming

`GET /api/v1/downloads/{id}/stream` serves that reader over HTTP. Range
parsing, `If-Range`, `206` and `416` are `http.ServeContent`'s job, not ours —
the reader is an `io.ReadSeekCloser` precisely so it can be handed over. What
we add is the content type (sniffing would block a `HEAD` until the first
piece landed), an ETag (a torrent is its content, so the bytes behind an id
cannot change), and the request context, which cancels a read when the player
walks away.

A finished download is served from the filesystem rather than through the
torrent: a restart does not resume completed downloads, and needing a live
swarm to replay something already on disk would make the library evaporate at
every restart. The filesystem is the truth for it: a finished file that is
missing or not its full size (deleted outside the app) turns the download back
to paused, at startup or whenever it is looked at, and the next Play restarts it
in the same directory. Inside a running torrent, the torrent storage checks the
file sizes behind every piece its completion record calls complete. Storage
lists a download only while it runs or its file is there, so a deleted episode
leaves the count; its leftover bytes still count as used until freed.

A download that was running when the core stopped starts again at boot, and so
does one whose backend refused to start it before (`failed`): what refused (a
drive not mounted yet) may be gone. One that fails again stays failed with the
new reason until the next boot or the next Play.

## Subtitles

A subtitle file is timed to one encode, so the question is never "English
subtitles for this film" but "subtitles for the file I am playing". The answer
comes from the OpenSubtitles hash — the file size plus the first and last
64 KiB — which the core computes from the download itself and sends to the
provider, which then answers with tracks matched against that exact copy and
marks them as such.

On a download still arriving, the tail is 64 KiB the swarm has not been asked
for yet, so the hash is computed when the picker is first opened rather than
when playback starts, bounded by a deadline, cached per download, and skipped
entirely if it does not arrive in time — an approximate list now beats an
exact one after the scene has passed.

The file itself is fetched through the core, never by the player:
`/api/v1/subtitles` hands out ids of ours and `/api/v1/subtitles/{id}` fetches
the one behind an id. Two things follow. Half of what these databases hold
predates Unicode and declares nothing, so the core decides the encoding once —
the file, then the provider's declared charset, then the code page that
language was written in — and every client gets UTF-8. And no API caller can
name an address for the core to fetch, which on a home server is the
difference between a subtitle endpoint and a proxy into the network it sits on;
the address a provider names is fetched only if it is public (see Egress).

Preferences live in the core because the desktop client is only one of several
clients that can use it. Environment values supply defaults, stored values win,
and sending `null` resets a preference to its default.

## Addons

The core is never told what an addon is for. `Addons`, `Metadata` and
`Subtitles` used to be three lists in the configuration holding the same kind
of thing; now there is one list, in the database behind `/api/v1/addons`, and
each entry's manifest says whether it serves `catalog`, `meta`, `stream` or
`subtitles`. The catalog, subtitle and source services take their providers
as a function and call it per request, so a row switched off on the Sources
page is gone from the next answer without a restart. The order of the list is
the order the services ask in: the first catalog is the home screen, and
between two copies that rank the same the higher addon's comes first.

Installing is `POST` with a URL. The manifest is fetched before anything is
stored — that is the check that the address is alive — and when it names an
addon already installed, that addon is pointed at the new URL rather than
installed twice. This is how an addon's own `/configure` page, which hands
back a URL with the settings inside it, changes the addon. The last manifest
is kept in the row so a core started without a network still knows what each
addon is for. Manifests are refreshed in the background, at start and hourly,
and a request only ever reads the copy in hand. One that has never answered is asked again on the way to
answering a request — waiting up to five seconds, not more than once a
minute — because the first request after a fresh start is the home screen
asking for its catalogue, and an empty answer there is an empty screen.

`LUMEO_ADDONS` is only what a new database starts with: the table is seeded
on the run that creates it, and a list emptied on purpose stays empty.

## Egress

Addon HTTP (manifests, catalogues, stream and subtitle lists, subtitle files,
artwork) goes through one transport, `internal/egress`, which honours
`HTTP_PROXY`/`HTTPS_PROXY`. Peer traffic is the torrent engine's and always
goes direct. A provider that refuses or does not answer is reported in
`/api/v1/sources` as `failed: [{provider, reason}]`, and the client names it
under Play.

What an addon names for the core to fetch on its own — artwork, subtitle
files, HTTP trackers — goes only to public addresses (`egress.Addressed`,
checked on the address dialled, after DNS and on every redirect): otherwise
an addon's answer could send GETs of its choosing to the router or to
anything on localhost. Behind `HTTP_PROXY` the proxy resolves names, so only
an address written into the URL is refused there. The addons' own addresses are the user's choice and
may be on their network. An addon's answer is read up to 16 MiB, and an
image that is not a web address is dropped rather than passed on.

Every request to one host shares one HTTP/2 connection. The transport pings
after 5 s of silence and drops the connection 3 s later, so a connection the
far side stopped answering (a tarpit, a VPN switch) is gone before it is
reused. A GET caught on one is resent once on a new connection; an answer,
403 included, is never resent. The addon client's limit (15 s) is under the
application's (20 s) and providers are asked in parallel, so a slow one costs
its own results, not the list.

## Data flow of the one workflow that matters

    search (Cinemeta)
      -> pick item
      -> providers return MediaSources for movie/season/episode
      -> release parser turns names into quality/codec/audio/language
      -> ranked list, with a smart default so Play needs no decision
      -> acquisition starts, playback starts against the same file
      -> file stays in the library until the keep policy frees it
      -> progress syncs, another device resumes it

## Client

Flutter, on Linux and Windows. media_kit hosts libmpv inside the widget tree, so
the player chrome is entirely ours and the user never sees mpv's own UI.

    lib/api      the core over HTTP, and the shapes it sends
    lib/ui/screens  home, item, search, library, settings, and the shell
                    that holds them
    lib/ui/player   the player: state and mpv wiring (player_screen), the bar
                    (chrome), the menus (menus), the wait and failure screens
                    (waiting), mpv's keys (bindings) and the second mpv
                    behind the seek bar's previews (thumbnails)
    lib/ui/widgets  everything shared between screens
    lib/platform    the machine: folders, the window, local settings, decoders
    linux/, windows/  the runners: start the core, one instance, the window
                    channel (dev.lumeo/window) behind the client's own title bar
