# Roadmap

What is next, not what was done: done work is in git and, where it set a
rule, in [decisions/](decisions/README.md). `[?]` marks a question to settle
before code.

## Next

1. What a first-time user runs into, in this order (mockups agreed):
   - The player shows "0%" while the downloads panel says "Finding peers".
     Under the ring: the same stage, then peers and rate; after about 30 s
     with no peers a quiet "Try another copy" naming the next copy. The ring
     stays put; lines appear below it.
   - One release menu for films and series: Automatic (checked by default,
     "the best copy for each episode") first, then On disk, Available, and
     "All copies…" and "File/Folder on this computer…" last, no icons. A
     film's file on this computer needs the core's link to accept a film.
   - A setting "Ask every time": Play opens the copies list, the pick plays.
   - After adding a source from "Add one", a "Back to <title>" button.
   - The title is blank until the logo loads or finally fails: after 400 ms
     show the text in the logo's box, cross-fade the logo in when it comes.
   - A back arrow left of the wordmark on pages with a way back; no tab lit
     on pages that are not Home, Library or Settings.
   - mpv's `R` takes `sub-pos` past the core's 70–100, and Settings shows
     the raw error under Appearance.
   - Subtitles: default "Foreign audio", and a subtitle turned on or off by
     hand is remembered per audio language for the next titles.
   - Once per machine, on leaving the player the first time: a card where
     the update card sits, "Lumeo keeps what you watch", saying the title is
     in My list and on this computer and, from the keep setting, when it is
     deleted; Storage and close.
2. Windows libmpv: media_kit's is mpv 0.36 built without Lua, so the console
   and statistics do not work. Ship a current libmpv with Lua, pinned by hash.
3. Skip the opening and ending of files whose chapters are unnamed, found by
   the audio the episodes of a season share (`[?]`).

## Remote core

The client already speaks HTTP to the core, so a core on another machine is a
deployment, not a rewrite. Before anyone runs one:

- Pairing: the core shows a one-time code, the client trades it with the
  address for a token of its own, revocable per device.
- TLS in the core: a self-signed certificate whose fingerprint the client
  pins at pairing (mpv gets it as `tls-ca-file`); a reverse proxy with a
  real certificate also works.
- A confined deployment shipped with the binary: a systemd unit and a
  container, unprivileged, writing to the data directory only.
- More than one core address in the client, switchable, each with its token
  (`LumeoApi.baseUri` changing at runtime).

Later: a management web UI, HTTP and WebDAV sources, phone and TV clients.

## Library and storage

- Default download folder `Videos/Lumeo`, laid out
  `Title (Year)/Season NN/<torrent name>/`. Only the directories above the
  torrent's are ours: renaming its files breaks seeding.
- Trakt import and export. A first-watched time needs a column of its own:
  `progress.updated_at` moves with a rewatch.
- A folder of films the user already has, scanned as a library of its own on
  the home screen.
- A series' episodes as a vertical list under the banner (still, length,
  synopsis for watched and next only). Mockup first: canvas "Series page ·
  release picker", page "Others' layouts".
- Freeing a pack episode costs ~250 ms (copying the two boundary pieces) and
  holds `startMu`, so a Play at that moment waits. Left as is until someone
  notices; the fix then is punching holes in place (`fallocate`,
  `FSCTL_SET_ZERO_DATA`) with the copy as fallback.

## Player

- A copy whose swarm is empty: after a while with no peers the player says so
  and offers another copy. The addon's seeder count cannot tell: zero is also
  what an addon without counts sends.
- mpv's window requests (clipboard, window size, minimise, on-top): answer
  each through an observed property, as `fullscreen` is.
- `video_output.cc` treats a failed `eglClientWaitSyncKHR` as signalled;
  handle it as the timeout, with the next change to the fence code.
- "Identify as…" for a file matched to the wrong title or none (`[?]`).
- A copy that is not the episode (another cut, a short), told by mpv's
  `duration` against the catalogue runtime. Only if somebody asks.

## Application

- Community translations through Weblate, committing to Forgejo (the GitHub
  mirror is overwritten by pushes). Runtime as minutes from the core, so the
  client says it in the viewer's language.
- A title never opened, on a slow Cinemeta: draw the page from the catalog
  row at once and fill episodes and cast in later. Retry a failed poster with
  a backoff.
- Settings to add: what opens at startup; pausing when minimised (X11 and
  Windows only: GTK on Wayland is never told); an external player for what
  our mpv cannot open; surround passthrough; subtitle outline; whether a
  newer release exists; mpv's network timeout and cache, `hwdec`.
- The home hero rotates every ~10 s, paused under the pointer (mockup first).
- Gamepad support.

## Metadata: TMDB

`[?]` TMDB as an optional provider with the user's own key
(decisions/foundations.md, Metadata). It brings what Cinemeta lacks:

- collection shelf on a film's page;
- season posters, also in Continue watching;
- More like this from recommendations;
- original-language audio as the default track;
- a trailer button played by our mpv through yt-dlp (`[?]` whether embedded
  libmpv loads its ytdl hook).

## Sources and the swarm

- anacrolix/torrent v1.61.0 can freeze a download from few peers for up to a
  minute (#1070, fixed on master). Update to the first release with the fix
  and drop the skip in `TestBackendStreamsFromLocalPeer`.
- Anime through Kitsu ids: Cinemeta folds sequels into seasons of the first
  title, so episodes numbered per part go missing.
- Playback jumping to the end of an episode, cause unknown. Next time: the
  core's `stream cut short` warning and `mpv.log` in `~/.local/state/lumeo`.
- `[?]` A proxy per addon, beyond `HTTP_PROXY`.
- `[?]` Ranking by language flags for live action, where the flags are
  mostly dubs.

## Client debt

- Go through what media_kit publishes (streams, state, configuration) against
  what we ask mpv for or keep in fields, and delete the copies.

## Shipping

- Copr, arm64, a self-hosted Flatpak remote.
- Windows: a signed installer if SmartScreen costs users; Snap Layouts on the
  maximise button.

## To check by hand

Windows 10 and 11: the title bar (drag, snap, maximise, the Windows 10 top
edge), fullscreen, a second launch and "Open with", the core starting and
stopping with the app, playback and seeking, subtitles and screenshots, the
picture modes, freeing one episode of a pack while the next plays, left click
pausing, and the home banner on scroll. A picture frozen after the display
sleeps is DWM not showing frames Flutter presents; resizing the view's child
window by a pixel revives it, a workaround to agree first.

A filtered line without a VPN: blank posters fill in within about 30 s.

## Open questions

- A demo source without copyrighted content.
- Whether a first-party indexer is worth writing once addon gaps are known.
