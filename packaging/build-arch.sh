#!/usr/bin/env bash
# Packages the tarball from build-dist.sh for Arch Linux. Run it on Arch (the
# release workflow uses Arch's container) as an ordinary user: makepkg refuses
# to run as root.
set -euo pipefail

cd "$(dirname "$0")/.."
version=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}
tarball="dist/lumeo-$version-linux-x86_64.tar.gz"

[ -f "$tarball" ] || packaging/build-dist.sh "$version"

work=dist/archbuild
rm -rf "$work"
mkdir -p "$work"
cp "$tarball" "$work/"
sed "s/^pkgver=.*/pkgver=$version/" packaging/PKGBUILD > "$work/PKGBUILD"
cd "$work"
sums=$(makepkg --geninteg)
echo "$sums" >> PKGBUILD
# The runtime dependencies are not needed to lay files out, and a build
# container does not have them.
makepkg --nodeps
mv ./*.pkg.tar.zst ..
ls ../*.pkg.tar.zst
