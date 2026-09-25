# Video output

## We own the Linux half of media_kit_video

A film left paused for long enough came back with the sound running and the
picture stopped on the frame it was paused on, on Wayland with the proprietary
NVIDIA driver. Everything between mpv's decoder and Flutter's compositor is C++
in one directory of one package, `media_kit_video`'s `linux/`, and 2.0.1 is the
newest there is: there is no version to upgrade to.

So `client/third_party/media_kit_video` is upstream 2.0.1 with `example/`
removed and the defects listed in its `LUMEO.md` fixed, wired in with a
`dependency_overrides` rather than a dependency, so that the constraint in
`pubspec.yaml` is still the one we go back to the day upstream ships them.
Nothing else in the package is touched: `diff -r` against a fresh copy of the
published archive is exactly our patch, which is what keeps the next upgrade a
re-copy rather than an excavation. `LUMEO.md` has each patch and its mechanism;
the shape of it is:

- **No thread of Flutter's waits on mpv.** The plugin asked mpv for the video
  size synchronously, twice per composited frame, on the raster thread that
  mpv's video output was itself waiting on: a deadlock that stopped the
  picture. On the platform thread instead it held Dart, which on Linux runs
  there, for every busy moment of mpv's core. Now the plugin asks mpv nothing;
  the size comes from the Dart half, observed on mpv's event loop.
- **mpv draws in Flutter's share group, and the frame is finished before it is
  handed over.** Upstream's `EGLImage` between two isolated contexts went stale
  on NVIDIA under Wayland after the window had been hidden. mpv's context now
  shares Flutter's, and the handover is a `glFinish`, not a `glFlush`.
- **A film is drawn even if mpv never sends a second frame.** A size change asks
  for one more composite, so the opening frame does not wait on the next.
- **mpv renders on a thread of its own** (below).

What this costs is a fork, and a fork is debt: one more thing to carry at every
upgrade. What it does not cost is the picture — the alternative on the table
was `enableHardwareAcceleration: false`, and media_kit's software path is capped
at 1920×1080, so it downscales a 4K film rather than showing it.

The integration suite plays a real film through the real libmpv into a real
texture, so it proves the fork builds and draws. The freezes themselves need
the machine they happen on: a Wayland session on the proprietary driver, and a
pause long enough. If one comes back, the question is whether
`frame-drop-count` climbs while the picture is still, and mpv's own statistics
page (`I`) answers it.

## mpv renders on a thread of its own

Embedding libmpv is how every real player does it (Jellyfin Media Player, Plex
HTPC and Stremio's shell in Qt, IINA in AppKit), and each renders on its
toolkit's render thread. That works for Qt because Qt's render thread is not the
one drawing the toolbar. Flutter's is: with mpv's render call on the raster
thread, waiting for each frame's display time, a fast scrub froze the picture
and the seek bar's thumb together, on a fully downloaded file.

So a thread of the plugin owns mpv's EGL context, draws each frame into one of
three buffers and lets mpv hold the render call until the frame's display time
(`BLOCK_FOR_TARGET_TIME`, mpv's default), and the raster thread only picks up
the latest finished buffer, with a fence in each direction. This is what
`render.h` asks for in its first paragraph and what the Windows half of
media_kit already does. `LUMEO.md` patch 3 is the mechanism.

The wait is mpv's, not ours. Timing it ourselves from `NEXT_FRAME_INFO`'s
`target_time` was tried: `render.h` documents it in microseconds and mpv has
filled it with nanoseconds since 0.36, so every film stood on its first picture.
Our own clock arithmetic against mpv's is a second implementation of something
mpv already does, and it is the one not tested against mpv's source every
release. The suite now asks `frame-drop-count`, not only the audio-driven clock.

Rejected with it: `video-timing-offset=0` (a shortcut for embedders that cannot
time frames themselves; upstream hit frame drops with it), `report_swap`
(Flutter never says when a frame reached the screen, and `render.h` says an
inconsistent report is worse than none), a libmpv integration of our own
instead of media_kit (this again, twice, with no picture to show for it) and an
external mpv process (it cannot draw under a Flutter bar).

`ADVANCED_CONTROL` is on because screenshots need it: without it mpv grabs in
software, and mpv 0.41's software grab cannot read an nvdec frame. The render
thread already keeps the rules the flag enforces. The UI test reads mpv's log
for the fallback.

One hop stays that native mpv does not have: mpv draws into a texture, Flutter
composites it, the compositor shows it — up to one Flutter frame of latency
between finished and visible, which no thread removes.

## Flutter's default renderer, Impeller

The client renders with Impeller, Flutter's default on Linux; no line asks for
it. It forced Skia before 0.1.57, because with Impeller the film played as a
black rectangle: upstream media_kit_video handed frames over through an
`EGLImage`, which Impeller did not yet sample on Linux (flutter/flutter#181656).
Flutter 3.47.2 and mpv drawing in Flutter's share group (patch 4) removed both
halves of that.

A black picture or a stuck frame on NVIDIA is compared against Skia before
anything else: `fl_dart_project_set_enable_impeller(project, FALSE)` in
`client/linux/runner/my_application.cc` brings it back.
