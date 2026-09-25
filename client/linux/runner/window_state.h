#ifndef RUNNER_WINDOW_STATE_H_
#define RUNNER_WINDOW_STATE_H_

#include <gtk/gtk.h>

// Opens the window at the size it was closed at, maximised if it was, and
// tracks both from then on. Call before the window is first shown.
void lumeo_window_state_init(GtkWindow* window);

// Writes what lumeo_window_state_init tracked. Called from the application's
// shutdown: Flutter quits the application on close without destroying the
// window, so the window's own signals never see the end.
void lumeo_window_state_save();

#endif  // RUNNER_WINDOW_STATE_H_
