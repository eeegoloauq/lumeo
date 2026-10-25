#!/usr/bin/env bash
# Assembles the share site into one directory, as GitHub Pages serves it:
#
#     site/build.sh _site
#
# A link is /movie/?<imdb id>-<words> or /series/?..., so title.html is served
# under both folders; the wordmark's font and the icon are the app's own.
set -euo pipefail

out=${1:?usage: site/build.sh <out dir>}
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

rm -rf "$out"
mkdir -p "$out/movie" "$out/series" "$out/fonts"
cp "$repo/site/index.html" "$out/"
cp "$repo/packaging/icon.svg" "$out/"
cp "$repo/site/title.html" "$out/movie/index.html"
cp "$repo/site/title.html" "$out/series/index.html"
cp "$repo/client/assets/fonts/Unbounded.ttf" "$out/fonts/"
