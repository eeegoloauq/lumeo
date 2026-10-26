#!/usr/bin/env bash
# Builds what a release is made of: the Go core, the Qt client's bundle, and
# the tarball that carries both plus the desktop files and icons. Everything
# downstream — the RPM, the Arch package, the plain tarball on the release
# page — starts here, so a package built by hand and one built by CI come
# from the same commands.
set -euo pipefail

cd "$(dirname "$0")/.."
version=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}
stage="dist/lumeo-$version-linux-x86_64"

rm -rf dist
mkdir -p "$stage"

# The client with the Qt it was built and tested with, from the Qt that
# CMAKE_PREFIX_PATH (or PATH) names: bin/, lib/, plugins/, qml/
# (desktop/CMakeLists.txt, install).
echo "==> client"
cmake -S desktop --preset release -DLUMEO_VERSION="$version"
cmake --build desktop/build/release
cmake --install desktop/build/release --prefix "$stage/bundle"

# Beside the binary: that is where the app looks for the core it starts
# (desktop/src/platform/instance.cpp).
echo "==> core"
(cd core && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=$version" -o "../$stage/bundle/bin/lumeo-core" ./cmd/lumeo)

# The icons every package installs as they are. 16 and 24 are in the list
# because desktops still use them — window lists and menus — and a desktop
# that has to shrink the 32 for those gets a rougher icon than one it was
# handed. Those three come from icon-small.svg, whose outline is thick enough
# to survive at that size.
for size in 16 24 32 48 64 128 256 512; do
  src=packaging/icon.svg
  [ $size -le 32 ] && src=packaging/icon-small.svg
  mkdir -p "$stage/icons/hicolor/${size}x${size}/apps"
  rsvg-convert -w $size -h $size $src \
    -o "$stage/icons/hicolor/${size}x${size}/apps/dev.lumeo.lumeo.png"
done
mkdir -p "$stage/icons/hicolor/scalable/apps"
cp packaging/icon.svg "$stage/icons/hicolor/scalable/apps/dev.lumeo.lumeo.svg"

cp packaging/lumeo.sh packaging/dev.lumeo.lumeo.desktop \
   client/assets/dev.lumeo.lumeo.metainfo.xml "$stage/"
cp LICENSE README.md "$stage/"

tar czf "dist/lumeo-$version-linux-x86_64.tar.gz" -C dist "lumeo-$version-linux-x86_64"
echo "==> dist/lumeo-$version-linux-x86_64.tar.gz"
