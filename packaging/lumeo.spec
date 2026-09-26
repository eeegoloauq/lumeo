# The package is built from artefacts, not from source: the Flutter bundle and
# the Go binary are produced by the release workflow (or by
# packaging/build-rpm.sh locally) and arrive here as one tarball. Building
# Flutter inside rpmbuild would mean pulling the SDK and the pub cache from
# the network during %build, which no distribution build system allows.
Name:           lumeo
Version:        %{?version}%{!?version:0.1.0}
Release:        1%{?dist}
Summary:        Find, acquire and watch films and series

License:        MIT
URL:            https://github.com/eeegoloauq/lumeo
Source0:        %{name}-%{version}-linux-x86_64.tar.gz
ExclusiveArch:  x86_64

BuildRequires:  desktop-file-utils
BuildRequires:  libappstream-glib

# libmpv is opened with dlopen() from Dart, so it leaves no DT_NEEDED entry
# and rpm's automatic dependency generator cannot see it. Without this line
# the package installs and the player fails at the first frame.
Requires:       mpv-libs
Requires:       gtk3
# Fedora builds libavcodec without the patented decoders, so mpv-libs alone is
# not enough to play most of what a swarm actually carries. Two different
# failures, and the second is the worse one:
#
#   - HEVC and E-AC-3 are simply absent, and the copy opens black or silent.
#   - h264 is absent too, but Fedora fills the hole with Cisco's libopenh264,
#     which plays and does not survive a backward seek: the sound lands seconds
#     away from the picture. mpv closes those reports as a broken decoder
#     rather than a bug (mpv-player/mpv#15837), and it looks for all the world
#     like a bug in whoever asked for the seek.
#
# This is a Recommends rather than a Requires on purpose: the package lives in
# RPM Fusion, dnf pulls it in for anyone who has that enabled and installs us
# anyway for anyone who does not. The player says which decoder is missing, or
# which one is going to lose the sound, and how to get it.
Recommends:     libavcodec-freeworld

%description
Lumeo is a media library, acquisition and playback platform: one Go binary
with SQLite behind a Flutter desktop client. It browses a catalogue that needs
no API key, ranks the ways to watch a title by the health of the swarm before
its resolution, and plays the file while it is still arriving.

%global debug_package %{nil}
# Old rpm builds (and non-Fedora ones) do not define where AppStream metadata
# goes; the path itself has been the same everywhere for years.
%{!?_metainfodir: %global _metainfodir %{_datadir}/metainfo}

%prep
%setup -q -n %{name}-%{version}-linux-x86_64

%build
# Nothing to build: see the note at the top.

%install
# The bundle stays in one piece. The Flutter binary looks for its engine and
# plugin libraries at $ORIGIN/lib, and for the core it starts beside itself,
# so splitting them apart breaks the app.
install -d %{buildroot}%{_libdir}/%{name}
cp -a bundle/. %{buildroot}%{_libdir}/%{name}/
install -Dm755 lumeo.sh %{buildroot}%{_bindir}/%{name}

install -Dm644 dev.lumeo.lumeo.desktop \
  %{buildroot}%{_datadir}/applications/dev.lumeo.lumeo.desktop
install -Dm644 dev.lumeo.lumeo.metainfo.xml \
  %{buildroot}%{_metainfodir}/dev.lumeo.lumeo.metainfo.xml
# The icon sizes are rendered in build-dist.sh, once for every package.
install -d %{buildroot}%{_datadir}/icons
cp -a icons/hicolor %{buildroot}%{_datadir}/icons/

%check
# gdk-pixbuf (GNOME Shell's app grid) sniffs only the first bytes for "<svg";
# rsvg-convert in build-dist.sh does not, so a long preamble passes the build
# unnoticed.
head -c 200 %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/dev.lumeo.lumeo.svg | grep -q '<svg'
desktop-file-validate %{buildroot}%{_datadir}/applications/dev.lumeo.lumeo.desktop
appstream-util validate-relax --nonet \
  %{buildroot}%{_metainfodir}/dev.lumeo.lumeo.metainfo.xml

%files
%license LICENSE
%{_bindir}/%{name}
%{_libdir}/%{name}/
%{_datadir}/applications/dev.lumeo.lumeo.desktop
%{_metainfodir}/dev.lumeo.lumeo.metainfo.xml
%{_datadir}/icons/hicolor/*/apps/dev.lumeo.lumeo.*

%changelog
* Sat Sep 26 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.64-1
- The interface is translated, Russian first. It follows the system language,
  and Settings, General, Language switches it at once. Titles, descriptions
  and genres stay as the catalogue sends them, in English.
- A download that stalled while the computer slept starts again by itself
  after waking, as after a network change.

* Fri Sep 25 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.63-1
- A download that stalls after the network changes (a VPN switched on or
  off, another Wi-Fi) starts again by itself; pressing Play on a stalled
  download does the same.
- The home screen no longer waits for an addon that never answered.
- A title you start watching goes on My list.
- New defaults: watched downloads are kept 30 days within 50 GB, and episode
  stills are shown.
- The player opens without flashing the title and 100% over a downloaded
  episode; the next-episode ring runs from the moment its card appears;
  seeks show mpv's bar.
- Windows: seek-bar previews and the second Esc work.
- Settings scroll with the pointer anywhere in the window; the rating button
  is round; files opened from disk are no longer listed as downloads.

* Fri Sep 25 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.62-1
- No source addon ships with the app: a fresh install starts with Cinemeta
  and OpenSubtitles, and until a source is added Play says
  "No source addons" and leads to Settings, Sources. An install that already
  has one keeps it.
- The Sources page no longer has a Configure button; an addon is configured
  on its own site and its address pasted in.
- Resetting settings is no longer undone by a change sent just before it.

* Fri Sep 25 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.61-1
- Settings are one page with its sections listed beside it, and the list
  follows as you scroll.
- Downloads can be paused and resumed, and a pause survives a restart.
- The downloads panel groups downloads into ready to watch, arriving and
  waiting, shows how long one has left and why one waits, and names the copy
  (resolution, HDR).
- New settings: seeding, upload and download speed limits, the download
  folder, how many days a watched download is kept, subtitle colour and
  styling, the arrow-key seek step, when the next episode is offered, and
  violet and teal accents.
- Text size, timeline previews and the screenshots folder are kept per
  computer.
- Settings can be reset to their defaults; About shows the player version,
  copies details and opens the logs.
- Secondary text is set in Plex Sans; monospace is kept for paths, addresses
  and commands.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.60-1
- The Windows installer builds again.
- Other accounts on the computer can no longer use Lumeo's core: every
  request carries a key only your account can read.
- The searches you went through are offered again under the empty search
  field.
- Playback settings choose how the next episode starts: after 5, 10 or 20
  seconds, or only when you press it.
- A download shows in the list the moment it starts, and says whether it is
  finding peers or fetching metadata.
- A download that could not start, for example on a drive that was not
  mounted yet, is tried again the next time Lumeo opens.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.59-1
- A file opened with Lumeo starts playing at once and gets its title while
  it plays.
- A damaged piece of a torrent no longer makes the player jump to a later
  scene or the end of the episode.
- Freeing a download works while the app runs on Windows, and on Linux its
  disk space comes back at once.
- Downloads on Windows take only the space they have fetched, so starting
  a film no longer stalls the disk.
- Reopening the app right after closing it brings the window back, and the
  first screens wait for the core instead of showing an error.
- Keep until watched frees a download as soon as its grace period ends.
- The banners on the home screen and title pages grow to fit their text on
  a short window.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.58-1
- A Windows installer is on the release page, for Windows 10 and 11.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.57-1
- The app draws with Impeller, Flutter's current renderer, instead of the
  older Skia; the player's picture shows under it now.
- The libraries in the package no longer point at the machine they were
  built on.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.56-1
- A Library tab: My list, with a shelf of new episodes of the series you
  follow, and History of what you watched, where episodes are rated.
- A title page has + for My list and your 1-10 rating beside the source.
- An empty source list says why: not out yet, a provider blocking, limiting
  or down, or no copies found, with Try again where it can help. Play is off
  when there is nothing to play.
- The app starts its own core and runs once: a second launch raises the
  window, and after an update the window never talks to the old core.
- A package for Arch Linux on the release page.
* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.55-1
- Pictures load better on a throttled network (without a VPN, say): a
  stalled image server is given up on in seconds instead of twenty, and a
  picture that failed is asked for again instead of staying blank.
- A poster still loading shows its title card instead of an empty tile.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.54-1
- Titles and home rows you have opened before show at once even when the
  metadata service is slow or blocked (without a VPN, say); they are
  refreshed in the background.
- Safer: the core serves only video files, refuses requests sent by web
  pages, keeps addons from reaching your local network, and caps what an
  addon can make it hold in memory.
- Downloads start on systems with IPv6 turned off.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.53-1
- After an update, series and film details are fetched again the first time
  you open them, so improvements such as stills for later seasons show up at
  once instead of a day later.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.52-1
- Episode details are refreshed daily again: a series you kept seeing in
  search or on the home page kept the episode list from the day it was first
  opened, without new episodes and without the stills for later seasons.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.51-1
- An episode on disk with no still of its own shows a frame from its file,
  taken once a third of the way in. Episodes with neither show their number
  on a plain tile.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.50-1
- The player's download panel shows this episode and the next: waiting,
  arriving, on disk, or no room with Download anyway. The button stays once
  the episode is on disk.
- The downloads panel groups a season into one row that opens into its
  episodes, plays what is ready with a click, and keeps finished downloads
  for a day, a week or until Clear.

* Thu Sep 24 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.49-1
- Once an episode is on disk, the next one starts downloading, so a series
  goes on without a wait. It stays within the disk limit and the free disk;
  a switch in Storage turns it off.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.48-1
- Storage has a disk limit and a keep policy: until watched, 30 days after
  watching, or forever. Over the limit, watched downloads go first;
  unwatched ones are never deleted.
- Discarding one episode of a season pack no longer deletes the other
  episodes' files.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.47-1
- Under Play, one small button says whether it plays the copy on disk or
  streams, and opens the list of copies.
- A download button beside the season tabs fetches every released episode
  of the season; on a film page it fetches the film.
- The list of copies has a one-line header.
- Title pages that fit the window no longer scroll.
- The subtitle language list in Settings no longer runs to the bottom of
  the window.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.46-1
- Episodes and films on disk open even when the source addon refuses to
  answer.
- A watched episode or film started again and left half way resumes there,
  shows its bar and comes back to Continue watching.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.45-1
- The copies of a film or episode open in a drawer on the right: on disk
  first, then by resolution, with each copy's languages, what is on disk
  and the pack used last time. The player's Source page shows the same.
- A poster has one bar, how much was watched; what is on disk is a mark in
  its corner, as on episode cards.
- Escape closes a dialog instead of leaving the page under it.
- Hardware decoding uses mpv's auto-safe.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.44-1
- The seek bar shows the frame under the pointer, with the chapter and
  the time, over parts that are downloaded and parts that are not.
- The time over the seek bar sits centred over the pointer.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.43-1
- The mouse wheel over the episode list or any other panel in the player
  no longer changes the volume; it does so only over the picture.
- Series that the still provider numbers as one long season, Re:Zero among
  them, show episode stills after the first season.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.42-1
- Play on an episode that is not the selected one plays it, instead of
  jumping back to the selected episode.
- The ring around the selected episode is no longer cut off at the top.
- Settings sit on the left edge again.
- The app says when the core it found running is from another release.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.41-1
- Settings show one section at a time from the list on the left:
  Appearance, Playback, Subtitles, Sources, Storage and About. The
  paragraphs are gone and every control is one size. Subtitles gain the
  Background choice (None, Shadow, Box).
- One accent, white by default; amber, red or blue under Appearance. It
  colours Play, the download bars, the focus ring and the chosen source.
- Loading shows a spinner, after a moment, instead of the amber line.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.40-1
- "Open with Lumeo" on a video file plays it. Lumeo names the film or the
  episode from the file and folder names, so it has its title, keeps its
  place in Continue watching, and the next episode plays from the same
  folder. A file it cannot name still plays and remembers where you were.
  The file is never moved or deleted, and Storage leaves it out.
- The window comes back at the size it was closed at, and maximised if it
  was: on 0.1.37 the state was saved at a moment that never came.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.39-1
- Keys work in the player while the film is still arriving: Esc used to
  do nothing until the first picture.
- The title page opens with the keyboard on the current episode, and the
  arrows run on into the next or previous season.
- Watched episodes carry a full white bar instead of a check; progress
  bars are white. The on-disk mark is a plain download arrow, the ring
  round the chosen card is thinner, and only the card under the pointer
  shows a play button.
- The player's episode list shows the same pictures as the title page,
  with the series art where an episode has no still of its own.
- An episode whose only title is "Episode N" is no longer printed as
  "18 · Episode 18".

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.38-1
- The episode strip works from the keyboard: Tab enters it on the chosen
  episode, the arrows choose, Enter plays, and the chosen card is ringed
  in white with its neighbours in sight. A click chooses, the play button
  on the still plays. The strip no longer jumps back to episode one.
- Episodes on disk carry a download mark; one downloading shows a ring.
- In the player, Esc leaves fullscreen first and the film only after; q
  leaves at once.
- Subtitle style has a Background: none, shadow or box, kept for the
  next film.
- "Search again" for subtitles is its own button under the list.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.37-1
- The next episode starts every time a film runs out, and its card comes
  back after seeking back from the end and watching it again.
- The window reopens at the size it was closed at, maximised if it was.
- Copies carrying your audio or subtitle languages rank above sharper
  ones without them.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.36-1
- Screenshots (s) are saved again with hardware decoding on: mpv takes
  them on the GPU, as a JPEG instead of a 6 MB PNG.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.35-1
- A request caught on a connection that silently died (a VPN switch,
  Cloudflare going quiet) is sent again on a new one, so sources and
  posters load instead of failing until a manual retry.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.34-1
- Artwork that was scrolled past before it finished loading is still
  cached, so a long episode list shows every still offline.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.33-1
- Arrow keys seek exactly by their step instead of to the nearest keyframe.
- Artwork is served by the core from an on-disk cache and loads once;
  Settings > Storage shows its size and clears it.
- The player keeps mpv's log in ~/.local/state/lumeo for bug reports.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.32-1
- Next-up skips episodes that have not aired: a caught-up series leaves
  Continue watching until the release date and its page opens on the last
  episode watched. An announced season's tab keeps Play where it was.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.31-1
- The source list no longer hangs until a restart: a connection a provider
  stopped answering is dropped by HTTP/2 pings, and providers are asked in
  parallel. A provider that refuses or does not answer is named under Play.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.30-1
- Storage no longer counts episodes whose files were deleted outside the
  app; their leftover bytes still count as used until freed.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.29-1
- Subtitle size no longer resets when the app starts before its core: the
  player loads the preferences before it opens a file, and stores a size
  only when the user changed it.
- Playback speed belongs to one film and is not carried to the next; the
  setting is gone.
- A new icon, and the GNOME app grid shows it: the old SVG had a comment
  before its tag, which GNOME could not read past.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.28-1
- Fix a crash on mpv 0.41 when the window lost focus with a key held, as on
  Ctrl+V in mpv's console: "release all keys" was sent without its empty
  argument, which mpv dereferences as NULL.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.27-1
- Player fixes: right-hand buttons no longer drift to the middle on a film
  with chapters, the volume slider shows its track, one click switches
  menus, a click on the picture closes a menu without pausing, and the
  next-episode ring fills smoothly.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.26-1
- Redesigned player: one bar of white Material icons, a settings menu with
  pages (source, speed, picture, chapters, decoding, shortcuts), audio and
  subtitles side by side with a style page, an episodes panel, a
  next-episode card with a countdown, and a loading screen.
- Every key goes through mpv: the player's own actions are mpv bindings,
  the console keeps its keys, non-Latin layouts fall back to the physical
  key, any quit closes the player, and zoom follows the cursor.

* Wed Sep 23 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.25-1
- A film resumed after a pause with the window hidden could keep flashing
  the same old frame among the new ones on NVIDIA. mpv now draws in a
  context shared with Flutter's, and Flutter samples mpv's texture itself;
  the EGLImage between the two, whose copy went stale, is gone.

* Tue Sep 22 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.24-1
- A film resumed after a pause with the window hidden could show one or two
  old frames on a loop among the new ones on NVIDIA. The frame is now handed
  to Flutter through a texture made afresh for every frame, as Flutter's own
  compositor does, not one bound once per buffer.
- The skip button takes the opening chapter, not a cold open marked "Intro"
  before it.
- A series caught up to broadcast stays in Continue watching with the
  episode still to come.

* Tue Sep 22 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.23-1
- Skip the opening, and move on to the next episode when this one ends.
  Both are read from the chapters in the file: a release that marks none is
  left alone rather than guessed at.
- An episode that runs out starts the next one, out of the copy of the
  season already on the disk where there is one. An episode that has not
  aired is not offered, and specials are not taken for a continuation.
- A screenshot taken with s is saved at last: it goes to the pictures folder
  under the name of the film, not to the working directory of the process,
  which an application started from a menu cannot write to.

* Tue Sep 22 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.22-1
- Minimise, maximise and close in the player's top bar. Lumeo draws the
  window's title bar itself and a film covers it, so a film was the one
  screen where the window could not be put away or closed.

* Tue Sep 22 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.21-1
- A list of what every key and mouse button does, under the gear in the
  player. Read from mpv rather than written down: the page prints the
  bindings mpv holds, with mpv's own description of each.

* Mon Sep 21 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.20-1
- The picture plays again: 0.1.19 stopped every film on its first frame
  with the sound running and the seek bar a second late. mpv now holds each
  frame to its display time itself, on its render thread.

* Mon Sep 21 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.19-1
- Scrubbing fast no longer freezes the picture and the seek bar together:
  mpv renders on a thread of its own, not on the one drawing the controls.
- The mouse buttons on the picture are mpv's, as the keys are: a click
  pauses, a double click goes fullscreen, the right button pauses.

* Mon Sep 21 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.18-1
- A click on the picture pauses as it lands, no longer 300 ms later; a
  second click within the interval takes the pause back and goes fullscreen.
- Dragging the seek bar keeps the controls up when the pointer wanders off
  the bar.

* Mon Sep 21 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.17-1
- The player's buttons answer on the click: the double click that goes
  fullscreen was listened for over the whole screen, and every button, the
  seek bar and the volume waited out its 300 ms before answering. It now
  belongs to the picture alone.
- Chapters, where the file has them: marks on the seek bar, the chapter's
  name over the pointer, and a list to jump by in the playback menu.

* Mon Sep 21 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.16-1
- The player answers at once again: a blocking call in the video plugin held
  the interface for the length of every seek, so clicks answered seconds
  late, a dragged bar fell behind the pointer, and one press of an arrow
  became two or three seeks. The plugin no longer asks mpv anything from
  the interface's thread.
- The loading ring means waiting for data only; it no longer shows on a
  pause or a seek of a downloaded film.

* Mon Sep 21 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.15-1
- The player's keys are mpv's: every key goes to mpv with its own bindings
  and auto-repeat — keyframe seeks on the arrows, frame steps, speed,
  volume, chapters, loops, zoom and pan, subtitle delay, and I for mpv's
  statistics page. Escape and q leave, c opens the audio-and-subtitles panel.
- Seeking is instant on a downloaded file (relative seeks land on keyframes,
  as in mpv) and the bar seeks as it is dragged. The controls follow the
  mouse and go half a second after it stops; a key or a pause does not
  bring them up.
- Audio and subtitles are one panel — the file's tracks and the database's
  copies as one list of languages — with the starting tracks chosen by mpv
  from the languages in Settings; a file without a preferred-language track
  starts with the best database copy. Subtitle size and height are settings.
- The wait before the first frame stands on the title's artwork; a click in
  the bar's gaps no longer pauses the film.

* Sun Sep 20 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.14-1
- Watch progress: the player reports where a film or episode is and resumes
  from there; a series opens on the next episode with Resume and the time
  left; watched episodes are ticked, part-watched ones carry a bar; the home
  screen starts with a Continue watching shelf. Kept by the core, so another
  client of the same core resumes it.
- Episode stills are blurred until the episode is watched; Show, Blur or
  Hide is a setting next to playback speed.
- The Storage section shows the disk and lists each title on disk with its
  size and a button that frees it, or everything at once.

* Sun Sep 20 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.13-1
- Add-ons live in the core's database and are managed from the Sources
  section of the settings page: what each one provides, on or off, drag to
  reorder, install by address, Configure in the browser. LUMEO_ADDONS only
  seeds a database that has none yet.
- The ground is plain black on every page; the tint taken from the artwork
  is gone.
- A film's artwork fills the window, and its list of sources scrolls into
  view when opened, with Play still on screen.

* Sun Sep 20 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.12-1
- Settings that survive a restart: subtitle languages in order and playback
  speed are chosen on the settings page and kept by the core, so they hold on
  every client of it; volume is remembered by the machine it was set on.
- The Storage section names the folder downloads land in and opens it when
  the core runs on this machine.
- The settings page prints the commands that install a missing decoder, with
  a button to copy them.

* Fri Sep 04 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.11-1
- The frame is handed from mpv to the window differently: the thread that
  draws no longer waits on mpv while mpv waits on it, and a frame is finished
  before the window reads it. This is what a film left paused for long enough
  came back without.
- The player writes down what the picture is doing, in mpv's own words as well
  as its own numbers, so a picture that stops leaves a record.
- The click that closes one of the player's menus no longer carries on to the
  film and pauses it; the menus hang off their button, close on Escape, and
  can be walked with a keyboard.

* Tue Sep 01 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.10-1
- Search opens on the line the tabs stand on, not against the top of the
  window, and the answers unroll under the field and fold away with it.
- The answers are ordered by how much of the title the typed word is — the
  exact name first — instead of one film and one series in turn.

* Tue Sep 01 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.9-1
- Search answers while the name is typed: titles with their artwork, films and
  series in one list, walked with the arrow keys.
- The middle of the bar is Home and Settings with search beside them, and a
  download starting no longer moves anything in it.
- What is downloading is a ring at the right of the bar; a row in the list it
  opens leads to the title it belongs to.
- A Settings screen: the core this client talks to and whether it answers, and
  what this machine can decode.

* Tue Sep 01 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.8-1
- A stopped episode of a season pack stops competing for the swarm with the
  episode still playing.
- A film that will not start says so, instead of claiming the copy has no
  picture when nothing has been said about its picture.

* Tue Sep 01 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.7-1
- A film that has only just started downloading waits for the swarm instead of
  being reported as a copy with no picture.
- Playback begins when the start of the file is actually on disk, and the ends
  of the file are fetched first so it gets there sooner.
- A film that stops to wait for the swarm says so instead of looking frozen.
- The name of what is coming is on screen while it is coming.

* Mon Aug 31 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.6-1
- A copy this machine cannot decode is marked in the table, and Play skips it.
- A film whose sound will not decode says so instead of playing in silence.
- Ctrl+F and F11 answer on a window nobody has clicked yet.
- The picture keeps its middle when the controls appear, and a click on the
  timeline lands on the time the pointer named.
- Episodes with no still of their own show the title's artwork.
- A finished download plays again after the core has been restarted.

* Mon Aug 31 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.5-1
- A series page fits on the screen, and the line across the artwork is gone.
- One bar on every page; Ctrl+F reaches search from anywhere.
- A film takes the screen, and names the decoder it is actually missing.

* Mon Aug 31 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.4-1
- The timeline is a real slider: it can be hit, tapped and dragged.
- Leaving a film started from the banner no longer starts it again.
- The seam across the bottom of a title's artwork is gone.

* Mon Aug 31 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.3-1
- A track that will not decode no longer claims the whole copy is unplayable.
- Seeking lands where it was asked to; the arrows repeat when held.
- Escape comes back to the title instead of resizing the window.

* Mon Aug 31 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.2-1
- Playback: the renderer no longer hides the picture behind a black rectangle.
- Back navigation, a reachable download list, and a Play that plays.

* Mon Aug 31 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.1-1
- The window carries its own title bar, an icon and a fullscreen mode.
- Sources default to Torrentio, so a fresh install can play something.

* Mon Aug 31 2026 Lumeo <67159275+eeegoloauq@users.noreply.github.com> - 0.1.0-1
- First packaged build: player, catalogue, acquisition, subtitles.
