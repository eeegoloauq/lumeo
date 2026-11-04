#!/usr/bin/env bash
# The Windows SDL3, unpacked into $1 (bin/SDL3.dll, include/, lib/cmake/SDL3)
# with its licence under $1/licenses: what build-windows.sh bundles and
# ci.yml's Windows tests link against, for the gamepad.
#
#     packaging/fetch-sdl.sh dist/sdl
#
# SDL's own MinGW build, checked against the digest its release page lists.
# A bump is the version and digest here and in build-sdl.sh.
set -euo pipefail

version=3.4.18
sha256=049b9dd711e3fb3f8d84feb998dfec54a75e17cf539c4a80ff4d058d839771cf

dir=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/sdl.tar.gz" \
  "https://github.com/libsdl-org/SDL/releases/download/release-$version/SDL3-devel-$version-mingw.tar.gz"
echo "$sha256  $work/sdl.tar.gz" | sha256sum -c
tar -xzf "$work/sdl.tar.gz" -C "$work"

mkdir -p "$dir/licenses"
cp -r "$work/SDL3-$version/x86_64-w64-mingw32/." "$dir/"
cp "$work/SDL3-$version/LICENSE.txt" "$dir/licenses/LICENSE.txt"
