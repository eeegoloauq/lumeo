#!/usr/bin/bash
# What /usr/bin/lumeo is. The app starts its own core (lumeo-core, beside it in
# the bundle) and is one instance, so all this does is find the bundle:
# /usr/lib64/lumeo from the RPM, /usr/lib/lumeo from the Arch package, or
# bundle/ beside this script in the tarball.
here=$(dirname "$(readlink -f "$0")")
for dir in "$here/../lib64/lumeo" "$here/../lib/lumeo" "$here/bundle"; do
  if [ -x "$dir/lumeo" ]; then
    exec "$dir/lumeo" "$@"
  fi
done
echo "lumeo: no application bundle found from $here" >&2
exit 1
