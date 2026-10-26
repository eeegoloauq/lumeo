#pragma once

#include <QString>

// Where the client keeps what it writes, in the app's own folder: the XDG
// base directories on Linux; on Windows settings in %APPDATA% and the rest in
// %LOCALAPPDATA%\Lumeo, beside the core's Data. The paths are the earlier
// Flutter client's, so an update from it keeps them.
namespace Folders {
QString config();
QString cache();
// Logs: the core's on Windows, mpv's.
QString state();
// mpv's log for the player being opened; LUMEO_MPV_LOG names another.
QString playerLog();
} // namespace Folders
