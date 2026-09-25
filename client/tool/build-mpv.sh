#!/usr/bin/env bash
# Builds the libmpv the test desktop's Fedora ships, for tool/ui-test.sh to run on.
#
#     client/tool/build-mpv.sh
#
# The dev box is Ubuntu 24.04, whose libmpv is 0.37, and mpv changed under
# us between the two more than once: target_time went from µs to ns (0.36),
# the subtitle box moved to sub-border-style (0.38), the software screenshot
# stopped reading nvdec frames (0.41). A suite green on 0.37 said nothing
# about any of it. The build goes to a cache directory and replaces nothing
# on the system; ui-test.sh uses it when it is there.
set -euo pipefail

version=0.41.0
sha256=ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209
prefix=${XDG_CACHE_HOME:-$HOME/.cache}/lumeo/mpv-$version

if [[ -e $prefix/lib/x86_64-linux-gnu/libmpv.so.2 ]]; then
  echo "already built: $prefix"
  exit 0
fi

for tool in curl meson ninja pkg-config cc; do
  if ! command -v "$tool" >/dev/null; then
    echo "missing: $tool" >&2
    exit 1
  fi
done

work=$(mktemp -d "${TMPDIR:-/tmp}/lumeo-mpv.XXXXXX")
trap 'rm -rf "$work"' EXIT

# On the dev box the network goes through `p`; elsewhere curl runs as is.
fetch=(curl -fsSL)
if command -v p >/dev/null; then fetch=(p "${fetch[@]}"); fi
"${fetch[@]}" -o "$work/mpv.tar.gz" \
  "https://github.com/mpv-player/mpv/archive/refs/tags/v$version.tar.gz"
echo "$sha256  $work/mpv.tar.gz" | sha256sum -c --quiet
tar -xzf "$work/mpv.tar.gz" -C "$work"

# Lua is required, not left to chance: the OSC and the console the player
# relies on are Lua scripts, and a build without them differs from Fedora's.
meson setup "$work/build" "$work/mpv-$version" \
  --prefix="$prefix" --buildtype=release \
  -Dlibmpv=true -Dcplayer=true -Dlua=enabled
meson compile -C "$work/build"
meson install -C "$work/build" --quiet
echo "built: $prefix"
