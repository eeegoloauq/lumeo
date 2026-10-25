# Moving the desktop client to Qt Quick

Why is in [decisions/foundations.md](decisions/foundations.md). This file is
the plan and the inventory the new client is written against; it is deleted
with `client/`, once `desktop/` has replaced it.

The new client is written from this inventory and the decisions, not by
translating Dart line by line. Behaviour that is in neither is read in the
Dart file named beside it, and whatever turns out to be in no list here is
left behind on purpose or added to it.

## Order

Each step ends with the checks of the steps before it still passing.

1. **Prototype, the gate.** `desktop/` with a window, the core's token, one
   title's sources, and a download played through libmpv in Qt Quick with a
   bar over the picture. Checked on the NVIDIA/Wayland machine: 4K HEVC on
   nvdec, scrubbing, an hour's pause, Anime4K's colours, fullscreen and the
   system's title bar on GNOME, and Russian typed into a text field without
   lag. Built for Windows with our own libmpv, where mpv's console
   and statistics open. If the picture fails here, the decision is reopened.
2. **Foundation.** The API client, the stores, the translations, the theme,
   the shell with its bar, and the test layers with a first test in each.
3. **Screens**, each with its tests: home, title page (Play, the sources
   drawer, the release menu, the season strip), the player, search, the
   library, settings, the downloads panel.
4. **The machine.** Background and tray, starting at login, one instance with
   "Open with" and `lumeo://` links, the update card and release notes.
5. **Packages and CI.** Fedora, Arch and the Windows installer from
   `desktop/`, the release workflow and the client checks on the mirror.
6. **Switch.** Walk this inventory against the new client, then delete
   `client/`, `desktop/tool/arb2ts.py` and this file, and rewrite what describes the client:
   `CLAUDE.md`, `CONTRIBUTING.md`, `architecture.md`, `decisions/testing.md`,
   `decisions/video-output.md`, `decisions/shipping.md`.

The Flutter client takes fixes meanwhile, no features.

## Layout

    desktop/
      CMakeLists.txt     C++20, Qt 6.12 (Quick, QuickControls2, Network;
                         DBus on Linux), libmpv
      src/api/           the core over HTTP, the token, the stores
      src/player/        the mpv item, the headless mpv, the frame grabber
      src/platform/      the window, one instance, tray, folders, settings
      qml/               screens, widgets, the theme as a singleton
      tests/             QtTest units, Qt Quick Test app tests, player tests

State lives in C++ objects (`QML_ELEMENT`, properties with `NOTIFY`), and QML
binds to it: no request logic in QML, no layout in C++.

mpv renders through its render API into a framebuffer object on Qt Quick's
render thread, with Qt's graphics API set to OpenGL
(`QQuickWindow::setGraphicsApi`). Either `QQuickFramebufferObject` of our
own, which is what mpv's own Qt example does, or KDE's `mpvqt` over the same,
if Fedora and Arch package it and it builds on Windows; the prototype
decides. Properties are observed on mpv's event loop; nothing on the GUI
thread waits on mpv, for the reason the Flutter client learned on GTK's.

## How it is built and looked at

The window has the system's title bar (decided 2026-10-25): KDE draws it,
Windows draws it, and on GNOME, which leaves decorations to the client, Qt's
Wayland decorations do. The bar under it keeps the wordmark, Back, the tabs,
search and the downloads ring, without the window buttons and drag areas;
that bar gets a mockup before code. The artwork no longer runs to the top
edge, which was the reason for our own.

A build is meant to be fast enough not to wait for: Ninja, ccache and mold,
QML read from the source tree in a development build so a QML edit needs no
rebuild, and Qt 6.12's QML hot reload where it works outside Qt Creator. It
builds on the server, where the tests run, and on the desktop, against the
system's Qt where it is new enough, to be looked at.

The look is checked against the Flutter client, not redrawn as mockups: one
screenshot per screen and state from `client/tool/dev.sh shot`, kept outside
git (they are full of posters), with the rules in decisions/interface.md.
Only what changes on purpose gets a mockup.

Colours, radii, type sizes and fonts are written once, in a tokens file that
both the QML theme and the share site read when they are built; today
`site/title.html` copies the client's colours by hand.

## What carries over unchanged

- The core and its API, the fixtures in `client/test/fixtures/core/` and the
  Go test that checks them (they move to `desktop/tests/`).
- Every rule in `docs/decisions/`, except the ones listed below as Flutter's.
- The interface's text: `desktop/i18n/lumeo_<code>.ts`, converted once from
  `app_<code>.arb` by `desktop/tool/arb2ts.py` and the source since; a string
  fixed in the Flutter client meanwhile is fixed in both. Ids are the arb
  keys, for `qsTrId`; placeholders are `%1`, `%2` in the English order and
  each message's comment names them; plurals are `%n`. Qt has no zero form
  and one `%n` a message, so `=0` became `<key>Zero` and a second plural
  `<key>_<variable>`, passed in as an argument. Weblate takes `.ts` as well.
- The fonts, the icon, the AppStream file, the Anime4K shaders. The scrim
  shader is rewritten for `qsb`. The icon font is Material's, which Flutter
  ships inside its SDK: it goes into `desktop/` (Apache 2.0).
- `client.json` and the folders the client writes to (`dirs.dart`): the same
  paths and keys, so an update keeps this machine's settings and the frames
  already taken.

## What goes, being Flutter's

- media_kit and the media_kit_video fork in `client/third_party/`.
- The second libmpv client (`mpv_host.dart`): we hold mpv's handle and read
  its events ourselves.
- Undoing media_kit's defaults (the `fast` profile, a 32 MiB cache, a 5 s
  network timeout, libass off, `hwdec=auto`): mpv starts with its own, and
  only what a decision names is set on top.
- The Impeller and Skia section of video-output.md, the `mediump` bug if the
  prototype shows it gone, the icon-subset note.
- Workarounds of Flutter's widgets: the wheel on horizontal rows (check what
  a horizontal ListView does with a wheel before writing anything), the
  double-tap arena (TapHandler), `MenuAnchor` positioning, the shell's own
  navigation stack (a StackView under the bar that floats over it), the
  window notifier that defers to the end of a frame.
- The Linux and Windows runners, 2,000 lines of C++, replaced by the next
  list.

## What Qt has that we drew ourselves

- Folder chooser (`folder_dialog.dart`): `FolderDialog`, the portal on
  Linux and `IFileDialog` on Windows. Still offered only for a core on this
  machine.
- One instance, and a later launch handing over its file or link:
  `QLocalServer`, one implementation for both systems instead of
  GApplication over D-Bus and a mutex with `WM_COPYDATA`.
- Tray: `QSystemTrayIcon` (StatusNotifierItem on Linux). Stock GNOME has no
  tray and keeps the notification, over D-Bus.
- The window: the system's title bar, `showFullScreen`.
- Links and folders: `QDesktopServices`. The Pictures folder:
  `QStandardPaths`, no `xdg-user-dir` and no Windows shell call.
- HTTP: `QNetworkAccessManager`. AppStream: `QXmlStreamReader`.

## Simplifications

- One mpv with no file, started once, answers the decoder list, its default
  bindings and its version; `decoders.dart` and `mpv_facts.dart` each start
  one now.
- One frame grabber for the seek bar's previews and the episode frames
  (`thumbnails.dart`, `frame_grabber.dart`).

## Inventory

The behaviour to carry, by area, and where its rules are written.

**The core.** Token from the data directory, sent only to the default
address, read again after a 401 with one retry (`core_token.dart`). A refused
connection is sent again for as long as a request may take
(`core_client.dart`, decisions/shipping.md). A core that stops answering is
an error after 20 s, not a spinner. A download this client starts is in the
list from the start's answer (`client.dart`). Downloads are polled, fast
while something moves (`downloads_store.dart`). Preference writes go one
after another, a burst of one key is one patch, and Reset drops what was
waiting (`preferences_store.dart`). The addon list on screen is what the core
returned (`addons_store.dart`). Artwork retries a 5xx after 2, 6 and 20 s, a
4xx is final, and a banner is decoded at the size it is drawn
(`artwork_image.dart`, `artwork_scrim.dart`). Language names and ranks
(`languages.dart`).

**Shell and bar.** decisions/interface.md: Back is an arrow before the
wordmark, a tab is lit only on its own page, the bar's
ground arrives as the page scrolls. The keyboard always has somewhere to be,
and Ctrl+F opens search (decisions/testing.md, App tests). Taking the
keyboard while the window is not focused activates it on Windows, even from
the tray (`app_shell.dart`).
The corner cards: an update, what this version brought, and once per machine
that Lumeo keeps what was watched (interface.md, Help). A file or link given
at start or by a later launch; a link only opens a page (`app_shell.dart`).

**Home.** Shelves named by us, the hero from the first shelf's first page,
the hero's height derived (interface.md), shelves that load when built and
page ahead, empty and failed states that say what is missing and offer the
fix (`home_screen.dart`, `shelf.dart`). Continue watching is the first shelf.
Posters: no caption, year and rating on hover, a lift and no growth, the
watched bar and the download mark (`poster_tile.dart`, `download_mark.dart`).
The logo measured and repainted white when dark, the title as text after
400 ms until it comes (`hero_logo.dart`).

**Title page.** interface.md: the season strip and its keyboard, Play and
what sits beside and under it, the banner's height, stills blurred until
watched, unaired episodes. A Play pressed before the list arrives is kept, a
copy this machine cannot decode is marked and not picked, an empty list says
why with the release date in mind (`play_block.dart`). A season's download
asks for one episode's list at a time (`item_screen.dart`). The release menu
and the sources drawer (decisions/sources.md, `release_menu.dart`,
`source_list.dart`). My list and the score change at once and are sent one at
a time (`library_actions.dart`, `rating_button.dart`). The share link
(`title_link.dart`).

**Player.** decisions/player.md whole, decisions/subtitles.md whole, and of
video-output.md the goal that nothing drawing the interface waits on mpv. The
waits and failures: patience on open, another copy offered when this one
finds no peers, the providers named when they are the reason
(`waiting.dart`). The next episode: the card, the countdown on the held last
frame, chapters as the ending (`skip.dart`, `chapters.dart`), and the
prefetch once this episode is on disk (`player_screen.dart`). Tracks carried
from one file to the next (`tracks.dart`). Where screenshots go and how their
names are escaped (`screenshots.dart`). Copies this machine decodes badly
(`decoders.dart`, sources.md). A non-ASCII key sent as its US-layout key
(`bindings.dart`). Closing saves the position and stops mpv, bounded in time.

**Search.** A wait before asking, films and series asked at once and
answered apart, the ranking by how much of the title the word is, answers
kept per word, five rows and the way to all of them, the recent searches
remembered only when one is submitted or opened (`search_box.dart`); the
results as a grid (`search_screen.dart`). Typing in the Flutter search lagged
on 2026-10-25, up to seconds per letter, cause unmeasured: the prototype's
text field is typed into on the same machine.

**Library.** decisions/library.md. The order of My list is this machine's,
History pages in and a removed line forgets its progress, new episodes as a
shelf (`library_screen.dart`), dates and lines as people say them
(`library_text.dart`).

**Settings.** interface.md, Settings. A stepped number shows each press and
sends the last, a value from another client lights Custom, a refusal is said
in its section (`controls.dart`, `settings_screen.dart`). The sections:
General, Appearance, Playback, Audio and subtitles with a sample line drawn
in mpv's units, Downloads with the disk as one bar, Sources dragged into
order with the way back to a title, Shortcuts read from mpv, About with
what a report needs in one copy (`settings/`).

**Downloads panel.** interface.md, the panel grouped by what can be done; the
rows, season rows, time left and what a row waits on (`download_rows.dart`);
a ring of fixed size in the bar (`downloads_indicator.dart`).

**The machine.** Background, tray, notification, start at login and Ctrl+Q
(interface.md). One instance, the core as a child holding its stdin, a new
core waiting for the old one's lock (shipping.md). Update checks and the
notes of every release skipped, betas included (shipping.md,
`release_notes.dart`). mpv's log with the previous one kept (`folders.dart`).
The language follows the desktop's and changes without a restart.

## Tests

The layers of decisions/testing.md stay; the tools change. Units are QtTest,
app tests are Qt Quick Test over a fake core that answers with the same
fixtures, and player tests run a real libmpv on headless Weston, as now. Qt
has no fake clock, so an interval a test needs to run out is a property the
test shortens, as `openPatience` is. The Dart suite (about 440 tests) is the
checklist: each behaviour ports with its screen, at the lowest layer, once.

## Open questions

- The lowest Qt the packages build against: Fedora's and Arch's own. If
  Fedora's release is below 6.12, build against it or bundle Qt.
- `mpvqt` or our own `QQuickFramebufferObject` (Layout).
- Where the Windows libmpv comes from, pinned by hash (roadmap, Next).
- The fake core in app tests: in-process `QHttpServer` (tests are not
  shipped, so its licence allows it) or a replacement for the network
  manager's replies. Settled by the first app test.
