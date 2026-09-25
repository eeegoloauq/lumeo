# Shipping and CI

## Shipping: packages for Fedora, Arch and Windows, and the app owns its core

The deployment target is a person who wants to watch something, so the package
is one package: the client, the core, a desktop entry and an icon. The client
speaks HTTP to the core even on the same machine, and a desktop launcher is not
going to start a server for you, so the app starts it, as Stremio desktop and
Deluge's classic mode do:

- The app is one instance per session (GApplication). A second launch raises
  the window and hands it the file it was asked to open, over D-Bus, then
  exits. There is never a second window with a claim on the core.
- The first instance starts `lumeo-core` from beside its own binary as a child
  and holds its stdin. Nothing is written to it; the core
  (`LUMEO_EXIT_ON_STDIN_EOF=1`) stops when the pipe closes, and the kernel
  closes it however the app ends, `kill -9` included. Our end is
  close-on-exec, so nothing the app starts keeps it open.
- The instance gives up its name (the D-Bus name, the mutex on Windows) when
  its last window goes, not when the process exits: tearing down the engine
  and the player takes a while, and a launch in that time handed its file to
  a process past handling it and exited with nothing on screen.
- The core locks its data directory. The app reopened at once starts a core
  that waits for the one it just closed to finish its downloads instead of
  resuming them into the same files beside it; a core started by hand on a
  directory in use says so and exits. The client sends a request the core
  refused the connection for again, for as long as a request may take
  (`CoreClient`): the new core listens only once it has the lock, and a
  refused request never reached it, so any method is safe to repeat.
- `/usr/bin/lumeo` only execs the bundle.

The rejected design is a launcher script that starts a core when nothing
answers on the port: it reuses whatever answers, so after an update a window
talks to the previous release's core, closing the first of two windows takes
the core from the second, and `kill -9` of the script orphans the core.

A build without a core beside it (`flutter run`, the UI tests) starts none and
stays non-unique: it talks to whatever answers on its address, which is how a
dev core started by hand is reached, and it runs beside an installed copy
instead of handing itself over to it.

libmpv comes from the distribution (`Requires: mpv-libs`) rather than being
bundled: it is the one dependency where the distribution's build is better
than anything we would ship, and Fedora already has it. It is also the one
dependency worth naming by hand — the Dart side opens it with `dlopen`, and a
`dlopen` leaves nothing for rpm's dependency generator to find. (The bundled
plugin does link it too, so the soname dependency happens to appear anyway;
the explicit line is what keeps that true if the plugin changes.)

Arch gets a package on the release page too (`packaging/PKGBUILD`, built by
`build-arch.sh` in Arch's container). It is the same tarball laid out the Arch
way; an AUR entry would need the release files somewhere public to download
from. Makepkg has no dependency generator, so the PKGBUILD lists what the
bundle links, with `mpv` for libmpv. Arch's ffmpeg keeps the patented
decoders, so nothing there plays the part of `libavcodec-freeworld`. The icon
sizes are rendered once, in `build-dist.sh`, and the tarball carries them.

Every library in the bundle has `RUNPATH=$ORIGIN` from the build itself.
Flutter's template copies plugin libraries into the bundle as built, with the
absolute build-tree path to `flutter/ephemeral` that CMake gives a build
RUNPATH. `client/linux/CMakeLists.txt` builds them with their install RUNPATH,
so no package has to rewrite the copies with `patchelf`.

No systemd unit yet. It would only earn its place once "keep seeding with the
window closed" is a thing the product promises, and then as a *user* unit, not
a system one: the core opens outbound BitTorrent connections and a loopback
HTTP port, and neither wants root.

Flathub is not the near-term target even though a media app belongs there: its
rules forbid prebuilt binaries, so libmpv and ffmpeg would have to be built
from source as sandbox modules — sixty-odd of them, maintained forever, for a
project whose difference is the catalogue and the acquisition, not video
decoding. A self-hosted Flatpak remote stays possible and needs none of that.

Windows gets an installer (`packaging/lumeo.iss`, Inno Setup, built by
`build-windows.sh` on GitHub's Windows runner). It installs per user, without
administrator rights, into `%LOCALAPPDATA%\Programs\Lumeo`: the core needs
nothing the account does not have, as on Linux. MSIX was rejected because an
unsigned one cannot be installed at all, and a bare zip because it gives no
Start menu entry, no uninstaller and no "Open with". The installer is unsigned,
so SmartScreen asks once; a certificate is a cost to take on only if that
turns out to lose users.

The Windows runner (`client/windows/runner`) is the Linux one in Win32 terms,
so the Dart side does not know which it is on:

- The core is the app's child with a pipe on its stdin, which Windows closes
  however the app ends. Only the pipe and the log (`core.log` in
  `%LOCALAPPDATA%\Lumeo\State`) are inherited, through an explicit handle
  list.
- One instance: a named mutex instead of GApplication, and the file of a
  second launch goes over `WM_COPYDATA` instead of D-Bus.
- The client's own title bar, over the same `dev.lumeo/window` channel. The
  system caption was the simpler option (VLC and mpv keep it) and was
  rejected for the reason GTK's was: the artwork runs to the top edge. The
  borders, the shadow and snapping stay the system's; what is lost is the
  Snap Layouts flyout on the maximise button (Win+Z still opens it).
- `dev.lumeo/shell` answers what `xdg-open` and `xdg-user-dir` answer on
  Linux: ShellExecute, and the Pictures known folder, which OneDrive moves.

libmpv is the exception to "from the distribution": Windows has none, so it
is media_kit's own build, downloaded by its CMake at build time. That build is
from 2023-09, older than the libmpv of any Linux release, and the Windows half
of `media_kit_video` is upstream's: none of the patches in our fork apply to
it. The MSVC runtime goes into the bundle through CMake's
`InstallRequiredSystemLibraries`, because a clean Windows 10 does not have it.

## Where CI runs: Forgejo gates the core, the mirror builds the client

The split follows the machines. Pull requests live in Forgejo, and the core is
seconds of work there — `go vet`, gofmt, `go test -race`, a build — so that is
the pre-merge gate, in `.forgejo/workflows/ci.yml`, on our own image
(`packaging/ci/Containerfile`, built by `ci-image.yml`). Anything that needs a
Flutter SDK is ten-plus minutes on a runner that also builds every other
repository, so the client's checks and the release build run on GitHub against
the push mirror, in `.github/workflows/`. The path filter there means a commit
touching only the core, docs or packaging builds nothing on that side.

The rule is that a workflow file present in the tree is one that actually
runs; the comment at the top of each says which half it is.

- A release is a tag, and its notes are the annotated tag's message: the
  workflow reads `git tag -l --format='%(contents)'` and publishes it with the
  tarball and the RPM. A tag with no annotation publishes an empty page, so
  there is nothing to write afterwards that is not written on the tag.
- A tag pushed in the same push as its branch does not always start the
  workflow on the mirror, which is why `release.yml` also takes
  `workflow_dispatch`: the release can be run by hand against a tag that is
  already there.
- The Flutter SDK is pinned by `subosito/flutter-action`'s version input rather
  than baked into an image: a release built by CI and one built by hand have
  to come out of the same toolchain, and the version lives in one line of the
  workflow.
- A release builds without caches; `ci.yml` on main keeps them. A cache saved
  by a tag run is readable by that tag alone, so the release runs saved 2.4 GB
  on Windows every time (six of its fourteen minutes) for no later run to read.
  A cache is also state from another run going into a published artifact,
  which zizmor's `cache-poisoning` audit flags. Warming them on main instead
  would mean a Windows build on every commit to save two minutes per release.
