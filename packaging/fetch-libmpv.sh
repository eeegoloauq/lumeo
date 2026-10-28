#!/usr/bin/env bash
# The Windows libmpv, unpacked into $1 with its licences under $1/licenses:
# what build-windows.sh bundles and ci.yml's Windows tests link against.
#
#     packaging/fetch-libmpv.sh dist/mpv
#
# shinchiro's build, mirrored into this repository by libmpv.yml and checked
# against the digest its own release page lists. A bump is these four lines
# and one run of that workflow; the commit is the one in the file's name, in
# full.
set -euo pipefail

mpv_date=20261021
mpv_file=mpv-dev-x86_64-20261021-git-e471496c56.7z
mpv_sha256=efc719eff3dc5954b4a5efc800632808bcec01cc9034940dd14e5eb7fe9ea633
mpv_commit=e471496c56f0f49c133bd88b50aed62b845f1909

dir=$1
mkdir -p "$dir/licenses"
archive=$(mktemp -d)/$mpv_file
curl -fsSL -o "$archive" \
  "https://github.com/eeegoloauq/lumeo/releases/download/deps-libmpv-$mpv_date/$mpv_file"
echo "$mpv_sha256  $archive" | sha256sum -c
7z x -bd -o"$dir" "$archive" >/dev/null
rm -rf "$(dirname "$archive")"

for file in Copyright LICENSE.GPL LICENSE.LGPL; do
  curl -fsSL -o "$dir/licenses/$file" \
    "https://raw.githubusercontent.com/mpv-player/mpv/$mpv_commit/$file"
done
cat > "$dir/licenses/SOURCE.txt" <<SOURCE
bin/libmpv-2.dll is mpv, licensed under the GPL version 2 or later (see
Copyright and LICENSE.GPL here), built from
https://github.com/mpv-player/mpv/tree/$mpv_commit
by https://github.com/shinchiro/mpv-winbuild-cmake, whose recipe names every
library built into it and where its source is. The build is $mpv_file.
SOURCE
