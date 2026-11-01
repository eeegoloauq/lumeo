# The core

How to run the core on its own, configure it and talk to its HTTP API. How it works inside is in
[architecture.md](architecture.md).

## Running it

    cd core
    LUMEO_DATA=./data go run ./cmd/lumeo

It listens on `127.0.0.1:7666`. Every request needs the token the core writes to `api-token` in its data directory (0600,
so only your own account can read it). For another machine, use
[the remote deployment](remote-core.md) with HTTPS and per-device pairing. A new database starts with Cinemeta for
the catalogue and OpenSubtitles v3 for subtitles; neither needs an API key. No source addon ships:
add one to have something to play.
Each addon's role is read from its manifest. Edit the list on the client's Sources page or over
`/api/v1/addons`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `LUMEO_ADDR` | `127.0.0.1:7666` | Listen address |
| `LUMEO_PUBLIC_URL` | unset | External HTTPS origin, a reverse proxy's or with `LUMEO_TLS` the core's own; no path or query |
| `LUMEO_TLS` | unset | `self-signed`: serve HTTPS with a certificate of the core's own for the host of `LUMEO_PUBLIC_URL`, which devices pin at pairing ([remote-core.md](remote-core.md#without-a-reverse-proxy)) |
| `LUMEO_DATA` | `$XDG_DATA_HOME/lumeo` | Directory of the SQLite database and downloads |
| `LUMEO_ADDONS` | Cinemeta, OpenSubtitles | Addons for an empty database: comma-separated URLs, optionally `name=url`, or `none` |
| `LUMEO_SUBTITLE_LANGS` | `en` | Default subtitle language order; a preference set in the client wins |
| `LUMEO_TORRENT_PORT` | any free port | BitTorrent listen port |
| `LUMEO_EPISODE_ARTWORK` | `show` | Default for unwatched episode stills: `show`, `blur` or `hide` |
| `LUMEO_MODE` | `full` | Where paired devices' personal data lives: `full` keeps it here, `media` leaves it on each device's own core ([Linked to a server](#linked-to-a-server)) |

## API

Every example needs the token as a header; with the core run as above, from `core/`:

    curl -H "Authorization: Bearer $(cat data/api-token)" "localhost:7666/api/v1/catalogs"

    curl "localhost:7666/api/v1/catalogs"
    curl "localhost:7666/api/v1/catalog?kind=series&id=top"
    curl "localhost:7666/api/v1/search?kind=movie&q=matrix"
    curl "localhost:7666/api/v1/items/<id>"
    curl "localhost:7666/api/v1/sources?item=<id>&season=2&episode=3"
    curl "localhost:7666/api/v1/preferences"
    curl "localhost:7666/api/v1/addons"
    curl -X POST -H 'content-type: application/json' \
         -d '{"url": "https://v3-cinemeta.strem.io/manifest.json"}' \
         "localhost:7666/api/v1/addons"
    curl -X PATCH -H 'content-type: application/json' -d '{"subtitleLanguages":["ru","en"]}' localhost:7666/api/v1/preferences
    curl "localhost:7666/api/v1/preferences/languages"
    curl "localhost:7666/api/v1/about"
    curl "localhost:7666/api/v1/storage"                    # what is on disk, by title
    curl -X DELETE "localhost:7666/api/v1/storage?item=<id>" # free one title (no item: everything)
    curl -X PUT -H 'content-type: application/json' \
         -d '{"season":2,"episode":3,"position":734.5,"duration":2580}' \
         "localhost:7666/api/v1/progress/<id>"
    curl "localhost:7666/api/v1/progress/<id>"              # entries, what to play next, and an unaired one after
    curl "localhost:7666/api/v1/continue"                   # titles part-way through, latest first
    curl -X DELETE "localhost:7666/api/v1/continue/<id>"    # out of that row until it is next played
    curl "localhost:7666/api/v1/searches"                   # what was searched for, latest first

Item ids are Lumeo's own, created on first sight and mapped to imdb/tmdb/tvdb ids in SQLite.
`/api/v1/sources` also accepts `imdb=tt...`.

The viewer's own data moves between cores as one file: watch progress, scores, My list, picked
audio and subtitle tracks, searches and the personal preferences (languages, subtitle look, accent,
player timings). Downloads, addons and the machine's preferences (download folder, keep, limits,
updates) stay. Titles are named by IMDb id; progress on a local file no title matched stays behind.

    curl "localhost:7666/api/v1/personal" -o lumeo.json
    curl -X POST -H 'content-type: application/json' --data-binary @lumeo.json \
         "localhost:7666/api/v1/personal"     # what it changed, by kind

An import merges: of two entries for the same episode or score the later one wins, an entry on My
list keeps its date, and nothing is removed. A second import of the same file changes nothing.
One invalid entry refuses the whole file, and nothing is written.

Downloads take the source object from `/api/v1/sources` unchanged:

    curl -X POST localhost:7666/api/v1/downloads -d '{"itemId":"<id>","season":2,"episode":3,"source":{...}}'
    curl "localhost:7666/api/v1/downloads"          # progress: bytes, peers, rate
    curl -X DELETE "localhost:7666/api/v1/downloads/<id>"            # stop, keep the data
    curl -X DELETE "localhost:7666/api/v1/downloads/<id>?data=true"  # stop and delete the data

A file can be played while it downloads. A range request fetches the pieces it needs first, so
seeking works from the start:

    curl -r 0-1023 "localhost:7666/api/v1/downloads/<id>/stream" -o head.bin
    mpv --http-header-fields="Authorization: Bearer $(cat data/api-token)" \
        "http://localhost:7666/api/v1/downloads/<id>/stream"

Subtitles are requested for the downloaded file:

    curl "localhost:7666/api/v1/subtitles?item=<id>&download=<download id>"
    curl "localhost:7666/api/v1/subtitles/<id>"

The core hashes the file, so subtitles timed for that exact release come first, marked
`hashMatch`. Each result has a `url` on the core: the core fetches the subtitle, converts it to
UTF-8, and only fetches from the provider, never from arbitrary addresses.

Downloads are stored in `<data>/downloads/<id>` and resume after a restart.


## Linked to a server

A core can forward to a media server what the server owns: addons, metadata, sources, downloads,
streams, storage and the subtitles of a download. History, scores, My list, searches and
preferences stay with it ([architecture](architecture.md), A core linked to a server). The client
talks to it as to any other core: `/catalogs` answers the server's rows as the server does, and
artwork addresses are this core's, cached here. Link it while it is stopped, with a pairing code from the
server's `lumeo-core pair`:

    LUMEO_DATA=./data go run ./cmd/lumeo link https://lumeo.example.com <code> [device name]
    LUMEO_DATA=./data go run ./cmd/lumeo unlink

The client links its core the same way when it pairs with a media server, handing it the
credential the server issued; the owner token sets and reads the link over the API:

    curl -X PUT -H 'content-type: application/json' \
         -d '{"url":"https://lumeo.example.com","token":"<device credential>"}' localhost:7666/api/v1/link
    curl localhost:7666/api/v1/link          # {"url": used from the next start, "running": in use now, "saved": [...]}
    curl -X PATCH -d '{"url":"https://other.example.com"}' localhost:7666/api/v1/link   # "" for none
    curl -X DELETE 'localhost:7666/api/v1/link?url=https://other.example.com'          # no url: the one in use

`PUT` keeps the link once the server took the credential and said it is a media server: 409 for
any other, 422 for a credential it refused. A core that is a media server itself links to nothing.
The core keeps every server it was linked to, with its credential, and forwards to one or none:
`PUT` and `link` add a server and choose it, `PATCH` chooses a saved one (404 for another),
`DELETE` and `unlink` forget one. The links are `server.json` in the data directory, owner-only,
read at start; a file from before several were kept holds the one in use. The address is the
server's `LUMEO_PUBLIC_URL`; plain HTTP is accepted only on loopback. Unlinking keeps the device
on the server until it is revoked there.

The server runs with `LUMEO_MODE=media`, and `link` refuses any other before pairing: a full
server keeps its devices' personal data, and the two would disagree about where it lives. Every
answer of a core says its mode in the `Lumeo-Mode` header, so a server switched to full is noticed
on its next answer: the linked core forwards nothing more and answers 502 saying why.

A media server answers a device's request for personal data (progress, history, My list,
scores, choices, searches, preferences, the export) with 403. The owner's token, which stays on
the server's machine, keeps a full core there. Starting or playing a download makes a device's
hold on it; the device then says whether its viewer watched the episode, which subtitle languages
to keep, and its keep rules in days (`serverKeepWatchedDays` and `serverKeepUnwatchedDays` in its
own core's preferences, 1 and 7 unless set):

    curl -X PUT -H "Authorization: Bearer <device credential>" -H 'content-type: application/json' \
         -d '{"watched":true,"subtitleLanguages":["ru","en"],"keepWatchedDays":1,"keepUnwatchedDays":7}' \
         "https://lumeo.example.com/api/v1/downloads/<id>/hold"

The rules are optional and keep what the hold had when left out. A hold lasts while its rule has
not run out: a watched file from the mark, an unwatched one from the device's last start or play
or the download finishing, while bytes still arrive too. The server applies them whether or not
the device is online, capped by the owner's `deviceMaxKeepDays` (30 unless set), and frees a
download once no hold on it lasts. A device sees its own hold as `hold` in the download list, and is not told the server's folders
(`/about`, `/storage`): they are its owner's. A linked core's `/about` says `"linked": true`, for a
client to show the device's keep rules in place of its own folder, limits and keep policy.

A device deleting a download, or clearing a title from storage, lets go of its own hold: the
download leaves that device's lists, stays for any device whose hold lasts, and goes, file and
all, once none does, unless a stream of it is open. Playing it again holds it again. A download
no device ever held is the owner's, and deleting it from a device is refused with 403. Revoking a
device releases its holds.

The owner's `deviceDiskLimit` (bytes, none unless set) caps what each device holds: every file a
device's hold lasts on counts in full, though the server stores it once. A download that would
take the device over it is refused with 507, `size` the copy's and `free` what the limit leaves,
as a copy larger than the free disk is. Playing a file another device holds is never refused.
