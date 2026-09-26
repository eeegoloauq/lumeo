# Contributing

Lumeo is a Go core (`core/`, one binary and SQLite, listening on `127.0.0.1:7666`) and a Flutter
client for Linux and Windows (`client/`) that plays through embedded libmpv. The client talks to the
core over HTTP, even on one machine.

Read [docs/architecture.md](docs/architecture.md) for how it fits together and
[docs/decisions/](docs/decisions/README.md) before changing something that was decided on purpose:
each decision says what was rejected and why. [docs/core.md](docs/core.md) covers the core's
settings and HTTP API, [docs/roadmap.md](docs/roadmap.md) what comes next.

## What you need

- Go (the version in `core/go.mod`).
- Flutter 3.47.2, the version CI pins.
- Flutter's Linux toolchain and libmpv with its headers. On Debian and Ubuntu, as CI installs them:
  `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libmpv-dev`.
- For the UI tests: `weston` and `ffmpeg`. `client/tool/build-mpv.sh` builds libmpv 0.41 into
  `~/.cache/lumeo` when your distribution's is older; the UI tests use it when it is there.

## Running it

    client/tool/dev.sh start      # a core and the client, with hot reload
    client/tool/dev.sh reload     # after an edit
    client/tool/dev.sh stop

Or each half on its own:

    cd core && LUMEO_DATA=./data go run ./cmd/lumeo
    cd client && flutter run -d linux

## Checks

A pull request has to pass these.

Core:

    cd core
    go vet ./... && GOOS=windows go vet ./...
    gofmt -l .                     # prints nothing
    go test -race ./...
    CGO_ENABLED=0 go build ./cmd/lumeo

Code for one OS goes in `_unix.go` / `_windows.go` files, which is why the Windows vet is in the list.

Client:

    cd client
    dart format --output=none --set-exit-if-changed lib test integration_test
    flutter analyze
    flutter test
    tool/ui-test.sh                # the real app on a headless Weston, about five minutes

`dart format lib test integration_test` fixes what the first line complains about; format on save
in your editor and it never does. `third_party/` is left alone: it stays upstream's code.

`tool/ui-test.sh --plain-name "<test name>"` runs one UI test. Every check in
`client/integration_test/` is a defect that once shipped; a fix for a visible defect comes with one.

Nothing here builds or runs the Windows client (`packaging/build-windows.sh` runs on Windows only),
so a change to `client/windows/` or to a Windows branch in Dart needs checking on a Windows machine.

## The player

mpv owns the player's behaviour: keys and mouse buttons go to it as `keydown`/`keyup`, and seeks and
settings are mpv commands and properties observed back. A new player feature is an mpv property or
command first, and Dart only where embedded mpv cannot do it. Never make a blocking mpv call on the
Dart thread: on Linux it is GTK's, and the whole interface stalls during every seek.

`client/third_party/media_kit_video` is a patched copy of upstream 2.0.1. Read its `LUMEO.md` before
changing it, and keep a `diff -r` against upstream equal to the patches listed there.

## Translations

The interface's text lives in `client/lib/l10n/`: `app_en.arb` is the source, every other
`app_<code>.arb` a translation of it, and `flutter pub get` generates `AppLocalizations` from them.
A string on screen is `context.l10n.someKey`, never a literal; counts are ICU plurals, and a sentence
is one message with placeholders, never pieces joined in code, so a translation can reorder it.

A new language is one file: copy `app_en.arb` to `app_<code>.arb`, set `@@locale`, translate the
values (the `@key` descriptions say where each one appears) and drop the `@` entries. It appears
under Settings → General by its `languageName`. A key left out falls back to English. Titles,
descriptions and genres come from the metadata provider and stay as it sends them.

## Commits

English, one change per commit, `type: what and why` (`fix:`, `feat:`, `refactor:`, `test:`,
`docs:`, `build:`, `chore:`). Code comments say why in a line or two, not the history; the history is
in git.

## Releases

Add the version to the `%changelog` in `packaging/lumeo.spec` and to
`packaging/dev.lumeo.lumeo.metainfo.xml`, then push `main` and an annotated `vX.Y.Z` tag in one
push. The tag message is the release notes. `packaging/build-dist.sh` makes the bundle and tarball;
`build-rpm.sh` and `build-arch.sh` package that tarball.
