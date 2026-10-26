# Shipping and CI

## Shipping: packages for Fedora, Arch and Windows, and the app owns its core

The deployment target is a person who wants to watch something, so the package
is one package: the client, the core, a desktop entry and an icon. The client
speaks HTTP to the core even on the same machine, and a desktop launcher is not
going to start a server for you, so the app starts it:

- The app is one instance per session: the first listens on a local socket
  (`QLocalServer`, a Unix socket in the session's runtime directory or a
  named pipe on Windows), and a second launch raises the window and hands it
  the file or link it was asked to open, with the desktop's activation token
  so Wayland lets the window come forward, then exits. There is never a
  second window with a claim on the core.
- The first instance starts `lumeo-core` from beside its own binary as a child
  (`QProcess`, never deleted: destroying one kills its child) and holds its
  stdin. Nothing is written to it; the core
  (`LUMEO_EXIT_ON_STDIN_EOF=1`) stops when the pipe closes, and the kernel
  closes it however the app ends, `kill -9` included. Our end is
  close-on-exec, so nothing the app starts keeps it open.
- The instance gives up its name when the app decides to end, not when the
  process exits: tearing down the engine
  and the player takes a while, and a launch in that time handed its file to
  a process past handling it and exited with nothing on screen.
- The core locks its data directory. The app reopened at once starts a core
  that waits for the one it just closed to finish its downloads instead of
  resuming them into the same files beside it; a core started by hand on a
  directory in use says so and exits. The client sends a request the core
  refused the connection for again, for as long as a request may take
  (`CoreClient`): the new core listens only once it has the lock, and a
  refused request never reached it, so any method is safe to repeat.
- A launch that finds the running instance's binary replaced on disk, a
  package upgraded under an app kept in the background, closes that instance
  and starts the new version, which is what the person launching asked for.
- `/usr/bin/lumeo` only execs the bundle.

The rejected design is a launcher script that starts a core when nothing
answers on the port: it reuses whatever answers, so after an update a window
talks to the previous release's core, closing the first of two windows takes
the core from the second, and `kill -9` of the script orphans the core.

A build without a core beside it (a development build, the tests) starts none
and stays non-unique: it talks to whatever answers on its address, which is how a
dev core started by hand is reached, and it runs beside an installed copy
instead of handing itself over to it.

The bundle carries the Qt it was built and tested with: `bin/lumeo`, Qt's
libraries, ICU, plugins and QML modules under `lib/`, `plugins/` and `qml/`
(Qt's own deploy script, `desktop/CMakeLists.txt`), with `RUNPATH=$ORIGIN/../lib`.
The distribution's Qt was the alternative: a smaller package, but an rpm built
against Fedora 44's Qt is not one Fedora 45's runs, a rolling Arch moves Qt
under a binary between our releases, and Ubuntu's Qt is too old for the
tarball at all. The cost is that Qt's fixes reach people with our releases. The deploy leaves out
the system's libraries, the QML debugger, the plugins for devices with no
desktop and the GTK theme, which would pull GTK in where the portal's theme
serves. About 30 MB compressed.

libmpv comes from the distribution rather than being bundled: it is the one
dependency where the distribution's build is better than anything we would
ship, and on Fedora it is the one that RPM Fusion's codecs reach. The RPM's
dependency generator finds it and every other system library the bundle
links; Qt and ICU are kept out of what the package provides and requires.

Arch gets a package on the release page too (`packaging/PKGBUILD`, built by
`build-arch.sh` in Arch's container). It is the same tarball laid out the Arch
way; an AUR entry would need the release files somewhere public to download
from. Makepkg has no dependency generator, so the PKGBUILD lists what the
bundle links outside itself, with `mpv` for libmpv. Arch's ffmpeg keeps the
patented decoders, so nothing there plays the part of `libavcodec-freeworld`.
The icon sizes are rendered once, in `build-dist.sh`, and the tarball carries
them.

No systemd unit. Starting at login is the desktop's autostart entry for the
app itself (interface.md), which keeps the one rule that the app owns its
core: a separate service would be a second owner, and the core opens outbound
BitTorrent connections and a loopback HTTP port, neither of which wants root.

Flathub is not the near-term target even though a media app belongs there: its
rules forbid prebuilt binaries, so libmpv and ffmpeg would have to be built
from source as sandbox modules — sixty-odd of them, maintained forever, for a
project whose difference is the catalogue and the acquisition, not video
decoding. A self-hosted Flatpak remote stays possible and needs none of that.

Windows gets an installer (`packaging/lumeo.iss`, Inno Setup, built by
`build-windows.sh` on GitHub's Windows runner, with Qt's MinGW build). It installs per user, without
administrator rights, into `%LOCALAPPDATA%\Programs\Lumeo`: the core needs
nothing the account does not have, as on Linux. MSIX was rejected because an
unsigned one cannot be installed at all, and a bare zip because it gives no
Start menu entry, no uninstaller and no "Open with". The installer is unsigned,
so SmartScreen asks once; a certificate is a cost to take on only if that
turns out to lose users.

On Windows the same code does the same things in Win32's terms, through
Qt: the core is a child with a pipe on its stdin, detached so it gets no
console, logging to `core.log` in `%LOCALAPPDATA%\Lumeo\State`; the instance
listens on a named pipe; the window has the system's title bar; the Pictures
folder is `QStandardPaths`'s, which follows OneDrive. Qt's deploy (windeployqt)
lays Qt and the compiler's runtime out beside the binary.

libmpv is the exception to "from the distribution": Windows has none, and mpv
publishes no libmpv to build against (its own Windows builds are the player
alone, or a rolling CI build meant for testing). The bundle carries
shinchiro's `mpv-winbuild-cmake` build, the one mpv's installation page names
first for Windows: one static `libmpv-2.dll` with ffmpeg inside. That
repository keeps about a month of daily builds, so the pinned one is mirrored
into a release of ours by `.github/workflows/libmpv.yml` and checked against
its digest at every build; a bump is the date, the file and the digest in
`build-windows.sh` and one run of that workflow.

## Updates: the app says a release is out, the system installs it

The core asks GitHub for the latest published release when the client starts,
at most once a day (a failed look again after an hour), and the client shows
it in the corner card that shows what an update brought: the notes of every
release since the running one, from the release's own AppStream file, so they
come in the interface language, and a button to the release page. Closing it
keeps that version quiet; the next one is offered again. Settings, About turns
the check off, and then the core never contacts GitHub. The core asks, not
the client, because every call leaving the machine is the core's.

Nothing installs itself. An rpm or a pacman package is the package manager's
to replace, and an app rewriting its own root-owned files is the wrong owner;
the way to updates that arrive by themselves on Linux is a repository the
system already polls (the roadmap's Copr and Flatpak remote). On Windows it
would be a signed installer run silently, which waits on signing.

## Where CI runs: Forgejo gates the core, the mirror builds the client

The split follows the machines. Pull requests live in Forgejo, and the core is
seconds of work there — `go vet`, gofmt, `go test -race`, a build — so that is
the pre-merge gate, in `.forgejo/workflows/ci.yml`, on our own image
(`packaging/ci/Containerfile`, built by `ci-image.yml`). Anything that needs Qt,
Weston and a Fedora container is ten-plus minutes on a runner that also builds
every other repository, so the client's checks and the release build run on GitHub against
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
- Qt is pinned in `packaging/install-qt.sh` rather than baked into an image:
  a release built by CI and one built by hand come out of the same Qt, and the
  version lives in one line of one script. aqtinstall is pinned to a commit of
  its master, whose last release cannot read Qt's repository for Windows
  from 6.11 on.
- A release builds without caches; `ci.yml` on main keeps them. A cache saved
  by a tag run is readable by that tag alone, so the release runs saved gigabytes
  every time for no later run to read.
  A cache is also state from another run going into a published artifact,
  which zizmor's `cache-poisoning` audit flags. Warming them on main instead
  would mean a Windows build on every commit to save two minutes per release.
