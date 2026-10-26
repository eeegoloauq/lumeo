# Video output

## mpv draws on Qt Quick's render thread, through its render API

`MpvItem` is a `QQuickFramebufferObject` of our own: mpv renders each frame
through its render API into the item's framebuffer object, on Qt Quick's render
thread, and the scene graph composites it under the bar like any other item.
This is what mpv's own Qt example does. KDE's `mpvqt` wraps the same thing; it
was not taken because it is not packaged everywhere the client goes and adds a
dependency for a hundred lines.

The scene graph is OpenGL (`QQuickWindow::setGraphicsApi`), and desktop OpenGL
rather than GLES (`src/main.cpp`): on Wayland with NVIDIA's driver Qt picks
GLES, mpv then declares its textures `mediump`, and NVIDIA reads them at that
precision, which turned Anime4K's orange green under Flutter. After a frame mpv
leaves its own GL state behind, which `resetOpenGLState` clears before the
scene graph draws on.

The display goes to mpv with the context (`MPV_RENDER_PARAM_WL_DISPLAY` or
`X11_DISPLAY`), so a hardware decoder hands frames to GL without a copy:
VA-API's interop needs it, NVDEC's goes through CUDA and does not.

## Nothing that draws the interface waits on mpv

mpv's two callbacks arrive on its threads and only post to the item: the wakeup
drains mpv's events on the GUI thread, the update schedules a frame. Commands,
property writes and reads are asynchronous, and every value on screen is an
observed property. A synchronous call on the GUI thread stalls the whole
interface during every seek; that is what the Flutter client learned on GTK's
thread, and why the Qt client was chosen (foundations.md).

When a frame is shown is mpv's to decide. Timing frames ourselves from
`NEXT_FRAME_INFO`'s `target_time` was tried in the Flutter client: `render.h`
documents it in microseconds and mpv has filled it with nanoseconds since 0.36,
so every film stood on its first picture. Our own clock arithmetic against
mpv's is a second implementation of something mpv already does.

## Open

`ADVANCED_CONTROL` is off. The Flutter client turned it on for screenshots:
without it mpv grabs in software, and mpv 0.41's software grab could not read
an NVDEC frame. Screenshots of an NVDEC-decoded film on NVIDIA are unchecked
in this client. If they fail, the flag comes on with what it asks of the
render thread (`mpv_render_context_update` on every update).

A black picture or a stuck frame on NVIDIA under Wayland is read against mpv's
own statistics (`I`): whether `frame-drop-count` climbs while the picture is
still says whether mpv or the compositing stopped.
