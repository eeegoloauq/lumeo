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
# four lines and one run of that workflow; the commit is the one in the
# file's name, in full.
mpv_date=20261021
mpv_file=mpv-dev-x86_64-20261021-git-e471496c56.7z
mpv_sha256=efc719eff3dc5954b4a5efc800632808bcec01cc9034940dd14e5eb7fe9ea633
mpv_commit=e471496c56f0f49c133bd88b50aed62b845f1909

# yt-dlp, which mpv runs for a trailer, and Deno, the JavaScript runtime it
# needs for YouTube, found beside it. yt-dlp then updates itself
# (MpvFacts::updateYtdl); 2026.10.21 is the first whose update cannot be
# tampered with on the way. Digests from each release's own sums.
ytdlp_version=2026.10.21
ytdlp_sha256=33121d192d706e62f684a06f80918e3f3a8ba52ac3a65213b6951c39c7d9f555
deno_version=2.9.7
deno_sha256=a0c3101b4158d1dfb7d6a78a7bf0f3de80c96bb423c152beec8beb22786f2238

rm -rf dist
mkdir -p dist/mpv dist/deno

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

echo "==> yt-dlp and deno"
curl -fsSL -o "$bundle/bin/yt-dlp.exe" \
  "https://github.com/yt-dlp/yt-dlp/releases/download/$ytdlp_version/yt-dlp.exe"
echo "$ytdlp_sha256  $bundle/bin/yt-dlp.exe" | sha256sum -c
curl -fsSL -o dist/deno.zip \
  "https://github.com/denoland/deno/releases/download/v$deno_version/deno-x86_64-pc-windows-msvc.zip"
echo "$deno_sha256  dist/deno.zip" | sha256sum -c
7z x -bd -o"dist/deno" dist/deno.zip >/dev/null
cp dist/deno/deno.exe "$bundle/bin/"

# What the licences of the programs the bundle carries ask to go with them.
# libmpv is GPLv2+: its notice, the licence texts and where its source is.
echo "==> licences"
mkdir -p "$bundle/licenses/mpv" "$bundle/licenses/deno"
for file in Copyright LICENSE.GPL LICENSE.LGPL; do
  curl -fsSL -o "$bundle/licenses/mpv/$file" \
    "https://raw.githubusercontent.com/mpv-player/mpv/$mpv_commit/$file"
done
cat > "$bundle/licenses/mpv/SOURCE.txt" <<SOURCE
bin/libmpv-2.dll is mpv, licensed under the GPL version 2 or later (see
Copyright and LICENSE.GPL here), built from
https://github.com/mpv-player/mpv/tree/$mpv_commit
by https://github.com/shinchiro/mpv-winbuild-cmake, whose recipe names every
library built into it and where its source is. The build is $mpv_file.
SOURCE
curl -fsSL -o "$bundle/licenses/deno/LICENSE.md" \
  "https://raw.githubusercontent.com/denoland/deno/v$deno_version/LICENSE.md"

echo "==> installer"
# Git Bash would take /DVersion for a path and rewrite it.
MSYS_NO_PATHCONV=1 iscc "/DVersion=$version" "/DFileVersion=${version%%-*}" packaging/lumeo.iss
echo "==> dist/lumeo-$version-windows-x86_64-setup.exe"
