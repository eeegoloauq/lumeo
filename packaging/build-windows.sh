#!/usr/bin/env bash
# The Windows release: the Flutter bundle with the Go core beside it, and the
# installer that carries both (lumeo.iss). Runs in Git Bash, which is what a
# Windows machine with Flutter on it already has; ISCC (Inno Setup 6) has to
# be on PATH. The same commands by hand and in release.yml.
set -euo pipefail

cd "$(dirname "$0")/.."
version=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}
bundle=client/build/windows/x64/runner/Release

rm -rf dist
mkdir -p dist

echo "==> client"
(cd client && flutter build windows --release --build-name="$version")

# Into the bundle, beside lumeo.exe: that is where the app looks for the core
# it starts (client/windows/runner/main.cpp).
echo "==> core"
(cd core && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath \
  -ldflags "-s -w -X main.version=$version" -o "../$bundle/lumeo-core.exe" ./cmd/lumeo)

echo "==> installer"
# Git Bash would take /DVersion for a path and rewrite it.
MSYS_NO_PATHCONV=1 iscc "/DVersion=$version" packaging/lumeo.iss
echo "==> dist/lumeo-$version-windows-x86_64-setup.exe"
