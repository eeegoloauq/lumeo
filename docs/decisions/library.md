# Library and watch progress

## Watch progress lives in the core, and "next" is decided there

The position in a film is stored by the core, not by the client that played
it. The client is one of several by design — the roadmap has a TV and a phone
on the same core — and a position that only the laptop knows is not progress,
it is a bookmark in one program. The same rule already moved preferences into
the core; this is the same rule applied to the thing preferences were the
rehearsal for.

What the Play button should open is also decided in the core, from the same
rows: the most recently touched entry if it is unfinished, otherwise the
episode after it in the catalogue's order, otherwise nothing. Not "the oldest
unfinished episode" — a half-watched pilot from a month ago must not outrank
the episode finished yesterday. Deciding it once in the core keeps every
client's item page, home shelf and player agreeing on what "next" is.

"Watched" is a latch at ninety per cent, and it does not come off by itself:
starting an episode again from the beginning is a rewatch, not an unwatching.
The client can clear it explicitly. Finishing (ninety per cent, the credits
skipped, a mark by hand) leaves no position, so a position on a watched entry
is a rewatch under way: it resumes, shows its own bar and is what Continue
watching opens.

## The library: My list and History, not a third tab for what is on disk

The first design had three places: My list, On disk and History. On disk went. A
title on disk already carries the mark on its poster wherever it is shown,
and Settings › Downloads lists every one of them with its size and a button
that frees it, which is the question somebody asking "what is on disk" has.
A third grid of the same posters would answer neither better. Files the user
had before Lumeo are a library of their own and belong on the home screen,
not here.

My list is a grid, like the search results: one list to look through, as long
as it is, in the order chosen (recently added, title without its article,
year, the viewer's score). The order is kept by this machine, not the core: it
is a way of looking at the list on one screen, as a remembered tab is. Adding
a title again keeps the date it was first added, or "recently added" would
reshuffle on every click. Under each poster is what the poster cannot say:
how far the viewer is ("3 of 10 seen", "watched") and their score; the kind
only when there is neither. The viewer's score is a star and a number, and
the catalogue's rating is only ever a bare number, so the star is what says
whose it is. It is an icon, not a character: the type is subset to Latin and
Cyrillic and a ★ in the text is an empty box.

New episodes are a shelf above the list, and ours rather than a calendar from
a service that wants an account: every episode out in the last fortnight and
not watched, of every series the viewer follows. Following is having the
series on the list or having watched any of it — the series somebody is in
the middle of are exactly the ones whose next episode they wait for, and
asking them to add each one to a list first leaves the shelf empty for
everyone who never did. Specials are left out, as they are of what is next.
One poster per series, on its latest new episode, with how many there are;
it opens the title on that episode. The design's NEW badge on each poster is
not there: the shelf is called New episodes.

History is a query over watch progress, not a log of its own: an entry that
is watched or stopped part way, the latest first, fifty at a time. Taking a
line out forgets where it was left, position included, because that is what
the line is. It is also where the viewer scores what they watched — an
episode for a series, the film otherwise; the title itself is scored on its
page, beside My list. Its still follows the spoiler rule of the season strip.

Ratings are 1 to 10, IMDb's and Trakt's scale, so a score given here means the
same thing there; a row of ten numbers rather than five stars, because half a
star has to be aimed at. Together with the IMDb ids, the list and the watched
entries they are what an import from Trakt, or an export to it, would need,
and they live in the core with progress for the same reason progress does.
The design's "Connect Trakt" is that import, and waits for it.
