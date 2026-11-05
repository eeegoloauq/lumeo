# Performance

How the client keeps its memory and its frames in check, and where to look
when either grows. The core is small (about 60 MiB on the desktop) and is not
covered here. They come from a read of the client on 2026-11-05 and the
desktop's measurements of 2026-11-04: about 1 GiB PSS after two hours, at
least 450 MiB of it memory glibc had freed and kept.

## Where to look first

A change is worth a second look for cost when it adds or touches:

- an mpv option or another mpv instance;
- a page, a `Loader`, a view's `cacheBuffer`, or anything kept while hidden;
- a C++ property QML binds to, or a `model:`;
- something connected to the playback position;
- an animation, a `layer`, a `MultiEffect` or a shader;
- a decoded image.

## Memory

**mpv's buffer is ours to bound.** mpv's defaults are for streaming from the
internet: up to 150 MiB read ahead, 50 MiB kept behind and `cache-secs` of
an hour, per instance. Here the core is on the same machine or on a LAN and
reads ahead on a torrent itself, so a buffer that size buys nothing. It still
costs, because what the demuxer freed stays resident (below). Each instance
gets a time-based readahead with a byte ceiling, written down in
[player.md](player.md) with its reason.

**A high point stays.** glibc keeps the small chunks a thread freed in that
thread's arena and gives back only the top of it. Once 200 MiB of demuxer
packets have been freed, most of those pages stay in the process. The fix is
a lower high point. `malloc_trim`, `MALLOC_ARENA_MAX` and a forced garbage
collection hide where the memory went and are not used.

**Hidden is not gone.** A page in the stack, a delegate in a view's cache
buffer and a window hidden to the tray keep their images, as the decoded
copy and the GPU texture, and keep their bindings running. Keep the data in
C++ and make the page again from it. Where the viewer is and what the pages
show live in `Navigation` (`src/api/navigation.h`), so the pages go while
the window is in the background, its scene graph and graphics context with
them, and a page that leaves the stack goes. A `cacheBuffer` is about one
screen. Something kept on purpose says why in a comment, with what it costs:
Home stays under the other pages, as the page Back ends at; a title page
under another stays, since made again it would ask the providers for its
copies again, but lets go of its banner.

**Images are decoded at the size shown.** `sourceSize` is the shown size
times the device pixel ratio; the provider scales while decoding. The
512 MiB artwork cache is on disk and bounds nothing in RAM.

## Work per update

- A getter that converts (`toVariantMap`, `toVariantList`, a regex, a `QUrl`)
  runs again for every binding on every read. Keep the converted value as a
  member and change it when its source changes.
- One NOTIFY signal per property, emitted only when the value changed. A
  shared `changed` makes every binding on every property of the object run
  again. Properties worked out from one source, such as a title's link from
  its item, share that source's signal.
- A delegate's own entry in a shared map is read through a small object
  that says only when that entry changed (`DownloadMark`), not as
  `Store.map[key]`: the whole map is converted for each delegate, and every
  delegate runs again whenever any entry moves.
- A list QML shows is a model with inserts, removes and `dataChanged`. A JS
  array or a `QVariantList` as `model:` makes every delegate again whenever it
  is replaced.
- A view of cards that scrolls keeps the cards scrolled out for those
  scrolled in (`reuseItems`); making each one again cost eight times as long
  per scroll. A reused card keeps nothing its model data does not set again
  (a still that failed is remembered by its address, not as a flag), and a
  `ListView` card lets go of the keyboard when pooled, or it comes back as
  another title with the focus on it. A `GridView` whose current item follows
  the keyboard needs nothing: the current item is never pooled.
- What connects to mpv's position runs about once per video frame. It
  compares numbers; anything slower is worked out on the signal behind it
  (chapters changed, preferences changed). A clock changes once a second.
- No `Behavior` on a value that changes every frame: it starts again each
  time.

## Rendering

- Nothing animates unseen. An animation runs on the item being visible, not
  on a state flag; a stopped animation costs nothing, a paused one still
  ticks.
- A delegate in a view's cache buffer counts as visible. Make the animated
  part only in the row that shows it.
- `layer.enabled` is an offscreen texture and a render pass for each item and
  breaks batching. It does not go on something repeated in a list, such as an
  icon: an icon is tinted when it is loaded (`image://glyph`).
- An effect on a still picture, such as the blur of an unwatched episode, is
  applied once when the picture is decoded (`image://artwork/blur/`).
- Idle means no frames. With nothing playing and nothing moving,
  `QT_LOGGING_RULES=qt.scenegraph.time.renderloop=true` logs nothing.

## Measuring

- Before and after a change, the same steps on the same build: start, browse
  a fixed path, play, close, idle, repeated 5 to 10 times.
- Memory is PSS and SwapPss from `/proc/<pid>/smaps_rollup`; mpv's buffer is
  `demuxer-cache-state`; allocation stacks come from heaptrack. heaptrack
  slows every allocation, so a delay seen under it is not the app's.
- What a change frees shows first in the heap in use (`mallinfo2`, arenas
  and mmapped chunks), read from inside the process: PSS keeps what glibc
  freed and kept, and moves less and later.
- A level that stops growing across the repeats is the working set. One that
  grows with every repeat is a leak.
- NVIDIA and Wayland numbers come from a real desktop: llvmpipe in a VM does
  not show the driver's memory.
- Sanitizers find what a reading misses: use after free, overflows, undefined
  behaviour and memory nothing points to at exit. The units and app tests run
  under them in CI (the sanitize preset, CONTRIBUTING.md). They see only the
  code the tests run, and memory still referenced (an oversized cache) is no
  leak to them. A cycle shows as indirect leaks alone, such as a closure
  holding a `shared_ptr` to itself.
