#!/usr/bin/env bash
# Packages the tarball from build-dist.sh as an RPM. Build it on Fedora (or in
# a Fedora container, which is what the release workflow does): the spec asks
# for that distribution's own validation tools by their Fedora names.
set -euo pipefail

cd "$(dirname "$0")/.."
version=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)}
tarball="dist/lumeo-$version-linux-x86_64.tar.gz"

[ -f "$tarball" ] || packaging/build-dist.sh "$version"

elsewhere=()
if ! grep -qi 'fedora\|rhel\|centos' /etc/os-release; then
  # %check validates the desktop file and the AppStream metadata with tools
  # that only exist under those names on Fedora. The package comes out the
  # same; what is skipped is that validation, which CI does in a container.
  echo "not a Fedora machine: skipping the BuildRequires check and %check" >&2
  elsewhere=(--nodeps --nocheck)
fi

topdir=$PWD/dist/rpmbuild
mkdir -p "$topdir"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
cp "$tarball" "$topdir/SOURCES/"
rpmbuild "${elsewhere[@]}" --define "_topdir $topdir" --define "version $version" \
         -bb packaging/lumeo.spec
find "$topdir/RPMS" -name '*.rpm'
