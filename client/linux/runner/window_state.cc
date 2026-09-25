#include "window_state.h"

#include <cerrno>

// Size and maximised only, as GNOME's own applications keep them. Position is
// the compositor's (Wayland gives a client no say in it), and fullscreen
// belongs to the player, not to the home screen the application opens on.
static constexpr char kGroup[] = "window";

static int width = 0;
static int height = 0;
static gboolean maximized = FALSE;

static gchar* state_file() {
  return g_build_filename(g_get_user_state_dir(), "lumeo", "window.ini",
                          nullptr);
}

static void size_allocate_cb(GtkWidget* widget, GdkRectangle*, gpointer) {
  // The size to come back to is the free one: a maximised, snapped or
  // fullscreen window measures the screen, and restoring that as a plain
  // window leaves nothing to unmaximise to.
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  if (gdk_window == nullptr) {
    return;
  }
  GdkWindowState state = gdk_window_get_state(gdk_window);
  if ((state & (GDK_WINDOW_STATE_MAXIMIZED | GDK_WINDOW_STATE_FULLSCREEN |
                GDK_WINDOW_STATE_TILED)) == 0) {
    gtk_window_get_size(GTK_WINDOW(widget), &width, &height);
  }
}

static gboolean window_state_cb(GtkWidget*, GdkEventWindowState* event,
                                gpointer) {
  maximized = (event->new_window_state & GDK_WINDOW_STATE_MAXIMIZED) != 0;
  return FALSE;
}

void lumeo_window_state_save() {
  if (width <= 0 || height <= 0) {
    return;
  }
  g_autofree gchar* path = state_file();
  g_autofree gchar* dir = g_path_get_dirname(path);
  g_autoptr(GKeyFile) file = g_key_file_new();
  g_key_file_set_integer(file, kGroup, "width", width);
  g_key_file_set_integer(file, kGroup, "height", height);
  g_key_file_set_boolean(file, kGroup, "maximized", maximized);
  g_autoptr(GError) error = nullptr;
  if (g_mkdir_with_parents(dir, 0700) != 0 ||
      !g_key_file_save_to_file(file, path, &error)) {
    g_warning("window state not saved to %s: %s", path,
              error != nullptr ? error->message : g_strerror(errno));
  }
}

void lumeo_window_state_init(GtkWindow* window) {
  g_autofree gchar* path = state_file();
  g_autoptr(GKeyFile) file = g_key_file_new();
  if (g_key_file_load_from_file(file, path, G_KEY_FILE_NONE, nullptr)) {
    // Kept as well as applied: a window opened and closed maximised never
    // measures a free size of its own, and must not forget the old one.
    width = g_key_file_get_integer(file, kGroup, "width", nullptr);
    height = g_key_file_get_integer(file, kGroup, "height", nullptr);
    if (width > 0 && height > 0) {
      gtk_window_set_default_size(window, width, height);
    }
    if (g_key_file_get_boolean(file, kGroup, "maximized", nullptr)) {
      gtk_window_maximize(window);
    }
  }
  g_signal_connect(window, "size-allocate", G_CALLBACK(size_allocate_cb),
                   nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   nullptr);
}
