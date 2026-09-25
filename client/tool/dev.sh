#!/usr/bin/env bash
# The loop for working on the interface: one window that stays up, and an edit
# that lands in it in about a second.
#
#     client/tool/dev.sh start          # screen, core and client, once
#     client/tool/dev.sh reload         # after an edit — hot reload
#     client/tool/dev.sh restart        # when the state has to go too
#     client/tool/dev.sh shot bar.png   # one frame of the window
#     client/tool/dev.sh log            # what the client has printed
#     client/tool/dev.sh stop
#
# Why this exists: `flutter build linux --release` is minutes and this is a
# second, which is the difference between trying a layout and arguing about it.
# `flutter run` reloads on SIGUSR1, so the window does not have to be attached
# to anybody's terminal — an agent editing the files can reload it too.
#
# With DISPLAY already set the window opens on that screen, which is what to do
# on a desktop. With nothing set it opens on an Xvfb of its own, and `shot` is
# then the only way to see it — which is what to do over ssh, and what the
# screenshots in docs/ are taken from.
set -euo pipefail

readonly api=http://127.0.0.1:7666
readonly window=1440x900

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd -- "$here/../.." && pwd)
state=${LUMEO_DEV_STATE:-${XDG_RUNTIME_DIR:-/tmp}/lumeo-dev}
# The core's data directory. The client is given it too: its API token is there.
data=${LUMEO_DATA:-$repo/core/data}

for dir in /usr/local/go/bin /usr/local/flutter/bin; do
  if [[ -d $dir ]]; then PATH=$PATH:$dir; fi
done

need() {
  local missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  if (( ${#missing[@]} )); then
    echo "missing: ${missing[*]}" >&2
    exit 1
  fi
}

# The display the window is on, whether we started it or inherited it.
screen() { cat "$state/display" 2>/dev/null || true; }

client_pid() { cat "$state/flutter.pid" 2>/dev/null || true; }

alive() { [[ -n ${1:-} ]] && kill -0 "$1" 2>/dev/null; }

# The window id, which is what a frame is grabbed from. Not cached: the client
# is restarted more often than this script is.
window_id() {
  DISPLAY=$(screen) xdotool search --name '^Lumeo$' 2>/dev/null | head -1
}

start() {
  need flutter xdotool
  if alive "$(client_pid)"; then
    echo "already running (pid $(client_pid)) on $(screen)" >&2
    return 0
  fi
  mkdir -p "$state"

  if [[ -n ${DISPLAY:-} ]]; then
    echo "$DISPLAY" >"$state/display"
  else
    need Xvfb
    # Its own display, whatever else is on the machine — a headless browser
    # usually owns :99 already.
    local display=
    for n in $(seq 90 120); do
      if [[ ! -e /tmp/.X$n-lock ]]; then display=":$n"; break; fi
    done
    [[ -n $display ]] || { echo "no free X display" >&2; exit 1; }
    # A screen larger than the window, so nothing clips it and the pointer has
    # somewhere to park where it leaves no hover state in a frame.
    Xvfb "$display" -screen 0 "1600x1000x24" -nolisten tcp \
      >"$state/xvfb.log" 2>&1 &
    echo $! >"$state/xvfb.pid"
    echo "$display" >"$state/display"
    export DISPLAY=$display
    for _ in $(seq 50); do
      xdpyinfo >/dev/null 2>&1 && break
      sleep 0.2
    done
  fi

  core

  echo "client (first build is the slow one)"
  cd "$repo/client"
  DISPLAY=$(screen) LUMEO_DATA=$data flutter run -d linux \
    --pid-file "$state/flutter.pid" \
    >"$state/client.log" 2>&1 </dev/null &
  # flutter writes the pid file itself, once it is ready to be signalled.
  for _ in $(seq 600); do
    [[ -s $state/flutter.pid ]] && break
    sleep 0.5
  done
  [[ -s $state/flutter.pid ]] ||
    { tail -30 "$state/client.log" >&2; echo "the client never came up" >&2; exit 1; }
  for _ in $(seq 60); do
    [[ -n $(window_id) ]] && break
    sleep 0.5
  done
  printf 'up on %s — edit, then `%s reload`\n' "$(screen)" "$0"
}

# A core to talk to, unless something already answers. Left running between
# client restarts: its SQLite cache is what makes the catalogue instant.
core() {
  # Any answer counts, 401 included: the core asks for its token.
  if curl -sS -m 2 -o /dev/null "$api/healthz" 2>/dev/null; then
    echo "core: already answering on $api"
    return 0
  fi
  need go curl
  echo "core: building"
  (cd "$repo/core" && go build -mod=readonly -o "$state/lumeo-core" ./cmd/lumeo)
  LUMEO_DATA=$data "$state/lumeo-core" >"$state/core.log" 2>&1 &
  echo $! >"$state/core.pid"
  for _ in $(seq 60); do
    curl -sS -m 2 -o /dev/null "$api/healthz" 2>/dev/null && return 0
    sleep 0.5
  done
  tail -20 "$state/core.log" >&2
  echo "the core never answered" >&2
  exit 1
}

# SIGUSR1 is hot reload, SIGUSR2 is hot restart: state kept, or state dropped.
# Reload is wrong for a change to a `late final` field or to anything created
# in initState — the object is already there and keeps the old value.
reload() {
  local pid; pid=$(client_pid)
  alive "$pid" || { echo "nothing is running" >&2; exit 1; }
  kill -USR1 "$pid"
  # The reload is asynchronous; the log line is what says it landed.
  sleep 1.5
  tail -3 "$state/client.log"
}

restart() {
  local pid; pid=$(client_pid)
  alive "$pid" || { echo "nothing is running" >&2; exit 1; }
  kill -USR2 "$pid"
  sleep 3
  tail -3 "$state/client.log"
}

# One frame of the window, waited for rather than demanded: X answers "resource
# temporarily unavailable" until the window is mapped and drawn.
shot() {
  need import
  local out=${1:-$state/shot.png} win
  win=$(window_id)
  [[ -n $win ]] || { echo "no Lumeo window on $(screen)" >&2; exit 1; }
  for _ in $(seq 40); do
    if DISPLAY=$(screen) import -window "$win" "$out" 2>/dev/null; then
      echo "$out"
      return 0
    fi
    sleep 0.5
  done
  echo "the window could not be photographed" >&2
  exit 1
}

stop() {
  for name in flutter core xvfb; do
    local pid; pid=$(cat "$state/$name.pid" 2>/dev/null || true)
    if alive "$pid"; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$state/$name.pid"
  done
  # flutter run spawns the application as a child; killing the tool leaves it.
  pkill -f "$repo/client/build/linux/x64/debug/bundle/lumeo" 2>/dev/null || true
  echo "stopped"
}

case "${1:-start}" in
  start) start ;;
  reload) reload ;;
  restart) restart ;;
  shot) shot "${2:-}" ;;
  log) tail -"${2:-40}" "$state/client.log" ;;
  stop) stop ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
