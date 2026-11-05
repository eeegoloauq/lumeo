# Contributing

Lumeo is a Go core (`core/`, one binary and SQLite, listening on `127.0.0.1:7666`) and a Qt Quick
client for Linux and Windows (`desktop/`) that plays through embedded libmpv. The client talks to
the core over HTTP, even on one machine.

Read [docs/architecture.md](docs/architecture.md) for how it fits together and
[docs/decisions/](docs/decisions/README.md) before changing something that was decided on purpose:
each decision says what was rejected and why. [docs/core.md](docs/core.md) covers the core's
settings and HTTP API, [docs/roadmap.md](docs/roadmap.md) what comes next.

## What you need

- Go (the version in `core/go.mod`).
- Qt 6.12 with Image Formats (artwork arrives in WebP too), Shader Tools, HTTP Server and
  WebSockets (the fake core in the tests). `packaging/install-qt.sh` installs that Qt into
  `~/.cache/lumeo/qt`, as CI does; a distribution's Qt 6.8 or later builds too, with its private
  headers (`qt6-qtbase-private-devel` on Fedora), which the gamepad's keys come in through.
- libmpv with its headers, SDL3 3.2 or later, CMake, Ninja, ccache and mold. On Fedora:
  `sudo dnf install cmake ninja-build gcc-c++ ccache mold mpv-devel SDL3-devel`; on Debian and
  Ubuntu, as CI installs them: `cmake ninja-build pkg-config ccache mold libgl-dev libegl-dev
  libxkbcommon-dev libmpv-dev libudev-dev`. Ubuntu 24.04 has no SDL3: `packaging/build-sdl.sh`
  builds the release's into `~/.cache/lumeo` and prints where, for `SDL3_ROOT`.
- For the player tests: `weston` and `ffmpeg`. `desktop/tool/build-mpv.sh` builds libmpv 0.41 into
  `~/.cache/lumeo` when your distribution's is older; the player tests use it when it is there.

## Running it

From `desktop/`:

    cmake --preset dev        # once; add -DCMAKE_PREFIX_PATH=<qt>/gcc_64 for a Qt of your own
                              # and -DSDL3_ROOT=$(../packaging/build-sdl.sh) without a system SDL3
    cmake --build --preset dev
    build/dev/bin/lumeo [file or lumeo:// link]

It talks to the core on `127.0.0.1:7666` with the token from the data directory: start one with
`cd core && LUMEO_DATA=./data go run ./cmd/lumeo`, or leave a running Lumeo's. With a `lumeo-core`
beside the binary, as installed, it starts that one itself and is one instance per session
(decisions/shipping.md). mpv's log is `mpv.log` in the state folder (`~/.local/state/lumeo`), the
previous one beside it, unless `LUMEO_MPV_LOG=<file>` names another.

## Checks

A pull request has to pass these.

Core:

    cd core
    go vet ./... && GOOS=windows go vet ./...
    gofmt -l .                     # prints nothing
    go test -race ./...
    CGO_ENABLED=0 go build ./cmd/lumeo

Code for one OS goes in `_unix.go` / `_windows.go` files, which is why the Windows vet is in the list.

Client, from `desktop/`:

    cmake --build --preset dev
    ctest --test-dir build/dev --output-on-failure    # units, app tests and qmllint, under a minute
    taskset -c 1 ctest --test-dir build/dev --repeat until-fail:5    # on one CPU, about three
    tool/player-test.sh                               # the player on a headless Weston, about two

    cmake --preset sanitize && cmake --build --preset sanitize    # for ownership or lifetimes
    ctest --test-dir build/sanitize --output-on-failure           # under ASan, UBSan and LSan

Tests go in the lowest layer that can show the behaviour, once: units under QtTest in
`desktop/tests/*_test.cpp`, the whole app over the fake core in `desktop/tests/app/`, and only what
needs a real libmpv in `desktop/tests/player/`. [docs/decisions/testing.md](docs/decisions/testing.md)
says what goes where and what a test does not check. qmllint fails on any warning
(`desktop/qml/.qmllint.ini`); a line whose types it cannot see takes `// qmllint disable <category>` and a
comment saying why. A fix for a visible defect comes with a test.
The sanitize preset builds the same tests with AddressSanitizer and UndefinedBehaviorSanitizer, and a
leak at exit fails a test; CI runs it as a job of its own. A report from Qt, Mesa or libmpv goes in
`desktop/tests/sanitizers/lsan.supp`, matched as narrowly as its stack allows and with a comment
saying why it is not ours; one of ours is fixed.
The run on one CPU is for a change to the app, QML or anything asynchronous: the CI runners,
Windows most, are slower than a desktop, and a test that checks a moment rather than waiting for a
state fails there first (a Linux system without `taskset` drops the prefix).
`tool/player-test.sh` takes Qt Quick Test's options, `-input tests/player/tst_gear.qml` for one
file. GitHub CI runs all of it on every push to `main` that touches the client and on every tag,
and the release is published only when it passes. On a headless Weston without a GPU,
`tool/no-libva-wayland.c` is preloaded, as `player-test.sh` does.

Nothing here builds or runs the Windows client. GitHub CI builds it and runs the units and app tests
on Windows on every push to `main` that touches the client; the player tests, the installer
(`build-windows.sh`, `lumeo.iss`) and anything a real desktop shows (tray, focus, GPU) still need
checking on a Windows machine.

## The player

mpv owns the player's behaviour: keys and mouse buttons go to it as `keydown`/`keyup`, and seeks and
settings are mpv commands and properties observed back. A new player feature is an mpv property or
command first, and C++ or QML only where embedded mpv cannot do it. Never make a blocking mpv call on
the GUI thread: properties are observed on mpv's event loop and posted to it, and a synchronous call
there stalls the whole interface during every seek.

## Translations

The interface's text lives in `desktop/i18n/`: `lumeo_en.ts` is the source, every other
`lumeo_<code>.ts` a translation of it. A string on screen is `qsTrId("someId")` (`qtTrId` in C++),
never a literal; each message's comment says where it appears and names its placeholders, `%1`, `%2`
in the English order. Counts are `%n` plurals, and a sentence is one message with placeholders,
never pieces joined in code, so a translation can reorder it.

A new language is one file: copy `lumeo_en.ts` to `lumeo_<code>.ts`, set its `language`, translate
the `<translation>`s (Qt Linguist opens it) and list it under `TS_FILES` in
`desktop/CMakeLists.txt`. It appears under Settings → General by its `languageName`. A message left
out falls back to English. Titles, descriptions and genres come from the metadata provider and stay
as it sends them.

## Commits

English, one change per commit, `type: what and why` (`fix:`, `feat:`, `refactor:`, `test:`,
`docs:`, `build:`, `chore:`). Code comments say why in a line or two, not the history; the history is
in git.

## Releases

The release notes are written once, as a `<release>` in
`client/assets/dev.lumeo.lumeo.metainfo.xml`, the one file left under `client/`: every released
core reads a newer release's notes from that path. The app shows them after an update (a `<li
xml:lang="ru">` beside each English one translates it), `packaging/release-notes.py` makes the
RPM `%changelog` and the GitHub release's items from them. Then push `main` and an annotated
`vX.Y.Z` tag in one push; the tag message is one line, the release's headline. A tag is a patch
(`v0.3.0` → `v0.3.1`) unless the change is clearly large; a major one only when asked.

The items go under the headings Added, Improved, Fixed and Removed, in that order and only those
with items: each heading a `<p>` with its `<p xml:lang="ru">` (Добавлено, Улучшено, Исправлено,
Удалено), then its `<ul>`. Each item is one change the user sees, in about 5 to 12 words; the
heading says what happened to it ("Saving screenshots on NVIDIA" under Fixed), and causes,
instructions, internal terms, CI and tests stay out. The app and the GitHub page show the groups,
the RPM changelog the items alone; a release written before the headings shows its items under
none, after the rest.

```xml
<release version="0.1.80" date="2026-11-06">
  <description>
    <p>Added</p>
    <p xml:lang="ru">Добавлено</p>
    <ul>
      <li>Gamepad controls.</li>
      <li xml:lang="ru">Управление геймпадом.</li>
    </ul>
    <p>Fixed</p>
    <p xml:lang="ru">Исправлено</p>
    <ul>
      <li>Saving screenshots on NVIDIA.</li>
      <li xml:lang="ru">Сохранение скриншотов на NVIDIA.</li>
    </ul>
  </description>
</release>
```

A beta is a `vX.Y.Z-beta.N` tag with its own `<release version="X.Y.Z~beta.N"
type="development">` entry: what changed since the beta before, which the app shows to whoever
updates from it (the `~` sorts it before X.Y.Z in AppStream and RPM). Its GitHub page lists every
beta of X.Y.Z so far. The release's `<release version="X.Y.Z">` entry sums its betas up and goes on
top of them; the beta entries stay. A beta is published as a GitHub pre-release: anyone can
download it, and the app offers it only to those who turned on "Offer betas" in About. A beta is
told when its release is out. Publishing a beta or a release removes the older betas from the
releases page; their tags stay. Betas go out when there is something to try; the release follows
once they are checked.
`packaging/build-dist.sh` makes the bundle and tarball, with the Qt of `install-qt.sh` in it;
`build-rpm.sh` and `build-arch.sh` package that tarball, `build-windows.sh` the Windows installer.
`packaging/container/Containerfile` is the server image, built from `core/` (its first lines say
how); the release pushes it to GHCR after publishing. The first push of the package leaves it
private: make it public once in the package's settings on GitHub.
The Windows libmpv is a pinned build mirrored into this repository's releases by
`.github/workflows/libmpv.yml`; a bump is that workflow run once and the four lines in
`fetch-libmpv.sh`.

## Share site

`site/` is the page a shared title link opens, served by GitHub Pages from the mirror:
`.github/workflows/site.yml` deploys it on every push to `main` that touches it (the repository's
Pages source is GitHub Actions). `site/build.sh _site` assembles it locally; any static server on
`_site` shows it.
