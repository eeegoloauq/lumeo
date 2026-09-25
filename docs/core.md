# The core

How to run the core on its own, configure it and talk to its HTTP API. How it works inside is in
[architecture.md](architecture.md).

## Running it

    cd core
    LUMEO_DATA=./data go run ./cmd/lumeo

It listens on `127.0.0.1:7666`. Every request needs the token the core writes to `api-token` in its data directory (0600,
so only your own account can read it); over a network it would travel in the clear, so keep it on localhost. A new database starts with Cinemeta for
the catalogue and OpenSubtitles v3 for subtitles; neither needs an API key. No source addon ships:
add one to have something to play.
Each addon's role is read from its manifest. Edit the list on the client's Sources page or over
`/api/v1/addons`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `LUMEO_ADDR` | `127.0.0.1:7666` | Listen address |
| `LUMEO_DATA` | `$XDG_DATA_HOME/lumeo` | Directory of the SQLite database and downloads |
| `LUMEO_ADDONS` | Cinemeta, OpenSubtitles | Addons for an empty database: comma-separated URLs, optionally `name=url`, or `none` |
| `LUMEO_SUBTITLE_LANGS` | `en` | Default subtitle language order; a preference set in the client wins |
| `LUMEO_TORRENT_PORT` | any free port | BitTorrent listen port |
| `LUMEO_SEED` | `true` | Default of seeding once a download completes; the preference set in the client wins |
| `LUMEO_EPISODE_ARTWORK` | `blur` | Default for unwatched episode stills: `show`, `blur` or `hide` |

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
    curl "localhost:7666/api/v1/progress/<id>"              # entries, and what to play next
    curl "localhost:7666/api/v1/continue"                   # titles part-way through, latest first
    curl "localhost:7666/api/v1/searches"                   # what was searched for, latest first

Item ids are Lumeo's own, created on first sight and mapped to imdb/tmdb/tvdb ids in SQLite.
`/api/v1/sources` also accepts `imdb=tt...`.

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

