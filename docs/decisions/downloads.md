# Downloads and storage

## Acquisition: seed by default, never touch the router

Downloads keep seeding once complete (`LUMEO_SEED=false` turns it off): taking
from a swarm and giving nothing back is how swarms die. UPnP port mapping is
off, and stays off — changing the user's network without asking is not ours to
do, and outgoing connections plus holepunching are enough for a home client.

Upload control is a switch and two limits, all core preferences (`seed`,
`uploadLimit`, `downloadLimit`), because only the core can apply them and a
second client must not see a setting the torrent client ignores;
`LUMEO_SEED` is only the default of `seed`. Seeding off is not a hard off: a
torrent stops uploading once it has every piece its downloads asked for, and
one still fetching keeps trading with its peers, because a peer that gives
nothing back is choked and the download starves. Whoever needs uploads to
stop outright sets the upload limit low; a limit, not an off switch, is the
tool for a metered or asymmetric line. All three apply while the client runs:
the limits are the client's own `rate.Limiter`s, changed in place (every
change is at a strictly later instant than the one before, since the limiter
turns a change at the same instant with no limit into NaN tokens, which never
run out), and seeding is decided per torrent with anacrolix's
`DisallowDataUpload`, re-decided as pieces complete and as episodes of a pack
come and go, because the client's own `Seed` flag cannot change once it runs.

A pause is per download, like Remove: pausing one episode of a season pack
stops asking the swarm for that episode and leaves the torrent running for
the others, and the pack's torrent goes only when its last episode is paused
or stopped. Pausing the whole torrent for one episode would stop episodes
nobody paused.

One torrent can back several downloads. A season pack is one infohash and many
episodes, so the backend keeps a refcounted torrent per infohash and drops it
only when the last download on it goes; the bytes live where the first download
put them. So the downloads of one torrent share that directory, and freeing
one deletes its file: the directory goes with the last download that keeps
anything in it. Deleting a download's directory, as Free once did, took the
other episodes of the pack with it.

anacrolix's file reader needs a fence around it: it decides how much is
readable from the torrent's chunk map and clamps that to the caller's buffer,
but not to the end of the file it was opened on. Ask for more than is left —
`io.Copy`, an HTTP range ending at EOF — and it hands back the start of the
next file in the torrent. `boundedReader` in `internal/acquire/torrent` is that
fence, and the season-pack test is what catches its absence.

The bytes go through our own file storage (`storage.go` there), not
anacrolix's. Its v1.61.0 file storage maps each file into memory at full
length and never unmaps or closes it, even after the torrent is dropped. On
Linux that holds disk space and memory until the core stops; on Windows a file
held that way cannot be deleted, so Free failed while the app ran, and a file
set to full length on NTFS is not sparse, so writing the last piece (asked for
first) zero-filled everything before it: disk and system stalls on a large
film. Ours keeps anacrolix's layout on disk (the `.part` name until a file is
whole, the same completion database), so earlier downloads carry on, makes new
files sparse on Windows, keeps one handle per file and closes them when the
torrent goes.

The reader is not responsive: it hands over a piece only once its hash is
checked, as torrent-stream (Stremio's engine), WebTorrent and libtorrent do;
TorrServer is responsive by default. A responsive reader passes chunks on as
they land, so a piece that then fails the check has already reached the
player. Measured on mpv 0.41 with a 3-minute Matroska file, keyframes every
2 s: a 1 MiB piece of random bytes or zeros at 40 places, or one bad 16 KiB
block, made it skip at most to the next keyframe (3.4 s), and a cluster
claiming 44 MiB instead of 1.5 was ignored. A bad piece is a short glitch, not
a jump to the end of an episode; the jumps seen in real use have
another cause (roadmap). The price is the rest of one piece at the start and
on a seek into data not fetched yet. Film torrents mostly use 0.5-2 MiB pieces
(libtorrent picks 1 MiB up to 11 GB), well under a second at 20 Mbit/s; a slow
swarm or a 16 MiB piece makes it seconds.

## Nearly every source for an episode is a whole season

A provider asked for one episode answers with season packs and points at the
file inside them — for a typical series every single entry in the list is one.
So the row says so: a copy whose name carries a season and no episode is
marked with it, and choosing "a source for episode three" is understood to be
choosing the season.

Which makes the pack worth remembering. The provider marks copies that hold
the next episode too, and once one has been chosen for a series the next
episode defaults to the same one. The acquisition layer already shares a
torrent between downloads, so watching a second episode adds a file to the
copy on disk instead of starting a second copy of the season.

## Keep policy: only what was watched is freed

Two settings, both core preferences so every client frees the same things.
Keep says how long a download stays once it is watched: until then ("Until
watched"), a number of days after (`keepDays`, thirty unless set), or forever. The disk limit is a ceiling on what
downloads take; over it, watched downloads go, the longest watched first,
whatever Keep says. A download nobody finished is never freed automatically,
by either: throwing away the film someone downloaded for the train is worse
than going over a number. So a file larger than the ceiling stays until it is
watched, and the ceiling never stops a download from starting. Stremio's
2 GB cache is the other design — a streaming buffer that evicts anything —
and it would contradict "keep, resume later". The defaults, Forever and no
limit, are what the core did before the policy existed, so an update frees
nothing by itself.

Watched is the progress entry's latch with no position: a rewatch under way
is not finished. The days count from when it was finished. A download
that is playing, or stopped playing less than ten minutes ago, is left for
the next pass: a player reconnects on every seek, and the credits of an
episode that already counts as watched are still on screen. Passes run at
start, every ten minutes, and when something they look at changes; a change
of the policy itself is cleaned before the core answers it, so the Storage
list read next is the new one.

Prefetch is the policy's one addition rather than removal: once the episode
playing is on disk, the next one starts downloading, so a series goes on
without a wait even when the swarm is slow. It is on by default, as Netflix's
Smart Downloads is. Its copy is Play's, picked by the player the way Download
season picks one (only the client knows what it decodes); whether it fits is
the core's, because only the core knows what the downloads take and which of
them the limit would free. So a prefetch is a start the core may refuse (507):
it has to fit in the free disk and under the disk limit beside what the
downloads still arriving will take, and watched downloads count as room
under the limit, since over it they are what goes. A copy of unknown
size never fits. A prefetched episode nobody reaches is unwatched and stays,
like any other download; it is one episode per series, and Storage lists it.

## Storage is a bar and a list, not a ring

The Downloads section of Settings shows the disk as one horizontal bar — Lumeo's share,
everything else, free — with the numbers under it, then one row per title
with its size and a button that frees it. A ring is what a phone shows for
one ratio in a small square; a desktop settings page has the width for a bar
and needs the list under it anyway, because "free something" is a choice of
what, not a single number. The download folder is a row of its own, with
Open and Change: other tools want the files, and a path is cheap to show.
Change applies to downloads started after it; what is on disk stays where it
is, because moving a torrent under a running swarm is its own feature.
