# The interface

## The client's look: dark, poster-first, one accent, one signature

The interface is in English, whatever the user's language: the data
in it — titles, genres, descriptions — arrives from Cinemeta in English, and a
half-translated screen where our labels are localised and the content is not
reads worse than one honest language. A translation table of our own for genre
names was tried and removed: it goes stale the moment the provider adds one.

Dark and poster-led is the genre's convention and it is followed on purpose —
this is a place where people watch films, and fighting that costs recognition
for nothing. The choices that are ours: the ground is black, and there is
exactly one accent. It is white unless the viewer picks amber, red, violet,
blue or teal under Settings → Appearance (the core's `accent` preference), because white
is what the player's own bar already is and a second colour next to it read as
a theme. Widgets read it as the theme's `primary`, never as a constant.
Waiting is Material's spinner held back 300 ms, not a line of our own: a
local core usually answers before anything would have flashed.

The ground was blue-black for most of the project's life, on the reasoning
that posters are warm and a cool ground makes them ring. What that produced
was a page reading as "the dark blue theme" rather than as absence, and a
worse second-order problem: with the ground at #0B0E14 and the first surface
at #141926, a panel was three per cent lighter than the page it sat on, which
is invisible. Every panel therefore ended up with a grey outline round it to
be seen at all — and an outline is the weakest surface there is, a rectangle
drawn with a thread. The border was the symptom; the palette was the cause.

So: black, and lightness does the lifting, because on black a shadow has
nothing to darken into. Four rungs — page, a row under the pointer, a chosen
row or a pill, a floating panel — with real distance between them, and the
blue moved off the ground onto the things standing on it, so a raised surface
stays cool and never reads as dirty grey. A visible outline is left to one
thing, a ghost button; a floating panel is edged with white at seven per cent
instead, which reads as the surface catching the light rather than as a line
drawn round it. Rows of one list are separated by a divider at half that
weight, and nothing surrounds them.

Two radii, plus one exception: six for anything pressed or lying on the page,
fourteen for anything floating above it — on black a rounded edge is what says
"on top of", where a square one reads as cut out of the page — and two for
artwork, which is a printed object whose corners are not ours to round. The
numbers 3, 4, 8 and 10 were all in use at once before this, one per call site,
and the seam between two of them is visible to somebody who cannot say why.

The ground stays black all the way down. An ambient wash — one colour taken
out of the artwork and laid under the whole page at a tenth of its strength,
the way Apple TV and Plex do — was tried and taken out: under the banner it
read as a dirty tint on a page that had been black a moment before, not as the
film's colour. The banner is finished by its own scrim instead, and a film's
banner is the whole window, so there is no page under the picture for a line
to be drawn on; its copies open in a drawer over it.

How much of a title physically exists on your disk is a number only Lumeo can
show: a stream has nothing to fill, and a library built from files you already
have is always full. It was a fill bar under every poster until watching got a
bar of its own, and two white bars on one poster read as two timelines. So the
one bar along a picture's bottom edge is how much was watched, the player's
timeline in small, and what is on disk is a corner mark: the download glyph
when all of it is here, a filling ring while it arrives. Posters and episode
cards carry the same mark (`DownloadMark`).

Type does two jobs. Plex Sans speaks, titles included: a title set in a display
face reads as decoration next to the real title cards the artwork carries, and
the artwork is the title whenever the provider drew one. Secondary lines —
year, size, speed, peers, quality — are Plex Sans too, smaller and dimmer.
They were Plex Mono, to make parsed values look parsed; small grey monospace
read as a terminal and made every panel look cheaper, and the reason for it
does not hold: Plex Sans draws all ten digits one width, so a changing number
does not jitter. Mono is left to strings someone might copy into a terminal:
the download folder, the core's address, an addon URL, commands, codec names.
Unbounded survives on one word, the wordmark, and ships as five glyphs.

Title artwork is measured before it is trusted. A logo is usually white
lettering on transparency, but some titles ship one drawn dark for a light
poster, and on our ground it disappears completely. So the mark's mean
luminance over its opaque pixels decides: below 0.18 it is filled white — the
shape is the design, only the ink changes — and anything above keeps its
colours. The line sits far below the dark-but-coloured case (a measured 0.28)
on purpose, because repainting one of those would be the worse bug.

Sizes are fixed, not scaled from the window. A wider screen should hand the
viewer more posters and more air, not larger letters — text that grows with the
window turns a desktop app into a television. The scale itself is hand-picked
rather than modular (12 / 14 / 15 / 16 / 18 / 52): every role here is pinned to
something physical — the width of a poster, the height of a control, the space
a hero leaves — and a ratio would fight all three.

The banner's height is derived, not chosen. A share of the window — it was
62% for an afternoon — is a number that happens to look right on the screen it
was picked on, and the promise this page makes is not about a share: it is
that opening a title lands you on something to choose from rather than on a
poster and a scrollbar. So the banner is what the screen has left over above
the block that has to stay visible under it — on a series the row of seasons,
the line about the current episode and a whole card of the strip; on the home
screen one entire shelf, label and posters. Every number in those blocks is
asked of the widget that draws it, so changing the episode card moves the
banner and nothing has to be re-tuned.

Two numbers stay chosen, because they cannot be derived from anything: a floor,
below which a banner stops being a picture, and a ceiling, above which the page
it heads becomes a screen with nothing on it to pick. The ceiling is what
governs a film, which has nothing under its banner at all until the list of
copies is asked for. Every hero in every design system has both bounds; what it
should not have is a percentage somebody liked.

Both are for the picture; what is written on it sets its own minimum. On a
short window the floor is less than a title, a synopsis and the buttons, and a
banner of fixed height pushed them out of its bottom and over the row under
it. So `BannerBox` is the derived height or its content, whichever is taller:
the page scrolls a little further rather than stacking controls on controls.

One accent needs a sentence saying what it means, or it spreads. It had:
the rating on a title page, the link that opens the table of copies, the link
that lengthens it, and the tab of the season being looked at were all amber,
which is four things that are not the play button and not what is on disk. On the
blue ground that was merely untidy; on black the amber carries and the page
ends up with five things shouting equally.

So the rule is a meaning rather than a count: **the accent marks what will
play, and how much of it is already here.** That is the play button, the
row of the sources drawer Play would use, and the episode selected in a season —
every one of them an answer to "what happens when I press play". A rating is a
fact and is set in plain text; a link is a link; a season is navigation and is
marked by being raised instead. The one exception is the keyboard's focus
ring, which is in the accent because it is transient and has to be findable on top of
somebody's artwork.

The result is rounded to whole device pixels, and that is not fussiness. A
height that lands inside a physical pixel is drawn with that row antialiased,
and the scrim over the artwork gets the same treatment: both end up a little
short of opaque, and what shows through the gap is the picture — one warm line
straight across the page, exactly where the banner ends. It shipped twice, and
the second attempt moved the gradient's stops, which was never where it came
from.

The bar is the window's title bar — the runner hides the desktop's — so it
cannot scroll away or hide itself on the way down the page: Close would go
with it. What it can stop doing is reading as a separate slab. It has no fill
and no edge of its own; over artwork it is nothing at all, and once the page
scrolls under it the ground arrives as a wash that fades out downwards. The
hairline under a flat panel is what the eye reads as "another thing", and a
full-bleed banner does not have a border across its top.

There is no cast list on a title page. Cinemeta gives three to five names with
no roles and no faces, which is not a credits section, and it was sitting
between the Play button and the thing the page exists for.

Shelves are dense on purpose: eight pixels between posters, no captions under
them. A poster is a title card already, and a caption under every one turns a
shelf into a table.

Hover adds only what the artwork cannot say — year and rating — and never the
title, because nearly every poster prints its own and saying it twice reads as
a mistake. The card lifts slightly instead of expanding: a Netflix-style
expansion shoves its neighbours aside, and a shelf that rearranges under the
pointer is harder to aim at, not easier to read. How much of a title is on disk
is not hover material at all; that is status, and it stays visible.

Acquisition lives in a pinned indicator rather than a block in the page. It is
a background operation, not content: given a block, it would push the catalogue
down and make the layout jump every time a download starts or finishes. When
watch progress exists, *that* goes on top as the first shelf, because a title
you are part-way through is content.

The panel it opens is grouped by what can be done, not by title: Ready to
watch (Play), Arriving (Pause), Waiting (Resume, Retry, Stop). One list sorted
by title made every row carry every button and said nothing at a glance about
whether the evening's film was here yet. The episodes of a season in the same
state are still one row, which opens into them. Stop and discard is offered
on what waits, not on what arrives: a row with bytes flowing is paused first,
so a download that is going well is never thrown away by one click beside the
pause button.

## A season is a strip, not a page

Episodes are a horizontal row of cards, the same gesture the shelves on the
home screen use. Full-width rows meant scrolling past everything to reach
episode nine, and a season of sixty made the page unusable; a strip holds the
whole season within one movement and leaves the rest of the page where it was.

Choosing and playing are two gestures, the way Plex and Apple TV split them.
A click on a card chooses its episode; a play button on the still, shown under
the pointer only, starts it (the keyboard has Enter, and one under each of
them put two on screen at once). The card used to be two controls, the
still playing and the caption choosing: nobody could tell them apart, and Tab
stopped twice on every episode.

The keyboard treats the strip as one control. The page opens with the keyboard
on the chosen card, so the arrows work without a click (a TV has nothing to
click with). Tab enters it on the chosen card only (a roving tab stop), the
arrows walk the season and on past either end into the next or previous one
(specials aside), being on a card chooses it, and Enter or Space plays it.
Up and down are Flutter's directional focus. Cards not out yet are reached but not chosen.
The strip scrolls so a whole neighbour stays in sight on either side of the
card the keyboard is on; left to Flutter's default it stopped at the very
edge, where the ring was hard to see. The ring is white, 2 px and outside the
still, so it reads over any picture.

A card answers "which episode is this" and nothing more: "17 · Title" (or
"Episode 17" when the provider's title is only that), the watched bar (white,
full once watched, as a check said less), the on-disk mark, and a date only when it means something. What it
is about belongs to the one episode being considered: its name and synopsis sit
in a block of fixed height above the strip, there even when the provider has no
synopsis, where it has room to be read and does not repeat fourteen times. Printed on every card it is noise and a
spoiler; painted over the still on hover it fights the play mark for the same
space.
The air date is there only when it means something — that the episode is not
out yet, or that it landed in the last fortnight. On an episode from 2008 the
date is trivia standing in a place where nothing needs to stand.

The page keeps exactly one current episode: the banner's button plays it and
the table under the strip is its list. Picking a card re-points both. Once
watch progress exists, "current" becomes the next episode nobody has seen
instead of the first — that is the only change it needs.

Per-episode ratings show only where the provider has them — some titles carry
one for every episode and some for none, and an empty column is worse than no
column.

## Rows scroll the way a desktop expects

A horizontal row in Flutter is fed only the horizontal part of a scroll event,
and a mouse wheel produces the vertical part — so a shelf could be dragged and
not scrolled. Making the row eat the wheel fixes that and breaks something
worse: the page stops scrolling wherever the pointer happens to rest. So the
wheel keeps belonging to the page, and sideways movement comes from the three
things that mean it — an arrow at each end on hover, shift with the wheel, and
a trackpad's own horizontal gesture.

Selecting an episode does not fetch its sources immediately. Clicking along a
season would otherwise fire one provider request per card; the list is fetched
for the episode the pointer settles on.

## Episodes that have not aired

Providers list a whole season the moment the dates are known, so half an
episode list can be things nobody can watch. Those rows stay — the date is
usually why the page was opened — but they carry the date instead of a button.
An offer to play something that does not exist is a lie the interface tells,
and it costs a click and a confusing empty source list to find out.

The same rule decides what is next. A series watched up to the latest aired
episode has no next episode until the following one is out: it leaves
"Continue watching" (Netflix, Plex and Jellyfin's Next Up do the same) and
its page opens on the episode last watched. It used to stay in the row with
the unaired episode, which pointed Play at an empty list.

## Stills are blurred until watched, by default

A still is a frame from the episode: the thumbnail for episode six is a
moment from episode six, chosen by somebody for being striking. Blurring it
until the episode is watched is the difference between an episode list one
can look at and one to squint past, so it is the default rather than an
option to discover. The placeholder a card falls back to when there is no
still is never blurred: there is nothing in it to spoil, and the episode
number on it has to stay readable.

## Settings: one page, and which choices stay on this machine

Settings is one page that scrolls, with its sections listed beside it: a press
scrolls there, and the section being read is lit as the page moves. It was a
rail of separate pages, and most visits are "where was that": a page to
scroll answers it by looking, a rail by guessing which page to open. The
downloads panel's Storage link opens it scrolled to Downloads
(`openSettings(section:)` on the shell).

Where a setting lives follows the rule `preferences.go` already had: a choice
that should follow the person to another client is a core preference (accent,
subtitles, the arrow step, when the next episode is offered, what is kept and
where downloads go), and so is anything only the core can apply (the disk,
seeding and rate limits). A fact about one machine or one screen is
`client.json`: text size (a screen and the distance to it), timeline
previews (whether this machine can afford a second decoder), where
screenshots go (a folder on this machine), and how long a finished download
stays in the panel. Reset puts back both kinds; downloads, the list and
history are not settings.

A row that does nothing is not shown. General's designed rows (language,
closing to a tray, pausing when minimised) need a translation layer, a tray
and a minimised state GTK on Wayland does not report, so General is not on
the page until one of them exists (roadmap, Application).

The Shortcuts section is read, not written: mpv's own bindings, asked of an
mpv started for the page, with ours (`ownBindings`) over them — the arrows at
the stored step among them. A key's label is mpv's comment on its binding, so
the page cannot drift from what the keys do. The arrow step is itself a
binding in our section rather than a Dart seek: the key goes to mpv as every
other key does, and mpv seeks.

Show next episode (`nextNotice`, 30 s by default) is when the next-episode
card appears before an end the file does not mark. Until it existed the card
came only at the last frame. It is an offer, not the countdown: the countdown
still starts on the held last frame, and credits marked as a chapter still
decide on their own. A file shorter than twice the notice gets the card at its
end, or a short one would carry it from its first minute.

The folder chooser is drawn by the app: the runners have none, and a native
one per platform (a portal call on Linux, `IFileDialog` on Windows) is code
nothing here can build or run. It walks this machine's folders, so Change on
the download folder is offered only when the core is on this machine.

## How the interface is checked

By running it. Every defect this client has shipped was visible in the first
minute of use and invisible to every unit test: a wordmark printed twice in the
same place, a panel clipped by the bar it hung from, a keyboard shortcut with
nothing focused to deliver it, a Backspace binding that silently took the key
away from the search field, text outside a Material picking up Flutter's
yellow-underlined fallback style, a search panel that opened against the top
of the window instead of where the field stands, and answers that blinked out
rather than folding away with the panel that held them. None of those are logic; all of them are what
the screen actually showed.

One class of them keeps coming back, and it is worth naming: the focus. Keys
are delivered by climbing from whatever holds it, so a window where the focus
has landed nowhere answers no shortcut at all, and says nothing about why.
It has cost F11 on a window nobody had clicked yet, and later back, fullscreen
and search together — the bar rebuilds its search field as pages change, and
the focus went with the widget that was thrown away. The shell therefore takes
the keyboard back whenever the page changes under it. Ctrl+F is what puts the
focus somewhere on purpose: search is one of the two things anyone comes here
to do, and the field slides along the bar as the downloads indicator beside it
grows and goes, so aiming at it with a pointer is the least reliable way in.

So `client/tool/ui-test.sh` drives the real application on a headless Weston
with a fake core behind it — no network, no binary, no swarm — and every check
in `client/integration_test/` is a defect that shipped once. One of them is
general rather than specific: it walks the render tree and fails on any text
painted in that fallback style, which catches the whole class rather than the
instance. The screen is Weston rather than Xvfb because GTK 3 on X11 gives
Flutter a GLX context, the media_kit plugin then finds no EGL display to share
and takes its software path, and the render thread is never exercised. Weston
on llvmpipe is Wayland and EGL, which is what the application meets on a
desktop.

What is not there: anything belonging to the window itself — the absent title
bar, dragging, maximising, real fullscreen. Those need a window manager, so
they are checked by hand against the built bundle.
