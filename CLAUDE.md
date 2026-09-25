# Lumeo

Self-hosted films and series: a Go core (`core/`, one binary + SQLite, `127.0.0.1:7666`) and a
Flutter client for Linux and Windows (`client/`) that plays through embedded libmpv. The client always
talks to the core over HTTP, even on one machine. Commands, checks and release steps are in
`CONTRIBUTING.md`. Docs: `docs/architecture.md` (how it works), `docs/decisions/` (why — read the
file for the area before reopening a choice), `docs/roadmap.md` (what is next).

## Checks

- The core gate (`CONTRIBUTING.md`, Checks) runs before merging any core change.
- `tool/ui-test.sh` runs the real app on headless Weston (Wayland/EGL). Xvfb gives Flutter GLX,
  media_kit falls back to software and the mpv render thread is never exercised. Kill Weston by
  pid: `pkill -f weston` from a tool call kills your own shell.
- Ubuntu ships libmpv 0.37, Fedora 0.41. `client/tool/build-mpv.sh` builds 0.41.0 into
  `~/.cache/lumeo` and `tool/ui-test.sh` runs on it when it is there (it prints which). CI stays on
  the runner's 0.37, so both versions are covered.
- While debugging, run one UI test: `tool/ui-test.sh --plain-name "<test name>"` (about a
  minute). The full suite (about five) runs once before the commit. A later fix that the tests
  it touches cover is checked with those; the full suite runs again only when a fix reaches
  shared code (the shell, the player, the fake core) and before a release.
- UI checks live in `client/integration_test/<area>.dart`, all started from `app_test.dart`: every
  `*_test.dart` there is a build and a launch of its own.
- A UI test never waits out one of the app's own timers. A timeout it needs to see run out is a
  `@visibleForTesting` value the test shortens (`openPatience`); a check that something did not
  happen waits one or two cycles of the timer behind it; a setting is read back from mpv rather
  than proved by waiting for its effect.
- Nothing here builds or runs the Windows client, so a change to `client/windows/` or a Windows
  branch in Dart is checked on a real Windows machine.

## CI

- Forgejo (`origin`) gates core pull requests (`.forgejo/`); since that directory exists, Forgejo
  ignores `.github/`. Client CI and releases run on the GitHub push mirror.
- A cloud session (claude.ai/code) works on the GitHub mirror, where no core gate runs: run the core
  gate before merging its pull request. Its client check is `dart format`, `flutter analyze` and
  `flutter test` only: `tool/ui-test.sh` cannot build there (the proxy refuses the GitHub archive
  media_kit's CMake downloads), so the UI suite runs in GitHub CI on the push to main. Say which UI
  tests a change is waiting on.

## Player

- mpv owns behaviour: keys and mouse buttons go to it as `keydown`/`keyup`, seeks and settings are
  mpv commands and properties observed back. A new player feature is an mpv property or command
  first; Dart only when embedded mpv cannot do it.
- Never make a blocking mpv call on the Dart thread (`mpv_get_property`, `platform.getProperty`,
  `observeProperty` on fast-changing properties). On Linux that thread is GTK's; the whole UI
  stalls during every seek.
- On Windows, libmpv and the `media_kit_video` half are media_kit's own (libmpv from 2023-09);
  the fork's patches are Linux-only.
- `client/third_party/media_kit_video` is a fork of upstream 2.0.1: read its `LUMEO.md` first,
  keep the upstream API, check every change with `tool/ui-test.sh` and on real NVIDIA/Wayland
  hardware before calling it fixed.
- Never compute waits from mpv's `target_time`: documented as µs, it is ns since mpv 0.36.
- The renderer is Flutter's default, Impeller. A picture problem on NVIDIA is compared against
  Skia first; `docs/decisions/video-output.md` says how.
- Fedora without the freeworld codecs decodes h264 with openh264; its desync reports are below us
  (`DeviceDecoders` in `client/lib/platform/decoders.dart`).

## Rules

- Every request to the core carries the token from `<data>/api-token`; artwork alone goes by an
  unguessable address instead. The core binds to localhost: exposing it needs TLS and a way to
  hand a remote client the token first.
- Fix causes, not symptoms; a workaround needs the user's agreement and a comment saying why.
- Commits: English, `type: what and why`, no `Co-Authored-By`, `Claude-Session` or other bot
  trailers, a cloud session's default included. Comments explain why in a line or two, not the
  history.
