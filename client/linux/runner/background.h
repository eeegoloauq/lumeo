#ifndef LUMEO_BACKGROUND_H_
#define LUMEO_BACKGROUND_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Running with the window closed, when the client's setting asks for it:
// closing hides the window, a tray icon (where the desktop shows one) or a
// notification (where it does not) brings it back or quits, and an autostart
// entry starts the app hidden at login.
//
// |start_hidden| is a launch with --background; |owns_core| is an installed
// copy, the only one an autostart entry may point at.
void lumeo_background_init(GtkApplication* application, GtkWindow* window,
                           gboolean start_hidden, gboolean owns_core);

// Applies the client's settings: {enabled, autostart, open, quit, running,
// runningBody}, the last four being the labels in the interface's language.
void lumeo_background_configure(FlValue* settings);

// Brings the window back from the background.
void lumeo_background_show();

// Quits whether or not the window would go to the background: the close goes
// to Flutter, which lets the client save what it has before the app exits.
void lumeo_background_quit();

#endif  // LUMEO_BACKGROUND_H_
