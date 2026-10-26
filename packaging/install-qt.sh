#!/usr/bin/env bash
# Installs the Qt the client is built and tested with, the same in CI and by
# hand: 6.12.0 with the modules desktop/ needs, under $1 (default
# ~/.cache/lumeo/qt), and on Windows the MinGW and Ninja that build with it.
# Prints the Qt directory, for CMAKE_PREFIX_PATH.
#
# aqtinstall is pinned to a commit: its last release (3.3.0) cannot read
# Qt's repository for Windows from 6.11 on, which its master can.
set -euo pipefail

qt=6.12.0
aqt="aqtinstall @ git+https://github.com/miurahr/aqtinstall@076e1659807d0b362a3ed684d54c2e9c775eb9c7"
dir=${1:-$HOME/.cache/lumeo/qt}

case "$(uname -s)" in
  Linux) host=linux arch=linux_gcc_64 prefix=gcc_64 ;;
  MINGW* | MSYS*) host=windows arch=win64_mingw prefix=mingw_64 ;;
  *) echo "install-qt: no Qt build for $(uname -s)" >&2; exit 1 ;;
esac

# Windows names it python; its python3 can be the Store's placeholder.
python=python3
[ "$host" = windows ] && python=python
"$python" -m venv "$dir/aqt" >&2
bin=$dir/aqt/bin
[ -d "$dir/aqt/Scripts" ] && bin=$dir/aqt/Scripts
"$bin/python" -m pip install -q "$aqt" >&2

"$bin/aqt" install-qt "$host" desktop "$qt" "$arch" --outputdir "$dir" \
  -m qtimageformats qtshadertools qthttpserver qtwebsockets >&2
if [ "$host" = windows ]; then
  "$bin/aqt" install-tool windows desktop tools_mingw1310 qt.tools.win64_mingw1310 --outputdir "$dir" >&2
  "$bin/aqt" install-tool windows desktop tools_ninja qt.tools.ninja --outputdir "$dir" >&2
fi
echo "$dir/$qt/$prefix"
