# How the client is tested

A test lives in the lowest layer that can show the behaviour it is about, and a
behaviour is tested once. `client/test/suite_test.dart` checks what of this a
machine can check; the rest is for whoever adds a test.

## The layers

| Layer | Where | Runs with | For |
| --- | --- | --- | --- |
| Unit | `client/test/*_test.dart` | `flutter test` | a function, a model, a store: ranking, parsing, what plays next |
| Widget | `client/test/*_test.dart` | `flutter test` | one widget on its own: a panel's rows, a card's marks, a painter |
| App | `client/test/ui/<area>_test.dart` | `flutter test` | the whole app over the fake core: the shell, focus and keys, navigation, what reaches the core |
| Player | `client/integration_test/` | `tool/ui-test.sh` (Weston) | anything that needs a real libmpv: playback, mpv's keys and properties, the render thread |

The first three run in about two minutes together. The player layer builds the
Linux app and runs it on a headless Weston: about five minutes for 31 tests, so
nothing goes there that the other three can show.

### App tests

The app tests drive `LumeoApp`, the way the Weston suite does, but under
`flutter test`: fake time, the default window size (1440×900), Linux as the
platform (it decides scrolling, scrollbars and shortcuts), and no GPU. Every
defect this client shipped in its first years was of this kind and invisible to
a unit test: a wordmark printed twice, a panel clipped by the bar it hung from,
a shortcut with nothing focused to deliver it, a Backspace binding that took
the key from the search field, text outside a Material in Flutter's
yellow-underlined fallback style. One test walks the render tree for that
fallback style and catches the whole class, not the instance.

The focus is the class that keeps coming back. Keys are delivered by climbing
from whatever holds it, so a window whose focus landed nowhere answers no
shortcut and says nothing about why. It has cost F11 on a window nobody had
clicked yet, and later back, fullscreen and search together. The shell takes
the keyboard back whenever the page changes under it, and the app tests press
the keys rather than call the handlers.

Everything goes through `test/ui/app.dart`:

- `uiTest` in place of `testWidgets`: the platform, the window size, a window
  channel that records calls in `windowCalls`, a machine that decodes
  everything (`DeviceDecoders`), mpv's facts, a Pictures folder that is not
  asked of `xdg-user-dir` (`picturesFolderAnswer`), and a stand-in for the
  player. Nothing an app test runs launches a program.
- `testApp` in place of `LumeoApp`: settings in a temporary file. `LumeoApp`
  without settings of its own reads and writes the desktop user's
  `client.json`.
- `fakeCore` (`test/ui/fake_core.dart`) answers every endpoint from fixtures,
  with switches for the failures a test needs.
- The player is a stand-in, `PlayerStandIn`, through `playerLayer` in
  `app_shell.dart`: the real screen needs libmpv and a GPU texture. An app test
  checks what Play asked the core for and which download the player was opened
  on (`playing(tester)`); what the player then does is the player layer's.
- Real I/O (a folder listing, a file decoded, a socket) does not advance in
  fake time. `waitForIo` waits for it; everything else is fake and costs
  nothing, including the app's own timers, which `uiTest` runs out after the
  test.

A picture over HTTP cannot be loaded in an app test: flutter test stubs
`HttpClient`, and `ArtworkImage` keeps the first client it made. What depends
on a decoded picture is tested on the widget, with the picture from a file
(`test/episode_card_test.dart`).

### Player tests

What only a real libmpv can show: a film opened, played, sought and run to its
end; mpv's keys and mouse buttons; the properties mpv is given and reports
back; the render thread and screenshots. The screen is Weston, not Xvfb: GTK 3
on X11 gives Flutter a GLX context, the media_kit plugin then finds no EGL
display to share and takes its software path, and the render thread is never
exercised. 0.1.19 shipped with every film frozen on its first frame under a
green suite on Xvfb. Weston on llvmpipe is Wayland and EGL, which is what the
application meets on a desktop.

A player test waits for mpv with `waitFor` and never waits out one of the
app's own timers: a timeout it needs to see run out is a `@visibleForTesting`
value it shortens (`openPatience`), and a setting is read back from mpv rather
than proved by waiting for its effect.

Not covered by any layer: the window itself (the absent title bar, dragging,
maximising, real fullscreen), a real GPU, and Windows. Those are checked by
hand against the built bundle.

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
  not what a screen does on its own (the rows of the downloads panel). Two
  tests on the same path are one test.
- **A regression test says what shipped.** A fix for a visible defect comes
  with a test in the lowest layer that shows it, with a comment on what
  happened.

## What is checked mechanically

`client/test/suite_test.dart`, part of `flutter test`:

- no two tests share a name (a test copied to another layer instead of moved);
- nothing but `test/ui/app.dart` builds `LumeoApp`;
- every test in `integration_test/` reaches the player.

A duplicate behaviour under two names is not caught; the rule above is.

## The 2026-09 split

The suite used to be 98 tests on Weston, over ten minutes. 61 moved to app
tests, 31 stayed on Weston, and 8 went:

| Test | Why it went |
| --- | --- |
| escape comes back from a title | covered by the same key from a fullscreen window |
| the field opens on the line the tabs stand on | alignment |
| the answers fold up with the panel instead of blinking out | an animation; the empty field on reopening moved into the Escape test |
| the downloads panel's Storage link opens Settings at Downloads | covered by Storage in the downloads panel, which now presses it twice |
| a download is paused from the panel and resumed | `downloads_panel_test.dart` checks the same |
| a season is on screen without scrolling | a proportion of the page |
| escape works while the film is still arriving | the same keys on a film that never arrives, in "a film takes the screen" |
| a back message closes the player | that is what `q` sends, in "leaving a film started from the banner" |

"Episode marks read over a real still" lost its screenshot and became a check
of the marks. The blur over an arrived still moved to the card's widget test.

Next: the fake core repeats the Go core's rules in Dart (what is next, the
watched latch). It is to return what a test sets instead, with its JSON as
fixtures the Go tests check against the real handlers (roadmap). The real core
binary cannot serve app tests: they run in fake time, and HTTP to another
process is real I/O.
