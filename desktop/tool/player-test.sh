#!/usr/bin/env bash
# Runs the player tests (tests/player/) on a headless Weston, with a real
# libmpv and a clip made here:
#
#     desktop/tool/player-test.sh [qmltestrunner options]
#
# Weston, not Xvfb: the application meets Wayland and EGL on a desktop, and
# its render thread is what these tests are for (decisions/testing.md). Build
# first (cmake --build --preset dev).
set -euo pipefail

cd "$(dirname "$0")/.."
test=build/dev/tests/player_test
for tool in weston cc ffmpeg; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
[[ -x $test ]] || { echo "missing: $test (cmake --build --preset dev)" >&2; exit 1; }

log=$(mktemp -d "${TMPDIR:-/tmp}/lumeo-player-test.XXXXXX")
weston_pid=
cleanup() {
  local status=$?
  [[ -n $weston_pid ]] && kill "$weston_pid" 2>/dev/null
  if ((status == 0)); then rm -rf "$log"; else printf '\nfailed (%d). Logs: %s\n' "$status" "$log" >&2; fi
}
trap cleanup EXIT

export XDG_RUNTIME_DIR=$log
socket=lumeo-player-test-$$
weston --backend=headless --renderer=gl --socket="$socket" \
  --width=1600 --height=1000 --idle-time=0 >"$log/weston.log" 2>&1 &
weston_pid=$!
# EGL on llvmpipe has taken over 6 s to come up on a CI runner.
for _ in $(seq 300); do
  if [[ -S $log/$socket ]] || ! kill -0 "$weston_pid" 2>/dev/null; then break; fi
  sleep 0.2
done
[[ -S $log/$socket ]] || { echo "weston did not come up:" >&2; cat "$log/weston.log" >&2; exit 1; }
export WAYLAND_DISPLAY=$socket QT_QPA_PLATFORM=wayland

# libva crashes inside mpv's vaapi probe on a compositor without wl_drm
# (client/tool/no-libva-wayland.c).
cc -shared -fPIC -o "$log/no-libva-wayland.so" ../client/tool/no-libva-wayland.c
export LD_PRELOAD=$log/no-libva-wayland.so

# The test desktop's mpv when client/tool/build-mpv.sh has built it; CI runs
# the system's.
mpv_lib=${XDG_CACHE_HOME:-$HOME/.cache}/lumeo/mpv-0.41.0/lib/x86_64-linux-gnu
if [[ -e $mpv_lib/libmpv.so.2 ]]; then
  export LD_LIBRARY_PATH=$mpv_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
  echo "libmpv: $mpv_lib" >&2
else
  echo "libmpv: the system's" >&2
fi

# No sound card here: ALSA's null device takes the samples, so the clip keeps
# its soundtrack.
printf 'pcm.!default { type null }\nctl.!default { type hw card 0 }\n' >"$log/asound.conf"
export ALSA_CONFIG_PATH=/usr/share/alsa/alsa.conf:$log/asound.conf

export LUMEO_TEST_CLIP=$log/clip.mkv
ffmpeg -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24:duration=20 \
  -f lavfi -i sine=frequency=440:duration=20 -c:v libx264 -preset ultrafast -c:a aac \
  "$LUMEO_TEST_CLIP"

# Not exec, or the trap above never runs and Weston stays behind.
"$test" "$@"
