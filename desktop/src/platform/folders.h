#pragma once

#include <QString>

// Where the client keeps what it writes, in the app's own folder: the XDG
// base directories on Linux; on Windows settings in %APPDATA% and the rest in
// %LOCALAPPDATA%\Lumeo, beside the core's Data. The Flutter client's, so an
// update keeps them (docs/qt-port.md).
namespace Folders {
QString config();
QString cache();
// Logs: the core's on Windows, mpv's.
QString state();
} // namespace Folders
