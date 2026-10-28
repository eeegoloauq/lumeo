# Lumeo

Self-hosted films and series: a Go core (`core/`, one binary + SQLite, `127.0.0.1:7666`) and a
Qt Quick client for Linux and Windows (`desktop/`) that plays through embedded libmpv. The client
always talks to the core over HTTP, even on one machine. Commands, checks and release steps are in
`CONTRIBUTING.md`. Docs: `docs/architecture.md` (how it works), `docs/decisions/` (why — read the
file for the area before reopening a choice), `docs/roadmap.md` (what is next).

## Checks

- The core gate (`CONTRIBUTING.md`, Checks) runs before merging any core change.
- `desktop/tool/player-test.sh` runs the player tests on headless Weston (Wayland/EGL), where mpv's
  render path is the one a desktop uses. Kill Weston by pid: `pkill -f weston` from a tool call
  kills your own shell.
- Ubuntu ships libmpv 0.37, Fedora 0.41. `desktop/tool/build-mpv.sh` builds 0.41.0 into
  `~/.cache/lumeo` and `player-test.sh` runs on it when it is there (it prints which). CI stays on
  the runner's 0.37, so both versions are covered.
- Tests by layer (`docs/decisions/testing.md`, read it before adding one): units under QtTest in
  `desktop/tests/*_test.cpp`, the whole app over the fake core in `desktop/tests/app/`, and only
  what needs a real libmpv in `desktop/tests/player/`. Lowest layer that shows the behaviour,
  once; behaviour, not looks. Search for existing tests of the behaviour first.
- `ctest` (under a minute) runs every time; `player-test.sh` (about two) when the player, `Main.qml`
  or `tests/player/` is touched. GitHub CI runs both on every client push to main and on the tag,
  and the release is published only when they pass.
- No test waits out one of the app's own timers. A timeout it needs to see run out is a property
  the test shortens (`Core::patience`, `Next.second`); a check that something did not happen
  waits one or two cycles of the timer behind it; a setting is read back from mpv rather than
  proved by waiting for its effect.
- Nothing here builds or runs the Windows client. GitHub CI runs the units and app tests on Windows
  on every client push; `lumeo.iss`, `build-windows.sh` and what a real desktop shows (tray,
  focus, GPU) are checked on a real Windows machine, the release workflow being their first build.

## CI

- Forgejo (`origin`) gates core pull requests (`.forgejo/`); since that directory exists, Forgejo
  ignores `.github/`. Client CI and releases run on the GitHub push mirror.
- A cloud session (claude.ai/code) works on the GitHub mirror, where no core gate runs: run the core
  gate before merging its pull request. Its client check is the build and `ctest` with the Qt of
  `packaging/install-qt.sh`; the player tests run in GitHub CI on the push to main. Say which
  player tests a change is waiting on.

## Player

- mpv owns behaviour: keys and mouse buttons go to it as `keydown`/`keyup`, seeks and settings are
  mpv commands and properties observed back. A new player feature is an mpv property or command
  first; C++ or QML only when embedded mpv cannot do it.
- Never make a blocking mpv call on the GUI thread (`mpv_get_property`, waiting on a command's
  reply): properties are observed on mpv's event loop and posted over. A synchronous call there
  stalls the whole interface during every seek.
- mpv renders through its render API into a framebuffer object on Qt Quick's render thread, in
  desktop OpenGL (`src/main.cpp` says why not GLES on NVIDIA).
- On Windows libmpv is a pinned shinchiro build, mirrored by `.github/workflows/libmpv.yml`; the
  bundle carries it. On Linux it is the system's.
- Fedora without the freeworld codecs decodes h264 with openh264; its desync reports are below us
  (`MpvFacts::unreliable` in `desktop/src/player/mpvfacts.cpp`).

## Rules

- Every request to the core carries the token from `<data>/api-token`; artwork alone goes by an
  unguessable address instead. The core binds to localhost: exposing it needs TLS and a way to
  hand a remote client the token first.
- Interface text is short: a setting is a name and a control, a hint only for a consequence
  nobody would guess (`docs/decisions/interface.md`, Settings).
- Fix causes, not symptoms; a workaround needs the user's agreement and a comment saying why.
- Commits: English, `type: what and why`, no `Co-Authored-By`, `Claude-Session` or other bot
  trailers, a cloud session's default included. Comments explain why in a line or two, not the
  history.
