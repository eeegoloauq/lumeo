# Roadmap

The MVP workflow is search → select → acquire → play while acquiring → keep →
resume later, and all of it runs end to end. Done work is in git and, where it
set a rule, in [decisions/](decisions/README.md). `[?]` marks a question to settle before code.

## Next, in order

1. **Check on an NVIDIA/Wayland desktop before the release.** The app owning
   its core (decisions/shipping.md): close and reopen at once comes back, the
   screen waits for a core still waiting for the previous one instead of
   stopping on "Try again", and a file opened with a second launch plays at
   once and is named while it plays. The window comes forward on Wayland:
   cover Lumeo with another window and double-click a video in the file
   manager; it should come forward and play, and a "Lumeo is ready" notice
   instead means the activation token did not arrive. Impeller
   (decisions/video-output.md): seeking, fullscreen, and a long pause with the
   window minimised, the case of the freezes in the media_kit_video fork.
2. Comments cut to the why, in a line or two, starting with the largest
   client files (`player_screen.dart`, `menus.dart`, `models.dart`,
   `item_screen.dart`): many narrate how a value was arrived at, which is
   history git already holds. Duplication and dead code found on the way go
   in the same pass.
3. A "keep running in the background" setting (tray or systemd user unit),
   off by default so nothing seeds forever. Needs a design first.

## From the user's notes of 2026-09-27, in order

1. mpv renders at the view's size and owns fit, fill and stretch (`panscan`,
   `keepaspect`), so its OSD is no longer cropped (patch 5 in the fork's
   `LUMEO.md`). Left to check by hand: a window resize and fullscreen on
   NVIDIA/Wayland, and the picture modes on Windows.
2. Windows. media_kit's libmpv is mpv 0.36 built with `-Dlua=disabled`, so
   the console and statistics cannot work: ship a current libmpv with Lua,
   pinned by hash. Then left click not pausing on Windows 10, the picture
   frozen after the display sleeps (leaving fullscreen brings it back), and
   whether the home banner still lags on scroll on Windows 10 now that its
   scrim is one shader pass (0.1.70). The frozen picture is below
   us: after the display turns back on, Flutter's raster thread still
   presents frames and DWM does not show them (mpv and the sound go on);
   resizing the FLUTTERVIEW child window by a pixel and back revives it,
   `RedrawWindow` does not. A fix in the runner would do that resize on
   `GUID_CONSOLE_DISPLAY_STATE` turning on, a workaround to agree first.
   Tested with the CI build under Wine here and on the user's machine.
3. A UX map of the user's journeys with the defaults of each, reviewed
   against screenshots of the real app; mockups only for what changes.
4. Opening and ending found by comparing a season's audio, for files whose
   chapters are unnamed (`[?]`, after the rest).

## Library and storage

- Download folder: `$(xdg-user-dir VIDEOS)/Lumeo`, changeable, laid out
  `Title (Year)/Season NN/<torrent name>/`. Files inside a torrent keep their
  names or seeding and verification break; only the directories above are
  ours.
- Trakt import and export: the core keeps IMDb ids, the list, ratings and
  watched entries, which is all it needs. `progress.updated_at` moves with a
  rewatch, so a first-watched time needs a column of its own first.
- Files the user already has (a folder of films outside Lumeo) as a library
  of their own: on the home screen, not as a Library tab.

## Player

- A copy whose swarm has nobody in it: the wait in the player says so after
  a while with no peers and offers another copy. The seeder count on the
  source list cannot say it: it is the addon's snapshot, and zero is also
  what an addon that gives no count sends.
- mpv's window requests (clipboard, window size, minimise, on-top): answer each
  once through a property the host observes, as `fullscreen` is, or leave mpv's
  "not available". mpv 0.41's NULL deref on an argument-less `keyup` is worth
  an upstream report.
- `video_output.cc` treats a failed `eglClientWaitSyncKHR` (`EGL_FALSE`) like
  a signalled fence. Handle it like the timeout, in the next change to the
  fence code, not alone.
- "Open with": `[?]` Identify as… for a file nothing or the wrong title
  matched (a search picked by hand).
- Subtitles with the download: today an external track is fetched from the
  provider on every open and the list needs the network, so offline only the
  embedded tracks play. Instead the core fetches, once a download knows its
  file, the best match for each preferred subtitle language (by the file's
  hash, which asks the swarm for the first and last pieces early) and keeps
  it in the download's directory, deleted with it. The list shows kept files
  first, as it lists a copy on disk among the sources; the player's rule
  stands, so an external track is added only when mpv chose no embedded one
  in a wanted language, and an embedded track is never doubled. Files are
  stored under names the core makes up, never the provider's, within the
  existing size and gzip limits, converted to UTF-8 text and never
  executable; their only reader is libass/FFmpeg, as it is now.

## Application

- Translations: community ones through a web editor (Weblate) that commits
  `client/lib/l10n/app_<code>.arb`. It has to write to Forgejo, not to the
  GitHub push mirror, which a push overwrites. The runtime ("112 min") is the
  provider's text; the core could send minutes so the client says them in the
  viewer's language.

- Artwork on a throttled network (decisions/security.md): check on a
  filtered line without a VPN that blank posters fill in within about 30 s.
  Stalls after some kilobytes of a body rather than in the handshake are
  routing, which no timeout or retry gets past.
- A slow or blocked Cinemeta (no VPN), the client's half. The core now answers
  a title opened before at once and refreshes it behind the answer, so what
  still waits is a title never opened: the item page spins for up to the
  addon client's 15 s with the catalog row's title, poster and rating already
  in hand. Draw the page from the row and fill episodes and cast in when they
  arrive. A poster that failed (the core's 502) stays blank until the page is
  rebuilt; retry it with a backoff instead.
- Settings still to add. General: what opens at startup, closing to a tray
  (no tray exists; ties in with "keep running in the background" above), and pausing when minimised — GTK 3 on
  Wayland is never told the window was minimised (xdg-shell has no such
  state), so only our own minimise button could see it; on X11 and Windows
  Flutter's `AppLifecycleState.hidden` does. Playback: an external player for
  what our mpv cannot open, surround passthrough. Subtitles: outline. About:
  whether a newer release exists. Downloads: the desktop's own folder chooser in place of the
  one drawn in the app (a portal call on Linux, `IFileDialog` on Windows).
- More than one core address, switchable, kept in `client.json`, each with
  its token. Needs `LumeoApi.baseUri` to change at runtime. For a core on the
  home server plus a local one on a laptop.
- The home hero moves on to another title every ten seconds or so, paused
  under the pointer, with arrows or dots to step (mockup first).
- Settings for the defaults still built in (a list to go through first):
  mpv's network timeout and cache, `hwdec`.
- Gamepad support.

## Metadata: TMDB

`[?]` TMDB as an optional provider with the user's own key (decisions/foundations.md,
Metadata). Cinemeta has no collections, recommendations, season art, original
language, or more than one backdrop. Waiting on it:

- Collection shelf on the film page, by release date, watched ones checked.
- Season posters where posters are shown (Continue watching shows the season
  being watched).
- More like this, from TMDB recommendations, not from genre.
- Original-language audio as the default track.
- Trailer: one button on the title page played by our mpv through yt-dlp
  (recommended, not bundled). Cinemeta's `trailerStreams` are flat per title
  and often not trailers; TMDB's `/videos` gives the open season's newest
  official one. `[?]` Whether embedded libmpv loads its ytdl hook.

## Sources and the swarm

- anacrolix/torrent v1.61.0 loses connection writer wakeups
  (anacrolix/torrent#1070): a download from few peers can freeze for up to a
  minute. Fixed on master (`aa71e8d`, `70072f1`), not released yet. Update to
  the first release that has it and drop the skip in
  `TestBackendStreamsFromLocalPeer`.
- Playback jumping to the end of an episode, so the next one starts, was seen
  in real use and has no known cause: a bad piece only skips to the next
  keyframe (decisions/downloads.md). A stream the core ends early looks exactly
  like that to mpv. When it happens again, look for the core's `stream cut
  short` warning (`journalctl --user` on Linux, `core.log` on Windows) and
  `mpv.log` / `mpv.old.log` in `~/.local/state/lumeo`.
- `[?]` Proxy per addon, beyond `HTTP_PROXY`.
- `[?]` Whether ranking by language flags holds for live action, where the
  flags are mostly dubs. Fresh anime episodes can have only raw copies for
  hours; only another source provider fixes that.
- Whether Cloudflare's 403 comes from our User-Agent or a burst: `curl -A
  'Lumeo/0.1 …'` from a residential line (datacentre addresses get 403 for
  any agent).

## Client debt: mechanics the framework already has

An entry is done when the hand-written version is gone, not wrapped.

1. Go through what media_kit publishes (streams, state, configuration) against
   what we ask mpv for or keep in fields, and delete the copies.

Checked and kept: the episode card's `Focus`, `Shortcuts` and `MouseRegion`
are its roving keyboard stop (the arrows walk the season, Enter plays) and
the play button shown on hover; the window's caption buttons stay out of the
tab order, as the system's own do, and draw their own hover without a ripple;
the poster tile's `MouseRegion` lifts it for any mouse, where
`FocusableActionDetector.onShowHoverHighlight` stays dark after a touch.

The shell's own history duplicates a `Navigator`; it stays until it causes a
defect.

The folder picker (`folder_dialog.dart`) is ours on purpose: it matches the
app and one folder is a small question. If someone asks for the system's
chooser (bookmarks, network places), `file_selector` is the flutter.dev
plugin for it on both systems.

## Shipping

Copr repo, arm64, a self-hosted Flatpak remote.

Windows is built by the release since the first tag after 0.1.57 and has not
yet run on a real machine. What to check there first, on Windows 10 and 11:
the title bar (drag, snap, maximise, the Windows 10 top edge), fullscreen in
and out, a second launch and "Open with", the core starting and stopping with
the app (`%LOCALAPPDATA%\Lumeo\State\core.log`), playback and seeking on
media_kit's libmpv (a 2023-09 build, older than any Linux one), subtitles and
screenshots. Later: a signed installer, if SmartScreen's warning costs users;
the Snap Layouts flyout on the maximise button, which needs the runner to know
where the client draws it.

## Before server mode

Server mode is the same binary deployed separately, with a management web UI,
more providers (HTTP, WebDAV), mobile and TV clients. These land first, because
they cannot be added once someone runs it:

- The API token over a network: TLS (a reverse proxy at least) and a way for
  a remote client to be given the token, typed in or paired. On loopback the
  client reads it from the data directory.
- A confined deployment shipped with the binary: a systemd unit and a container,
  unprivileged, no capabilities, write access to the data directory only.

## Open questions

- A demo source without copyrighted content: the Public Domain Movies addon URL
  we had is dead.
- How far Cinemeta falls short in practice, and whether that makes TMDB the
  recommended setup.
- Whether a first-party indexer is worth writing once addon gaps are known.
