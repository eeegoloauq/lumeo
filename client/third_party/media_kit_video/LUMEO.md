# media_kit_video 2.0.1, patched

Upstream `media_kit_video` 2.0.1 from pub.dev, unpacked here with `example/`
removed and the four things below changed in `linux/`, plus one line of
patch 4 in `lib/src/video/video_texture.dart`. Nothing else is changed: a
`diff -r` against a fresh copy of the published archive is exactly this list,
which is what makes the next upgrade a re-copy and a re-apply rather than an
archaeology session.

    dart pub cache add media_kit_video:2.0.1
    diff -r -x example -x LUMEO.md \
      ~/.pub-cache/hosted/pub.dev/media_kit_video-2.0.1 .

## Why we own a copy at all

A film left paused for long enough came back with the sound running and the
picture stopped on the frame it was paused on; a seek forward brought it back.
Reported on 0.1.5 on Wayland with the proprietary NVIDIA driver. mpv's own
log (`vo=v`) says which half stopped — but nothing in the client could *fix*
it, because everything between mpv's decoder and Flutter's compositor is in
this package's `linux/` directory, and it is C++.

2.0.0 rewrote that directory. Flutter 3.38 stopped handing plugins a GDK GL
context to share, so mpv no longer rendered into Flutter's own texture: it
rendered into a texture of its own, in an isolated EGL context, and the two
were joined by an `EGLImage`. Everything below is a consequence of that
rewrite being new; patch 4 replaces the `EGLImage` with a shared context.

## What is changed

### 1. `linux/video_output.cc` — no thread of Flutter's ever waits on mpv

`video_output_get_width` and `video_output_get_height` asked mpv for
`video-out-params` with `mpv_get_property`, which is synchronous: it hands the
question to mpv's core thread and waits. Both are called by
`texture_gl_populate_texture`, twice per composited frame, on Flutter's raster
thread — the only thread that ever calls `mpv_render_context_render`, and
therefore the thread mpv's `vo_libmpv` waits on in `flip_page` while the core
feeds it frames. The core waits for the video output, the video output waits
for the render call, and the render call waits for the core. The picture stops;
the audio, on its own thread, does not. mpv gives up after its own timeout,
drops the frame and says `mpv_render_context_render() not being called or
stuck` at verbose level — which is why the client asks mpv for `vo=v`.

The first version of this patch (0.1.11 to 0.1.15) moved the question to the
platform thread, in an idle queued from mpv's update callback, once per frame.
That was the wrong thread too: Flutter's Linux embedder runs Dart's UI isolate
on the platform thread, so every frame held Dart for as long as the core was
busy — and the core is busiest during a seek, when frames come fastest. Every
key, click and drag was answered late; a drag along the bar fell seconds
behind the pointer; and a `keyup` delivered late is a key mpv still holds and
auto-repeats, which is how one press of an arrow became two or three seeks.

Now nothing in `linux/` asks mpv anything. The size is the one the Dart half
of this same package already sends: `NativeVideoController` observes
`video-params` through mpv's event loop, where nothing waits, and calls
`VideoOutputManager.SetSize` with `dw`x`dh` (rotation applied) for every film
(a `width`/`height` given to the controller is sent once at creation and then
overwritten by the film's own — that is upstream's behaviour, unchanged). The
getters return that. `video_output_set_size` asks for one more render when
the size changes — a wake of the render thread on the H/W path (patch 3),
upstream's render on the S/W one, moved out of its idle callback into
`video_output_render_sw` for that —
so the first frame is drawn even when mpv has no second frame to announce:
the frames announced before the size arrived were skipped at 0x0, which is
the 1x1 placeholder and no render call at all, and a film paused on its
opening frame would otherwise sit there.

On the S/W path the size is clamped per axis in `set_size` (upstream's rule
for a fixed size) rather than scaled to fit as upstream's getters did for the
natural one; the Flutter side lays the texture out at the film's own aspect
either way. We do not run that path.

### 2. The frame is finished before it is handed over

Upstream called `glFlush()` after rendering into mpv's texture and then had
Flutter's context sample it. A change to an object another context reads is
guaranteed visible there only once it has completed (GLES 3.2, appendix D);
`glFlush` promises only that the commands were submitted. The handover is a
`glFinish()` — on the render thread, where waiting costs nothing anybody
sees.

### 3. `linux/video_output.cc`, `linux/texture_gl.cc` — mpv renders on a thread of its own

Upstream called `mpv_render_context_render` from `texture_gl_populate_texture`,
on Flutter's raster thread — the thread that also draws every widget. mpv
holds that call until the frame's display time (`video-timing-offset`, 50 ms
by default), and its video output waits up to 200 ms in `flip_page` for the
call to come; on a seek storm the raster thread sat in both, and the
scrubber's thumb — pure Dart — stood still with the picture for half a second,
then jumped. `render.h` opens with "preferably rendering should be done in a
separate thread"; the Windows half of this same package does so (its
`thread_pool.h`); the Linux half, rewritten for 2.0, did not.

Now `video_output.cc` starts a `GThread` per video output that owns mpv's
EGL context (patch 4) for its whole life. mpv's update callback only wakes it;
it calls `mpv_render_context_update` (never from the callback, as render.h
insists), draws into a free buffer, and lets mpv hold the render call until
the frame's display time — `MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME` at its
default of 1, on this thread, where nobody else is kept; a seek's frames are
due at once and are released at once. Then it `glFinish`es and marks the
Flutter texture. The hold is bounded by mpv's own video output, which
releases the call at the frame's time or after its 200 ms timeout. The first
version of this patch turned the hold off and timed the wait itself from
`MPV_RENDER_PARAM_NEXT_FRAME_INFO`'s `target_time`; render.h documents that
field in microseconds, `vo_libmpv.c` has handed over the video output's
nanosecond `pts` unconverted since mpv 0.36, and the difference was a
deadline decades away — the thread never came back for the second frame.
Until the film's size has arrived from the Dart side a frame is taken with
`MPV_RENDER_PARAM_SKIP_RENDERING`, so mpv's video output is never left
waiting for a render that does not come.

Frames go round three buffers, each a texture with an FBO: one on screen,
one finished and waiting for the next composite, one being drawn.
`texture_gl_populate_texture` — the raster thread — only takes the latest
finished one (`video_output_take_frame`) and hands Flutter that buffer's own
texture name (patch 4). When the raster thread stops showing a buffer it
puts an `EGL_KHR_fence_sync` fence in Flutter's command stream; the render
thread waits on that fence before drawing into the buffer again, so a frame
Flutter's GPU is still reading is never overwritten under it. A fence that
has not passed in a second is a stuck GPU: the buffer stays Flutter's, the
frame is taken with `SKIP_RENDERING`, and the log says so. Without the
extension (logged once) the buffers are reused unfenced, which the
three-deep ring makes unlikely rather than impossible to notice.

The render thread reads the size under `frames_mutex`, which
`video_output_set_size` now takes, so a resize is never seen half-applied;
a size change wakes the thread to redraw mpv's last frame at the new size
(`redraw_pending`, separate from mpv's own updates, because on a paused film
`mpv_render_context_update` has nothing new to report), which is what patch
1 used to do with a bare texture mark. `dispose` unregisters the texture, so
no composite comes for the frames again, then stops and joins the thread,
which frees the buffers and mpv's renderer with its context current and
releases the context on its way out; `dispose` then destroys the context.

The context is made with `MPV_RENDER_PARAM_ADVANCED_CONTROL`, and this thread
keeps the rules it sets: it calls `mpv_render_context_update` on every wake of
the update callback and never waits for mpv's core (its only waits are its
own condition and Flutter's fences). Without it mpv takes a screenshot in
software, and mpv 0.41's software path cannot read a hardware frame: `s` saved
nothing under nvdec (fixed upstream in c66204b69b, after 0.41.0). With it the
screenshot is drawn by this thread on the GPU, as mpv's own window does. The
cost is that a threading mistake here becomes a hard deadlock rather than a
dropped frame; the rules above are what keeps it out.

Not done, on purpose: `mpv_render_context_report_swap` (Flutter never says
when a frame reached the screen, and render.h warns that an inconsistent
report is worse than none).

### 4. mpv's context is in Flutter's share group — `linux/`, `lib/`

On 0.1.23 and 0.1.24, NVIDIA on Wayland, after a pause and the window hidden:
the film played on, and one and the same old frame flashed on screen every
third frame. mpv, checked in the live process, went on drawing new frames.
Changing the film's aspect ratio from mpv's console
(`set video-aspect-override 2`), which reallocates the three buffers, cured
it on the spot: one buffer's `EGLImage` had stopped seeing what mpv drew
into its texture. Making Flutter's sibling afresh for every frame (0.1.24)
did not help, because the stale copy was the image's, not the sibling's.

So there is no `EGLImage` any more. mpv's EGL context is made with Flutter's
render context as its share context, with the same config and attributes
Flutter gives its own resource and platform contexts
(`fl_opengl_manager.cc`), and the buffer's texture name is what Flutter
samples: one share group, one copy. Flutter hands plugins no context, and
what is current on the platform thread depends on who drew last (GDK makes
its own context current there), so the one place Flutter's render context
is known for certain is the raster thread inside `populate`. The first
composite of the texture makes mpv's context there
(`video_output_share_context`); the render thread, waiting for it, makes it
current for good and makes mpv's renderer in it. If either cannot be made,
the platform thread falls back to S/W and announces the new texture id.

mpv's video output cannot start without the renderer ("No render context
set"), so a film has to wait for that first composite, and it waits in mpv
itself: the output registers a client of its own on mpv's `on_load` hook —
mpv's mechanism for a client that must prepare before a file is opened — and
continues each hook once the renderer exists, the S/W path has taken over,
or the output is disposed. Nothing on the Dart side waits, so closing a
player before its first composite (the window hidden, the screen left at
once) stops mpv as it always did. The one change in `lib/` is that `Video`
mounts the `Texture` as soon as it has an id, covered by the fill colour
until the film has a size; upstream mounted it only then, which is after the
film is opened, and the composite that lets it open would never come.

## What is deliberately not changed

* `texture_gl_dispose` deletes the placeholder's name from the platform
  thread, in whatever context is current there — as upstream did with its
  one name. Flutter's Linux embedder gives a texture no destruction callback
  on the raster thread, so there is no place to do it right; the name is
  small. The same embedder gap leaves upstream's window in which a composite
  already inside `populate` outlives `dispose`; nothing here widens it, and
  the frames themselves are freed under the mutex `populate` takes them
  under.
* The S/W render path's idle callback holds an unreferenced `VideoOutput*`
  (upstream issue #1442). We are on the H/W path; the H/W callback has the same
  shape and the same narrow window against `dispose`. Not this fix.
