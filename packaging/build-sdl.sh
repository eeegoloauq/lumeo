#!/usr/bin/env bash
# SDL3 for the gamepad on Linux: built from its pinned source as a static
# library, with only the joystick and gamepad parts, into $1 (by default
# ~/.cache/lumeo/sdl-<version>). Prints that directory, for CMAKE_PREFIX_PATH.
#
#     packaging/build-sdl.sh [prefix]
#
# Ubuntu 24.04, which CI and the release build on, has no SDL3 package, and
# linked in, the bundle asks for none on the systems it runs on. Where the
# system has SDL3 (Fedora, Arch, newer Debian and Ubuntu) a build of your own
# can use that instead. A bump is the version and the digests here and in
# fetch-sdl.sh, from the release page, and an OSV query for its commit.
set -euo pipefail

version=3.4.18
sha256=9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3
prefix=${1:-${XDG_CACHE_HOME:-$HOME/.cache}/lumeo/sdl-$version}

if [[ -e $prefix/lib/libSDL3.a ]]; then
  echo "$prefix"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/lumeo-sdl.XXXXXX")
trap 'rm -rf "$work"' EXIT

# On the dev box the network goes through `p`; elsewhere curl runs as is.
fetch=(curl -fsSL)
if command -v p >/dev/null; then fetch=(p "${fetch[@]}"); fi
"${fetch[@]}" -o "$work/sdl.tar.gz" \
  "https://github.com/libsdl-org/SDL/releases/download/release-$version/SDL3-$version.tar.gz"
echo "$sha256  $work/sdl.tar.gz" | sha256sum -c --quiet
tar -xzf "$work/sdl.tar.gz" -C "$work"

# The rest of SDL stays out: Qt has the window, the sound is mpv's. udev,
# when its headers are there, is opened at run time and finds a controller
# plugged in later; without it SDL watches /dev/input itself.
{
  cmake -S "$work/SDL3-$version" -B "$work/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_TEST_LIBRARY=OFF -DSDL_EXAMPLES=OFF \
    -DSDL_AUDIO=OFF -DSDL_VIDEO=OFF -DSDL_GPU=OFF -DSDL_RENDER=OFF -DSDL_CAMERA=OFF \
    -DSDL_DIALOG=OFF -DSDL_TRAY=OFF -DSDL_POWER=OFF -DSDL_HAPTIC=OFF \
    -DSDL_JOYSTICK=ON -DSDL_HIDAPI=ON -DSDL_UNIX_CONSOLE_BUILD=ON
  cmake --build "$work/build"
  cmake --install "$work/build"
} >&2
echo "$prefix"
