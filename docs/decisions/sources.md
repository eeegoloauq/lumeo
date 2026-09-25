# Sources and what Play picks

## The source list is a table, and it is the product

Every addon client shows sources as a wall of truncated file names in a narrow
panel. Ours is a table across the width of the window because that is what the
release parser exists for: quality, kind, audio languages, size, swarm and
tracker in columns you can compare down.

Two rules hold it together. Every fact appears in exactly one column and
exactly once — the resolution is not repeated inside a summary, which is what
made the first attempt unreadable. And the noisy remainder — codec, bit depth,
audio layout, group, the release name itself — waits until a row is the one
being looked at.

The tracker and the languages come from the provider, not from the name: an
aggregator is the only thing that knows which of its trackers answered, and the
flags it prints are better evidence than guessing from a title. They are every
language the copy carries, soundtrack and subtitles in one list — a
Crunchyroll rip with Japanese audio is flagged English, Russian, Spanish — so
they say a language is there, never that it is spoken.
Both were being thrown away with the rest of the text under the first line.

Six rows show by default. Enough to see there is a choice, few enough that the
list stays a detail of the page rather than the page itself.

## What Play picks, and where the preference for it lives

Ranking health before resolution is the first rule: the sharpest copy in a
list is often a remux nobody seeds, and starting it means watching a stalled
bar. A source with a swarm therefore outranks one without, and only inside
those groups does sharper win. This is what makes "Play needs no decision"
true rather than a slogan.

Between health and resolution comes language: a copy carrying one of the
viewer's subtitle or audio languages, by the provider's flags or a "Multi
Subs" in its name, goes ahead of one that does not. A 1080p raw without
subtitles is worse than a 720p copy with them. The flags cannot tell a dub
from a subtitle track, so the rule asks only whether the language is there;
it never overrides health, because a copy that stalls is not watchable in any
language.

The ranking only decides among copies the library has not chosen yet. Ahead of
it the core puts a copy already on disk (finished before one still arriving),
then a copy from the pack of the one started last for this title — the
provider's `bingeGroup`, recorded per title whenever a download starts, the
way Stremio continues a series from the same release. Both are the core's
because clients share the library: the pick made on one machine is the file on
disk for the next. The client used to hold the pack in a page's state, and
leaving the page gave the ranking's best again, passing a finished download
over for a fresh one.

The tracks picked in the player go into the same record, for the whole title
rather than the episode, as a language and a title: mpv's ids are per file,
and the title is what tells "English Full" from "English Honorifics". Only the
viewer's picks are kept, and whose a change is is told by its cause, not its
time (`TrackChanges` in `client/lib/ui/player/tracks.dart`): mpv reports
property changes in no fixed order, and its own pick at load arrived after the
first picture as often as not.

One thing the core cannot rank by is the machine that will play the result: the
same list is served to every client, and only the client knows what its mpv can
decode. So that one gate lives in the client — a copy this machine cannot decode
is not what Play starts, however well the core ranked it — and it is a gate, not
a filter: the row stays in the table, marked, because somebody who installs the
missing package should find it where they left it.

Which knobs belong to whom is the part worth writing down. A tracker name —
1337x, rutor, yts — is an addon's vocabulary, not ours; modelling it in our
settings would hardcode us to one addon and break the day someone points us at
another. An addon that takes configuration keeps it in its own URL, and the
addon list takes the whole URL, so choosing providers and excluding cam rips
is already possible and belongs there: the addon's own site hands back a URL
that is pasted into the same field that installs one. We never draw a form
for somebody else's fields; they change without us. A Configure button that
opened that site from the Sources page was dropped in 0.1.62: the site is one
paste away anyway, and the button was one more thing per row.

A fresh database starts with Cinemeta and OpenSubtitles and no source addon.
Which sources somebody plays from is their choice, not a
default a public repository ships; until one is added, Play says "No source
addons" and leads to the Sources page instead of claiming there are no copies.
Before 0.1.62 a fresh database started with Torrentio.

What belongs to us is everything expressed in terms our own parser produces:
resolution ceiling, minimum swarm, size limits, language. Those work for any
provider, including local files and HTTP, which is the whole point of the
Locator abstraction.

Writing our own indexer instead of speaking the addon protocol stays out of
scope: an aggregator across trackers is scrapers that break weekly, and the
roadmap already carries the question of whether addon gaps ever justify it.

Download season is Play's choice made for each released episode, one after
another, by the client: the copy a press of Play would start, which only the
client can pick because only it knows what this machine decodes. One at a
time because a provider asked for seventeen lists at once answers 403. A
film's Download is the same choice without opening the player.

## What is missing is asked of mpv, not guessed from the distribution

A film that will not play because nothing here decodes HEVC used to be
answered with a paragraph about Fedora and openSUSE shipping libavcodec with
the patented decoders taken out. It is true of those two, and it was printed
on every distribution, unverified — on a machine with a full ffmpeg it sent
somebody to install a package they already had, for a failure that was really
a broken copy.

mpv knows. `decoder-list` is a property, and reading it turns the guess into a
fact: the decoder is missing, or it is there and the copy is the problem, or
mpv could not be asked and nothing about codecs gets claimed at all. The name
of the package to install is the only part that stays distribution-specific,
and that comes from `/etc/os-release` — Fedora and openSUSE have an answer,
everywhere else says nothing rather than inventing one, because "install
codecs" is not an instruction.

And it is asked before anything is chosen, not after something failed. The
list is read once when the application opens, from a libmpv handle with no
file and no window, and it is what the sources drawer marks its rows with: a
copy whose name says hevc, on a machine whose mpv has no hevc, is a black
screen, and saying so in the row is worth more than saying it over the black
screen twenty seconds into a download. Play does not pick a marked row.

The names have to be translated, because a release calls it x265 and mpv calls
it hevc, and there is no canonical table between the two — FFmpeg knows its own
codec ids and nothing about what a scene group writes in a filename. So ours is
one table in `client/lib/platform/decoders.dart`, with tests, and a name it
does not know means *unknown*, never *unsupported*. It is a claim about the
name of a copy rather than about the copy: the file itself is not on disk yet,
and nobody — not us, not Stremio, not the addon — knows what is really in it
until it arrives.

Which half of a film a failed decoder took is asked the same way. mpv words
both failures identically ("Failed to initialize a decoder for codec 'x'"), so
the answer comes from the file's own `track-list`, where the track that failed
is still listed with its codec and its type. A missing picture is a message
over a black screen; missing sound is a line over a film that is playing, and
a mark in the bar where the volume control would be — it used to be neither,
because the line was only shown when a picture was already up and the failure
arrives before the first frame.
