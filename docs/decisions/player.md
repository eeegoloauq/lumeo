# The player

## The player

libmpv renders into the widget tree, so the chrome is entirely ours — which is
the reason the client is Flutter rather than a webview, and the reason the
scrubber can carry something no other player shows: a band behind the played
position marking how much of the film exists on disk. You can see where it is
safe to jump to.

Playback waits for the backend to say there is something to open — the file is
known *and* the whole pieces at the front of it are on disk. That is what
`ready` on a download means. Neither half alone is enough: a size arrives with
the source before a single byte has been asked for, and the name of the file
arrives with the metadata, seconds later, still over nothing. Handed a file on
the strength of its name, mpv blocks on its first read, gives up when its
patience runs out — five seconds, which is what media_kit sets, and not a
number anybody should be waiting behind a swarm with — and reports a copy that
will not play. That was an episode at 3% with two peers feeding it, told across
the whole screen that it had no picture.

Each of the three parts answers for what it can see, and none of them holds the
whole clock. The core does not say ready until the beginning of the file
exists. mpv is then given mpv's own sixty seconds on a read instead of
media_kit's five, and told to reconnect rather than end the film if the
connection drops. And the screen, once mpv has actually given up on something,
keeps handing the file back for another half minute before it says so — a
stream can be dropped in the middle of being opened, and one line from mpv is
not an answer. A file that hangs rather than refuses therefore takes minutes to
be reported, which is the right way round: that is the case where something is
still being tried.

Ready is a soft admission, not a promise — the front of a file is not
everything a container needs, and in a season pack the first whole piece can be
a few kilobytes of the episode before it. So the message at the end of all that
says only what is known: this copy would not start. That it has no picture is
said only where a codec was actually named.

## The player's controls, and where each of them came from

The bar is deliberately the one every player already has, because nobody
should have to learn ours: play, the seek bar, volume, subtitles, speed and
picture, fullscreen. What is not there is as deliberate: no stop button
(closing is stopping), no skip buttons, no menu bar of every mpv property.

**The keys are mpv's.** Every press goes to mpv as a key — `keydown` on the
press, `keyup` on the release, with mpv's own auto-repeat in between — and
what it does is what mpv's default bindings say: seek by keyframes on the
arrows, frame steps on `.` and `,`, speed on `[`/`]`/`{`/`}`/Backspace, volume
on `9`/`0` and the wheel, `m`, chapters on PgUp/PgDn, loops on `l`, zoom and
pan on Alt with `+`/`-` and the arrows, subtitle delay, size and position on
`z`/`x`, `Shift+g`/`Shift+f`, `r`/`t`, and `I` for mpv's own statistics page.
libmpv starts with these off (`input-default-bindings=no` is the client API's
default), which is why they were absent: the player kept a table of a dozen
keys of its own and dropped the rest, and had fewer keys than mpv while sitting
on top of it. The bar is read back from mpv's properties — `volume`, `mute`,
`speed`, `sub-delay`, `fullscreen` — so the key and the control always agree,
and what is remembered for the next film is what mpv ended up at.

Down and up, not a `keypress` per event the keyboard sends, because the
repeat has to be mpv's: only mpv knows that a held arrow seeks again and a
held space bar pauses once — a `keypress` for every keyboard repeat was tried
for an evening and toggled pause thirty times a second. The cost is that both
travel to the core thread as commands, and a `keyup` that gets there late is
a key mpv still holds and auto-repeats after 200 ms. So nothing between the
release and mpv may wait on mpv's core (video-output.md, "No thread of
Flutter's waits on mpv").

No key is ours. The player's own actions are bindings in an mpv input
section (`ESC` → `script-message lumeo escape`, `q` → `script-message lumeo
back`, `c` → `script-message lumeo tracks`, `F11` → `cycle fullscreen`,
`MBTN_LEFT` → `cycle pause`), and the
player answers the `client-message` through a second libmpv client of its own
(`mpv_host.dart`), because media_kit does not pass those events on. mpv's
precedence then decides: the console's forced bindings win while it is open,
and a user's input.conf can rebind our actions. The same client hears the
core's shutdown, so any binding to `quit` closes the player instead of leaving
a dead picture. `f` toggles mpv's `fullscreen` property, and the window
follows it. Esc undoes one thing at a time, as mpv and the browsers do: an open
menu, then fullscreen, then the film; `q` leaves at once. A film takes the
screen when it starts, so one stray Esc used to end it.

The subtitle background (none, shadow, box) is a core preference set from the
subtitle style page. mpv 0.38 moved the box to `sub-border-style` and made
`sub-back-color` the shadow's colour; the player asks mpv whether
`sub-border-style` exists and sets whichever properties this mpv has.

One deliberate departure from raw mpv: a printable key whose character is not
ASCII and has no binding (a Russian layout's `а` on the `f` key) is sent as the
US-layout character of the same physical key. Standalone mpv has that defect
on Linux; browsers and every large player bind shortcuts to the physical key.

The pointer's position over the picture is sent to mpv (`mouse x y`, in the
video's own pixels, since the render target is the video's size), so
`cursor-centric-zoom` closes in on the cursor.

The page that lists the keys is read the same way: mpv's `input-bindings`
property carries every binding it holds with the comment its own input.conf
writes beside it, and the "Keyboard shortcuts" page under the gear prints
that, one line per command, ours included. Left off it are the
bindings with nothing to act on here — quitting, the playlist, mpv's own
window — and the media keys, which reach mpv and do what is printed on them.
A key that mpv gains or loses appears or goes without a line of ours
changing.

Every seek is exact, `hr-seek=yes`. mpv's `default` lands a relative seek
on a keyframe, and with keyframes 5–10 s apart a 5 s arrow moved 15 s, or
nothing, or a minute — read as a bug, and every streaming player seeks
exactly. Measured on an NVIDIA GPU (4K HEVC, nvdec): exact is a
68 ms median against 24 ms, p95 under 310 ms, landing within a frame instead
of 2.6 s off. An earlier delay blamed on `yes` was a blocking call on the Dart
thread, fixed since. There is no setting: nobody would choose the inexact
seek. The bar seeks by keyframes as it is dragged and exactly on release,
which is what mpv's own controller does and what makes the picture follow the
thumb.

The chrome follows the mouse and nothing else: up when the pointer moves,
gone half a second after it stops, as mpv's controller does. A key, a pause or
a seek does not bring it up, and a paused film does not keep it up; a menu
that is open or a pointer resting on the bar does.

Three of the decisions inside the bar are ours rather than inherited.

**Volume goes to 150%.** mpv amplifies past unity — its own ceiling is 130 —
and the one time anybody wants that is a film mixed so quietly the dialogue
disappears. The slider goes there.

**Fullscreen is the window's, not a route's.** media_kit can push a second
`Video` into a fullscreen route; that rebuilds the tree under a player which
is already playing, and there is a known upstream bug in exactly that path for
non-trivial trees. Asking the toplevel GTK window to go fullscreen — the call
is already in media_kit's Linux plugin — keeps this widget, this mpv instance
and this state where they are, and costs no dependency.

**A film takes the screen.** Playing left the window exactly as it was, which
on a maximised window means the desktop's own panel sits across the top of the
picture — and the key that would fix it is one nobody thinks to press once the
film is already playing. So opening a film asks the window for fullscreen, and
closing it hands the window back in the state it was taken in; that second half
is what makes taking it acceptable, and it is the half with a test on it. When
settings exist this becomes one of them, with this as the default.

That change is also why the window notifier defers: its listeners are widgets,
and both calls happen inside a frame — the screen asks as it is built and gives
back as it is unmounted. A ChangeNotifier that notifies there is a setState
against a locked tree, so `AppWindow` announces a change made during a frame at
the end of it, once, rather than every caller remembering a post-frame callback.

**The icons are Material Symbols, in white.** They were `CustomPainter`
paths because Flutter subsets the icon font and a stale subset once shipped an
empty box. Flutter 3.47.2 rebuilds the subset when the icons in the code
change (an icon added to an incremental release build was in its font,
checked), so the reason is gone, and the bar is the plain one people expect: one
button size, white icons, no colour on hover, the accent only on the progress
bar.

**The menus are the framework's.** They hung from a fixed `Positioned(right: 24, bottom: 96)` inside the
chrome. That corner was right only by coincidence — the panel happens to be
the width that makes it look aligned — and, worse, there was nothing between
the panel and the picture, so the click that dismissed a menu carried on to the
film and paused it: one gesture, a menu closed and a film stopped that nobody
asked to stop. Each of the two buttons is a `MenuAnchor` now.
`consumeOutsideTap` eats that click, the panel is tied to the button and
flipped above the bar by the menu's own layout rather than by our arithmetic,
Escape closes it, and what is inside is inside a Material and a focus scope —
which is what the next item on the list, the rows in the panel, needs before it
has anywhere to send the focus. Which menu is open is still the screen's, since
the `c` key writes to it too; the anchor is told, in one place, rather than
asked in several. Every panel, the download popover included, ends 24 px from the
window's right edge whichever button opens it (`openAtRightEdge`), so Escape
and the outside click behave the same for all of them.

**The double click is the picture's alone.** The `GestureDetector` that
pauses on a tap and goes fullscreen on a double tap wrapped the whole stack,
chrome included, and a double-tap recognizer holds the gesture arena for 300
ms after every click to see whether a second one is coming. Every button, the
scrubber and the volume waited that out before answering, while the keys —
which never enter the arena — answered at once, and two quick clicks on any
button went fullscreen. It sits on the picture layer now and nothing else,
and it is a `SerialTapGestureRecognizer` rather than onTap + onDoubleTap, so
the pause does not wait either: the first click pauses as it lands and the
second, within the interval, takes the pause back and goes fullscreen — what
every mainstream player does. mpv's own answer is that the left button does nothing
and the right one pauses, which nobody outside mpv would find.

**A held button holds the chrome.** While a mouse button is down the pointer
sends moves, not hovers: `MouseRegion.onHover`, which is what keeps the
controls up, goes quiet, and `MouseTracker` re-hit-tests every move, so a
drag along the bar that wandered above it left the band, the band said the
hand was gone, and the idle timer hid the controls under a thumb still being
dragged. One flag on the screen, from pointer down to pointer up, and the
half second starts at the release.

**Chapters are marks on the bar, not a button.** Most films have none; an
anime release has an opening and an ending. What every player that has them
does is the same and is all there is to do: a gap in the track where each one
starts, the chapter's name in the bubble over the pointer, and PgUp/PgDn,
which are mpv's already. The list to jump by is a section of the Playback
menu, under speed and picture so that those two never move, and it is not
there at all for a file with none. A button of its own on the bar would be a
bar that changes shape for one file in twenty. The marks are drawn by the
Slider's own track shape, which is the one thing that knows where the track
is and is exposed to be replaced for exactly this.

## Preview frames on the seek bar come from a second mpv

Streaming services pre-generate their previews on a server, as a sprite sheet
or an index of frames per film; there is no server here to do it. mpv's answer is `thumbfast`, a script that runs a second mpv,
seeks it to the keyframe under the pointer and passes the frame back through a
file. The player does the same with libmpv's own means: an mpv instance of its
own on the same stream (`thumbnails.dart`), a keyframe seek, and
`screenshot-raw`, the command libmpv has for handing a frame to its client. mpv
scales the frame to 480 pixels before it reaches Dart. libmpv's other way out,
the software renderer, is described in `render.h` as very slow and something
"you probably don't want to use".

The frames are made on demand and none are kept. Nothing starts until the
pointer first reaches the bar; while it moves, a newer position replaces one
still waiting; the instance goes with the film. A sprite made in advance would
mean decoding the whole file for pictures that take about 25 ms each to decode
when someone points at them.

Over a part that is not downloaded yet, the preview reads from the core like
any other reader, so the swarm fetches those bytes: a keyframe seek with no
read-ahead asks for little. Until a frame arrives, the bubble
shows the chapter and the time. The frame, the chapter and the time sit
centred over the pointer and stop at the ends of the bar.
