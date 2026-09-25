#!/usr/bin/env bash
# Drives the real application and checks what it actually shows.
#
# Every check in integration_test/ is a defect that shipped, and none of them
# were reachable from a unit test: a wordmark printed twice in the same place,
# a panel clipped by the bar it hung from, a shortcut nothing could reach, a
# keystroke stolen from a text field. So the tests run against the real widget
# tree on a real screen, with a fake core behind them — no network, no binary,
# no swarm, and a failure that is always the client's.
#
#     client/tool/ui-test.sh
#
# The screen is a headless Weston, because this has to run on a machine with
# no desktop — CI, or a session over ssh — and because it has to be Wayland:
# GTK 3 on X11 gives Flutter a GLX context, and with no EGL context to share a
# display with, the media_kit plugin falls back to software rendering. The
# suite ran on Xvfb for a while and never once executed the render thread it
# was believed to cover; 0.1.19 shipped with every film stuck on its first
# frame and the suite green. Weston's GL renderer on llvmpipe is what the
# application meets on a Wayland desktop, GPU aside. Anything to do with the
# window itself (the title bar, dragging, maximising, real fullscreen) is not
# here: those need a window manager's decorations, and they are checked by
# hand against the built bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

for dir in /usr/local/flutter/bin; do
  if [[ -d $dir ]]; then PATH=$PATH:$dir; fi
done

for tool in flutter weston cc ffmpeg; do
  if ! command -v "$tool" >/dev/null; then
    echo "missing: $tool" >&2
    exit 1
  fi
done

log=$(mktemp -d "${TMPDIR:-/tmp}/lumeo-ui-test.XXXXXX")
weston_pid=
cleanup() {
  local status=$?
  [[ -n $weston_pid ]] && kill "$weston_pid" 2>/dev/null
  if (( status == 0 )); then
    rm -rf "$log"
  else
    printf '\nfailed (%d). Logs: %s\n' "$status" "$log" >&2
  fi
}
trap cleanup EXIT

# Weston puts its socket under XDG_RUNTIME_DIR, which a CI runner or an ssh
# session may not have; the log directory is private to this run and will do.
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-$log}
# A fresh state directory, so each run opens the window at its default size
# rather than the one the last run closed it at, and mpv's log stays with the
# rest of this run's.
export XDG_STATE_HOME=$log/state
socket=lumeo-ui-test-$$

# The window opens at 1440x900 (linux/runner/my_application.cc); the screen is
# larger so nothing clips it. idle-time=0: no screen blanking mid-test.
weston --backend=headless --renderer=gl --socket="$socket" \
  --width=1600 --height=1000 --idle-time=0 >"$log/weston.log" 2>&1 &
weston_pid=$!
for _ in $(seq 50); do
  if [[ -S $XDG_RUNTIME_DIR/$socket ]]; then break; fi
  sleep 0.2
done
if [[ ! -S $XDG_RUNTIME_DIR/$socket ]]; then
  # Printed rather than pointed at: on a CI runner the file goes with the machine.
  echo "weston did not come up:" >&2
  cat "$log/weston.log" >&2
  exit 1
fi
export GDK_BACKEND=wayland WAYLAND_DISPLAY=$socket

# See tool/no-libva-wayland.c: without this, libva crashes the application
# inside mpv's vaapi probe on any compositor that has no wl_drm.
cc -shared -fPIC -o "$log/no-libva-wayland.so" tool/no-libva-wayland.c
export LD_PRELOAD=$log/no-libva-wayland.so

# The test desktop's mpv rather than the system's, when tool/build-mpv.sh has built
# it: the dev box's Ubuntu ships 0.37, and CI keeps running on that one.
mpv_lib=${XDG_CACHE_HOME:-$HOME/.cache}/lumeo/mpv-0.41.0/lib/x86_64-linux-gnu
if [[ -e $mpv_lib/libmpv.so.2 ]]; then
  export LD_LIBRARY_PATH=$mpv_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  echo "libmpv: $mpv_lib" >&2
else
  echo "libmpv: the system's (tool/build-mpv.sh builds the test desktop's 0.41)" >&2
fi

# And a sound card, for the same reason as the screen: with no audio device
# mpv drops the soundtrack, and a test about audio tracks has none to pick.
# ALSA's null device takes the samples and throws them away; mpv reaches it
# through ALSA's default device once PipeWire and PulseAudio are not there.
printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' >"$log/asound.conf"
export ALSA_CONFIG_PATH=/usr/share/alsa/alsa.conf:$log/asound.conf

# Every build of the test bundle leaves a new 73 MB directory here and
# nothing removes the old ones; they once filled the dev box's disk. The three
# newest stay, so the next build still reuses one. A fresh checkout (CI) has
# the directory empty, and ls given no match fails the whole script.
builds=(.dart_tool/flutter_build/*/)
if ((${#builds[@]} > 3)); then
  ls -dt "${builds[@]}" | tail -n +4 | xargs -r rm -rf
fi

# Not exec: it would replace this shell and the trap above would never run,
# leaving a Weston and a temporary directory behind on every single run (eight
# Xvfbs were once found alive at once that way).
#
# One entry file, whose checks live beside it: a second application launched
# in the same `flutter test` session dies before it connects ("The log reader
# stopped unexpectedly") — on CI's clean runner as much as here.
flutter test integration_test/app_test.dart -d linux "$@"
