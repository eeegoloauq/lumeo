# Decisions

Why Lumeo is built the way it is, written down so that a choice is not reopened
without its reasons. Each entry says what was rejected and why, because the
rejected option is usually the tempting one. How the code is laid out is in
[architecture.md](../architecture.md); what comes next, in
[roadmap.md](../roadmap.md).

| File | What it settles |
| --- | --- |
| [foundations.md](foundations.md) | Go core with SQLite, HTTP between client and core, Flutter with libmpv, no browser playback, the Stremio addon protocol, Cinemeta |
| [security.md](security.md) | What the core trusts, the API token, confinement, behaviour on a throttled network |
| [downloads.md](downloads.md) | Seeding and limits, season packs, what is freed and when, the storage page |
| [sources.md](sources.md) | The source table, how Play picks a copy, decoders asked of mpv |
| [subtitles.md](subtitles.md) | Subtitles by file hash, the audio and subtitle panel, libass rendering |
| [player.md](player.md) | Waiting for a playable file, the controls, keys and mouse, seek-bar previews |
| [video-output.md](video-output.md) | The patched Linux half of media_kit_video, mpv's render thread, Impeller |
| [interface.md](interface.md) | The look, the season strip, scrolling, settings, how the interface is tested |
| [library.md](library.md) | Watch progress and "next" in the core, My list, history, ratings |
| [shipping.md](shipping.md) | Packages for Fedora, Arch and Windows, the app owning its core, CI |

## Not doing

Kept here so it stays not-done: an own decoder or codec stack, a transcoding
matrix, live TV, DLNA, multi-user permissions, a plugin marketplace,
Chromecast/AirPlay, intro detection, recommendations, every platform at once.
In the client: a gallery of extra stills, a sleep timer, picture-in-picture on
GNOME Wayland (a client cannot keep its window on top there), dimming the
picture beyond the bottom gradient, episode trailers, a universe tree for film
series.
