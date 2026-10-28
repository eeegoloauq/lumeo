# The player

## The player

libmpv renders into the scene under our own bar, so the chrome is entirely
ours — which is the reason the client is native rather than a webview, and the
reason the
scrubber can carry something no other player shows: a band behind the played
position marking how much of the film exists on disk. You can see where it is
safe to jump to.

Playback waits for the backend to say there is something to open — the file is
known *and* the whole pieces at the front of it are on disk. That is what
`ready` on a download means. Neither half alone is enough: a size arrives with
the source before a single byte has been asked for, and the name of the file
arrives with the metadata, seconds later, still over nothing. Handed a file on
the strength of its name, mpv blocks on its first read, gives up when its
patience runs out and reports a copy that will not play. That was an episode at 3% with two peers feeding it, told across
the whole screen that it had no picture.

Each of the three parts answers for what it can see, and none of them holds the
whole clock. The core does not say ready until the beginning of the file
exists. mpv then has its own sixty seconds on a read, and is told to reconnect
rather than end the film if the connection drops. And the screen, once mpv has actually given up on something,
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

Closing the window stops mpv before the process ends. The window's close
waits for the player, which saves the position, stops both mpvs and frees the
video output, then lets it go. Ending with them running crashed every close
during playback: the GPU driver's exit handlers tear down what a decoder or
the render thread still uses.

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
and what is remembered for the next film is what mpv ended up at. Shift with
the arrows is mpv's exact seek bound again without its `no-osd`: every seek
says where it landed.

Down and up, not a `keypress` per event the keyboard sends, because the
repeat has to be mpv's: only mpv knows that a held arrow seeks again and a
held space bar pauses once — a `keypress` for every keyboard repeat was tried
for an evening and toggled pause thirty times a second. The cost is that both
travel to the core thread as commands, and a `keyup` that gets there late is
a key mpv still holds and auto-repeats after 200 ms. So nothing between the
release and mpv may wait on mpv's core (video-output.md, "Nothing that draws
the interface waits on mpv").

No key is ours. The player's own actions are bindings in an mpv input
section (`ESC` → `script-message lumeo escape`, `q` → `script-message lumeo
back`, `c` → `script-message lumeo tracks`, `f`, `F11` and `MBTN_LEFT_DBL`
→ `script-message lumeo fullscreen`, `MBTN_LEFT` → `cycle pause`), and the
player answers the `client-message` it reads among mpv's events. mpv's
precedence then decides: the console's forced bindings win while it is open,
and a user's input.conf can rebind our actions. The same client hears the
core's shutdown, so any binding to `quit` closes the player instead of leaving
a dead picture. Esc undoes one thing at a time, as mpv and the browsers do: an open
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
of 2.6 s off. An earlier delay blamed on `yes` was a blocking call on the GUI
thread, fixed since. There is no setting: nobody would choose the inexact
seek. The bar seeks by keyframes as it is dragged and exactly on release,
which is what mpv's own controller does and what makes the picture follow the
thumb.

mpv's own defaults rule everything else: mpv starts with them, so no value of
ours goes stale when mpv changes its mind. Any GPU draws the defaults;
software rendering cannot, and the player suite, which runs on llvmpipe,
applies mpv's `fast` profile for that reason (`MpvItem::profile`). What is set
on top is a decision written here, not a taste.

Anime4K is offered in Picture, off by default: it sharpens lines and wipes
grain and fine texture, which some like and others call damage, and its
high-end presets need a discrete GPU at 4K. The shaders are Anime4K 4.0.1's
(`Anime4K_v4.0.zip`, MIT, sha256
`139cd282086457c5adc79caf7b75b8b825091d71c9b54958c18745fea62d7ed7`), only the
files of its high-end A, B and C presets, in `desktop/anime4k`. The doubled modes
(A+A and the like) are left out: they oversharpen on almost any source. mpv
runs them as `glsl-shaders`, so the choice is read back from mpv.

On NVIDIA (GTX 1660 Ti) the Flutter client's Anime4K turned orange into
green: mpv on GLES, the only API it could draw in inside Flutter's share
group, declared `precision mediump sampler2D`, and NVIDIA read textures at that
precision. The Qt client draws in desktop GL (video-output.md), where it is
clean.

The chrome follows the mouse and nothing else: up when the pointer moves,
gone half a second after it stops, as mpv's controller does. A key, a pause or
a seek does not bring it up, and a paused film does not keep it up; a menu
that is open or a pointer resting on the bar does.

Three of the decisions inside the bar are ours rather than inherited.

**Volume goes to 150%.** mpv amplifies past unity — its own ceiling is 130 —
and the one time anybody wants that is a film mixed so quietly the dialogue
disappears. The slider goes there.

**Fullscreen is the window's.** The window goes fullscreen and the player
stays the item it was, with its mpv and its state. The window is the one
owner of it: `f`, F11 and the double click ask the player, which asks the
window and reads it back, and mpv's own `fullscreen` flag is not used, so a
window left by the desktop's own shortcut is still what `f` toggles. Mirroring
mpv's flag and the window both ways took a stale state the compositor
reported as a window opening fullscreen for the viewer leaving fullscreen,
and the film fell out of it.

**A film takes the screen.** Playing left the window exactly as it was, which
on a maximised window means the desktop's own panel sits across the top of the
picture — and the key that would fix it is one nobody thinks to press once the
film is already playing. So opening a film asks the window for fullscreen, and
closing it hands the window back in the state it was taken in; that second half
is what makes taking it acceptable, and it is the half with a test on it. When
settings exist this becomes one of them, with this as the default.

**The icons are Material Symbols, in white:** SVGs in `desktop/icons/`, only
the ones in use, tinted by the button. The bar is the plain one people
expect: one button size, white icons, no colour on hover, the accent only on
the progress bar.

**A menu takes the click that closes it.** A menu hangs over the picture,
and the click that dismissed it used to carry on to the film and pause it: one
gesture, a menu closed and a film stopped that nobody asked to stop. A click
on the picture while a menu is open only closes the menu, and a menu's panel
and the bar's bands take every click and wheel that misses their controls.
Escape closes a menu before anything else.

**The mouse buttons are mpv's too.** Each button goes to mpv as it goes down
and up, so its bindings decide: a double click goes fullscreen, mpv's own, and
a click pauses, ours in the input section above, as every mainstream player
does; mpv's answer, the right button pausing and the left doing nothing, is
one nobody outside mpv would find. Not before there is a picture, or a click would pause a
film nobody has seen.

**A held button holds the chrome.** While a button is down the controls stay,
so a drag along the bar that wanders above it does not hide them under the
thumb still being dragged; the half second starts at the release.

**A title keeps its picture, not its sound.** The fit, Anime4K and decoding
picked while a title plays come back with its next episode: they belong to
the release (its black bars, its line art, a file the graphics decode wrong)
and to this machine's screen and graphics, so they are kept in client.json,
not in the core. Volume and speed are not: the volume follows the room and the
hour, and a series that kept last night's quiet would start quiet by day.

**A playing film keeps the screen on.** mpv's `stop-screensaver` works through
a window of mpv's own, which a render API client has none of, so the player
holds it: `SetThreadExecutionState` on Windows, and on Linux the desktop
portal's `Inhibit`, which GNOME, KDE and a sandbox all answer, rather than
each desktop's own screensaver interface. A pause lets go.

**Chapters are marks on the bar, not a button.** Most films have none; an
anime release has an opening and an ending. What every player that has them
does is the same and is all there is to do: a gap in the track where each one
starts, the chapter's name in the bubble over the pointer, and PgUp/PgDn,
which are mpv's already. The list to jump by is a section of the Playback
menu, under speed and picture so that those two never move, and it is not
there at all for a file with none. A button of its own on the bar would be a
bar that changes shape for one file in twenty. The marks are drawn by
the seek bar's own background, which is the one thing that knows where the
track is.

## Preview frames on the seek bar come from a second mpv

Streaming services pre-generate their previews on a server, as a sprite sheet
or an index of frames per film; there is no server here to do it. mpv's answer is `thumbfast`, a script that runs a second mpv,
seeks it to the keyframe under the pointer and passes the frame back through a
file. The player does the same with libmpv's own means: an mpv instance of its
own on the same stream (`FrameGrabber`, which the episode frames share), a
keyframe seek, and `screenshot-raw`, the command libmpv has for handing a frame
to its client. mpv scales the frame to 480 pixels before it reaches us. libmpv's other way out,
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

## Trailers play in the player, through the system's yt-dlp

Cinemeta names a title's trailers as YouTube ids, none per season or episode.
The core builds the watch link from an id of the right shape and passes no
link an addon wrote, so mpv is never handed a stranger's URL. mpv plays the
link through its ytdl hook, which runs yt-dlp: the client offers a trailer
only where there is one. On Linux that is the system's, which the packages
recommend with a JavaScript runtime, since yt-dlp needs one for YouTube. The
Windows bundle carries yt-dlp and Deno beside the app, and that yt-dlp updates
itself: YouTube breaks an old one within months, three times in the year to
October 2026, and the fix ships within days.

A trailer is the film's player with links in place of a download
(`Playback.urls`): mpv's keys, the bar and fullscreen are the same, and nothing
about it goes to the core. A title's trailers play in the metadata's order,
the bar numbering them, its buttons going back and on, and the episodes'
panel listing them by number; nothing ranks them, since Cinemeta gives them
no names. Its Play button does what the title's Play would. The core's
reconnect options are set on its own stream only: on YouTube's HLS, whose
segments close early, they waited out every delay, half a minute before a
trailer's first frame.

`Playback` opens the trailers one at a time rather than as mpv's playlist.
YouTube keeps some to a few countries, and one that will not open is dropped
for the next, from the list and from the page's Trailer button, where mpv's
playlist would skip it and keep offering it. Only all of them failing is a
failure: YouTube refusing them when yt-dlp says so, else yt-dlp perhaps out of
date, which is what an old one does once YouTube changes.

yt-dlp is asked for VP9 where there is one. It would take AV1 where YouTube
has both, which only recent graphics cards decode, where nearly all since
2016 decode VP9. The player takes the tallest picture there is, 4K included,
which on a 1080p screen still looks better than 1080p for its bitrate; the
banner, a muted background, no taller than it fills the banner.

A title's page also plays the first trailer that opens in its banner, muted,
three seconds after it is up, filling the banner as its artwork does (an upright one whole), under
Settings › Playback › Background trailers. It pauses while the episodes are
scrolled to and, once it has ended or the page was left
for a film, does not come back on that page. Its fullscreen button opens the
player with sound at the banner's second. That mpv keeps no log: the
player's log is the last film's, which a report is about.
