# How the client is tested

A test lives in the lowest layer that can show the behaviour it is about, and a
behaviour is tested once.

## The layers

| Layer | Where | Runs with | For |
| --- | --- | --- | --- |
| Unit | `desktop/tests/*_test.cpp` | `ctest` | a class on its own: ranking, parsing, what plays next, a store against the fake core |
| App | `desktop/tests/app/tst_<area>.qml` | `ctest` (offscreen) | the whole shell over the fake core: focus and keys, navigation, what reaches the core |
| Player | `desktop/tests/player/tst_<area>.qml` | `tool/player-test.sh` (Weston) | anything that needs a real libmpv: playback, mpv's keys and properties, the render thread, frames |

Units are QtTest and app tests Qt Quick Test, all under a minute together. The
player layer runs a real libmpv on a headless Weston, about two minutes, so
nothing goes there that the other two can show.

Units and app tests share `FakeCore` (`tests/fakecore.h`): QHttpServer on a
real local socket, answering with the core's JSON from `tests/fixtures/`, which
`core/internal/api/fixtures_test.go` checks against the types the handlers
write, so the two cannot drift. It keeps none of the core's rules: what is
next, Continue watching and the history are what the test sets. It holds a
request in flight when told to and refuses a wrong token, and the real socket
is what lets a unit see the client send a refused connection again or read the
token again. Its request log is shared across a test file: a test reads it from
where it began.

### App tests

An app test builds `Shell` as the window holds it, over the fake core, with
`XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `XDG_STATE_HOME` in a temporary folder
(`tests/app/main.cpp`): nothing it runs reads or writes the desktop user's
settings. It presses keys and clicks rather than calling handlers, and reads
what reached the core from `fakeCore`.

The focus is the class of defect that keeps coming back. Keys are delivered by
climbing from whatever holds the focus, so a window whose focus landed nowhere
answers no shortcut and says nothing about why. It has cost F11 on a window
nobody had clicked yet, and later back, fullscreen and search together. The
page the stack changes to takes the keyboard, and the app tests press the keys.

What Qt Quick Test asks of a test, learned the hard way:

- `tryVerify` wants a function returning a boolean; `tryCompare` a property.
- `waitForRendering` times out when no frame is pending: wait for a
  positioner with `waitForPolish`, or for a popup's `opened`.
- A popup's content is not a child of the page: find it under
  `popup.contentItem`.
- Offscreen, `grabImage` draws neither a `MultiEffect` layer nor an animated
  node, so an empty circle or a missing ring in a grab proves nothing.

### Player tests

What only a real libmpv can show: a film opened, played, sought and run to its
end; mpv's keys and mouse buttons; the properties mpv is given and reports
back; the render thread, frames and screenshots. The screen is Weston, not
Xvfb: X11 gives the scene graph a GLX context where a desktop gives EGL, and
the path under test is not the one people run. 0.1.19 shipped with every film
frozen on its first frame under a green suite on Xvfb. Weston on llvmpipe is
Wayland and EGL, which is what the application meets on a desktop.
`player-test.sh` makes its clips with ffmpeg, preloads
`tool/no-libva-wayland.c` (libva crashes probing a compositor without
`wl_drm`) and sends sound to ALSA's null device.

A setting or the pause is read back from mpv rather than proved by waiting for
its effect or read off the bar, which hides itself. A screenshot taken through
mpv's `screenshot-raw` has alpha 0: check a pixel's alpha, not whether it
looks white.

Not covered by any layer: the window itself (the system's title bar, real
fullscreen), the tray and the notification, a real GPU, and Windows. Those are
checked by hand against the built bundle.

## What a test checks

- **Behaviour, not looks.** A test fails when something cannot be done or is
  done wrong: a control out of reach, a key that goes nowhere, a request the
  core never gets, text that says the wrong thing. A position is checked only
  when being elsewhere loses something: a panel off the window, a control
  that moves out from under the pointer. Alignment, proportions, animation and
  screenshots are for the eye and the mockups, not for a test.
- **Once.** Before adding a test, find the ones that already touch the
  behaviour. A higher layer does not repeat a lower one: an app test covers
  the wiring between screens (the Storage link opens Settings at Downloads),
  not what a screen does on its own. Two tests on the same path are one test.
- **A regression test says what shipped.** A fix for a visible defect comes
  with a test in the lowest layer that shows it, with a comment on what
  happened.
- **No real waiting.** Qt has no fake clock, so no test waits out one of the
  app's own timers: an interval a test needs to run out is a property it
  shortens (`Core::patience`, `Next.second`, `Preferences::rememberDelay`). A
  check that something did not happen waits one or two cycles of the timer
  behind it.
