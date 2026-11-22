#!/usr/bin/env bash
# The generated WinRT headers newer than Qt's MinGW-w64 11 SDK. Keep them
# private to the SMTC source file so that the rest of the client uses Qt's SDK.
set -euo pipefail

package=mingw-w64-x86_64-headers-git-13.0.0.r1.gb45abfec4-1-any.pkg.tar.zst
sha256=0776c28555d5a36bf5641d7fd0f7aeb5e762d14a9803df9b22d7c9d6b3482d52
dir=${1:-dist/winrt}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/$package" "https://repo.msys2.org/mingw/mingw64/$package"
echo "$sha256  $work/$package" | sha256sum -c

headers=(
  windows.media.h
  windows.foundation.h
  windows.foundation.collections.h
  windows.storage.h
  windows.storage.fileproperties.h
  windows.devices.geolocation.h
  windows.storage.streams.h
  windows.storage.search.h
  windows.system.h
)
paths=()
for header in "${headers[@]}"; do
  paths+=("mingw64/include/$header")
done
(cd "$work" && cmake -E tar xf "$package" -- "${paths[@]}")
mkdir -p "$dir"
cp "$work/mingw64/include/"*.h "$dir/"
