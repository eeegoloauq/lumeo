#!/usr/bin/env bash
# The Windows release: the Qt client's bundle with the Go core and libmpv
# beside it, and the installer that carries them (lumeo.iss). Runs in Git
# Bash with the Qt of install-qt.sh, its MinGW and Ninja on PATH, and ISCC
# (Inno Setup 6). The same commands by hand and in release.yml.
set -euo pipefail

cd "$(dirname "$0")/.."
version=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}
bundle=dist/bundle

# libmpv: shinchiro's build, mirrored into this repository by libmpv.yml and
# checked against the digest its own release page lists. A bump is these
# three lines and one run of that workflow.
mpv_date=20261021
mpv_file=mpv-dev-x86_64-20261021-git-e471496c56.7z
mpv_sha256=efc719eff3dc5954b4a5efc800632808bcec01cc9034940dd14e5eb7fe9ea633

rm -rf dist
mkdir -p dist/mpv

echo "==> libmpv"
curl -fsSL -o "dist/$mpv_file" \
  "https://github.com/eeegoloauq/lumeo/releases/download/deps-libmpv-$mpv_date/$mpv_file"
echo "$mpv_sha256  dist/$mpv_file" | sha256sum -c
7z x -bd -o"dist/mpv" "dist/$mpv_file" >/dev/null

echo "==> client"
cmake -S desktop -B desktop/build/windows -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
  -DLUMEO_VERSION="$version" -DMPV_DIR="$PWD/dist/mpv"
cmake --build desktop/build/windows
cmake --install desktop/build/windows --prefix "$bundle"

# Beside lumeo.exe: that is where the app looks for the core it starts
# (desktop/src/platform/instance.cpp).
echo "==> core"
(cd core && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath \
  -ldflags "-s -w -X main.version=$version" -o "../$bundle/bin/lumeo-core.exe" ./cmd/lumeo)

echo "==> installer"
# Git Bash would take /DVersion for a path and rewrite it.
MSYS_NO_PATHCONV=1 iscc "/DVersion=$version" "/DFileVersion=${version%%-*}" packaging/lumeo.iss
echo "==> dist/lumeo-$version-windows-x86_64-setup.exe"
