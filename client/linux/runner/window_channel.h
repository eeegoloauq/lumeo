#ifndef LUMEO_WINDOW_CHANNEL_H_
#define LUMEO_WINDOW_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Wires "dev.lumeo/window" to |window|.
//
// The window has no title bar of its own — see my_application.cc — so
// everything a title bar does (move, maximise, minimise, close) has to come
// back across a channel from the bar the client draws itself. Fullscreen is
// here for the same reason: it belongs to the toplevel window, and the player
// needs it without rebuilding the tree underneath a running mpv.
void lumeo_window_channel_init(FlBinaryMessenger* messenger, GtkWindow* window);

#endif  // LUMEO_WINDOW_CHANNEL_H_
