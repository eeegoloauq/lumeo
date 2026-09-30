# Subtitles and audio

## Subtitles are picked by the hash of the file, and arrive through the core

The out-of-sync subtitle is the oldest complaint in this ecosystem, and it has
one cause: a subtitle is timed to an encode, and clients ask for it by title.
So the core identifies the copy instead — the OpenSubtitles hash of the file
being played — and the provider answers with tracks made for it and says which
those are. The picker marks them, and the frame rate the rest were timed at
sits beside them, because 25 against 23.976 is the drift a viewer can predict
before pressing play.

Ranking puts language first and the hash match second. An exact English track
is not a better answer than an approximate one in the language the room reads.

The hash costs the last 64 KiB of a file that is arriving front to back, so it
is computed when the picker is first opened rather than when playback starts,
and the lookup goes ahead without it if the swarm is too slow. Watching without
subtitles must not spend a byte on this.

The file is fetched by the core and not by the player, for two reasons. Half of
what these databases hold is single-byte text from before Unicode with nothing
declaring what it is, and mojibake looks like a broken film rather than a
broken charset; deciding that once, in one place, is the difference. And the
endpoint takes an id the core minted, never an address — an endpoint that
fetched whatever it was handed would be an open proxy into the network the
core sits on, which for a home server is the whole home.

And the player fetches it from the core itself and hands mpv the file, never
the address. mpv waits on an address it is handed, and while it waits every
command after it waits too: a provider that kept silent held the switch to the
next episode for as long as the core waited on it. The core gives up on a file
once nothing of it has arrived for 5 s, well before the player's own 20 s,
since a filtered route passes the first few KB of a body and then nothing; the
player says the file did not download, and picking it again asks again.

The picker itself does not distinguish where a track came from: the ones inside
the file and the ones a database has for this copy are the same decision to
whoever is watching. So the subtitle column is a list of languages rather than
of sources — a language appears once, as the file's own track when it has one
and otherwise as the database's best copy for this file — and the rest of what
the database holds sits behind a count on the row, for the viewer whose copy
turned out to be a second out.

## Subtitles are kept with the download

Looked up at every open, an external track needed the network each time and
offline only the embedded tracks played. So once a download knows its file,
the core (`subtitles.Keeper`) fetches the best match for each wanted language
(the subtitle languages, and the language last picked for the title), by the
file's hash, once, and keeps it in the download's own extras directory,
`.lumeo-<download id>` beside its bytes, which goes with the download. The
hash costs nothing extra here: the torrent backend asks for both ends of a
file first anyway. A language no provider has is asked for again after a day;
while no provider answers at all, lookups back off from a minute to an hour.

The files are the same UTF-8 text as a fetched one, under names the core makes
up and an extension from a fixed list, never executable, and served only by
the names their index lists. `/api/v1/subtitles` lists them first, marked as
kept, and they are the whole answer when the catalog or every provider fails;
the picker says "on disk" beside them. The player lists them from disk
(`/api/v1/downloads/{id}/subtitles`, no provider asked) when it opens the file,
and once mpv has chosen, adds the kept track whose language the viewer ranks
above mpv's choice, if one is. They are not handed to mpv with the file for it
to choose: mpv ranks any external track above the file's own whatever its
language, so a kept Russian would beat the file's English for a viewer who
put English first.

## Audio and subtitles are one panel, and mpv does the choosing

One button, two columns: the soundtrack on the left, the subtitles on the
right. Whoever picks Japanese audio is about to look for English subtitles,
and the players people already know put the two next to each other for
that reason. Speed and picture stay under the other
button; they are about neither which film it is nor what language it is in.

Which track a film starts with is mpv's decision, told in mpv's own terms:
`alang` and `slang` from the language preferences, `subs-with-matching-audio`
off for the mode that wants subtitles only over a foreign soundtrack, and
`subs-fallback` off for the mode that wants none until asked. mpv already
matches `en` against `eng` and `en-US` (checked against the libmpv the client
is built on), honours the default and forced flags, and puts up a forced track
for the signs when the dialogue needs none — a copy of those rules here would
be a worse one. What mpv does not have is a name for a code: its track list
carries the tag as the muxer wrote it, so the core's language table, the one
it normalises provider codes with, is served with its aliases and the client
prints "English" where it printed `EN-US`.

The database is the other half of the same rule. When mpv has chosen no track
and the mode wanted one — "always", or "foreign" over a soundtrack in none of
the subtitle languages — the player looks the file up once the picture is on
screen and loads the best copy in a preferred language; a file with no
English track and an English copy in the database starts with subtitles, as
the mode promises. That is the one lookup made without the menu being
opened, and it is made only then: looking costs the swarm the last 64 KiB of
the file, and a viewer whose file already carries the language never pays it.

The list itself is read from mpv's `track-list`, not from media_kit's copy of
it. media_kit's current-track stream only repeats what it was told to select,
so a track mpv chose by itself never reached the menu and nothing was lit
while a subtitle was on screen; and its track model drops `external`,
`forced` and `selected`, which are the three facts the menu is built on.

Size and height are preferences the core keeps, with the languages: a line
that had to be made bigger for this screen has to be bigger for the next film
too. Timing stays with the episode, in its progress: a delay is a fact about
one copy, so it does not follow to the next episode, and coming back to this
one finds it in sync again.

## Subtitles are drawn by mpv, and they move for the bar

media_kit's default is to switch libass off, read mpv's `sub-text` property
and draw the line as a Flutter `Text`. That loses everything a styled track
carries — position, typesetting, karaoke — and turns an ASS release into a
plain caption. So `libass: true` is set explicitly and media_kit's own
subtitle layer is switched off; mpv composites into the picture, which is the
reference implementation for this, and size and position become mpv's
properties (`sub-scale`, `sub-pos`, `sub-margin-y`) rather than our text
style.

The controls exposed are size, height and timing, and on the settings page a
colour out of four and whether a styled track keeps its own look: a font
picker and a free colour picker are where subtitle settings go to become a
preferences panel. The four (white, a broadcast yellow, cream, cyan) are
mpv's `sub-color`, which reaches plain text only; "keep the file's styling"
off is `sub-ass-override=force`, for the viewer who wants our size, colour and
background on an ASS track too, signs and all. Size and height are also on
the settings page, since the core keeps them. The steps either side exist for a
screen further away than the default assumes, not to fix a bad default.

A plain-text line is drawn where and as large as the styled dialogue of a
streaming release is, converted to mpv's 720-line scale: `sub-font-size` 48
(1/15 of the picture), `sub-margin-y` 36 (1/20 above the bottom edge) and an
opaque 4 outline. A viewer sees both kinds of track on the same screen, and a plain one
drawn larger and higher reads as a mistake. The line does not move for the
bar: the bar covers it while it is up. A line kept above the bar all the time
sat twice as high as any release draws it, and one that jumps each time the
mouse moves is worse than one briefly covered; styled tracks keep their own
place either way.

The edge is one choice of three: that outline alone, a drop shadow, or a box.
The shadow comes with a 1.5 outline and an opaque, unblurred offset of 3: under
the full outline a shadow is two more pixels of the same black and cannot be
told from the outline alone, and without any outline white text is lost on a
white picture. The settings page draws its sample from the same numbers and
libass's way of sizing a font (by its win ascent plus descent, not its em),
over the backdrop of the last title watched, since an edge is judged against
a picture.
