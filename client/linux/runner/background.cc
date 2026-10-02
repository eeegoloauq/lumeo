#include "background.h"

#include <dlfcn.h>
#include <glib/gstdio.h>

#include <cerrno>
#include <string>

#include "window_channel.h"

// libayatana-appindicator, opened at run time rather than linked: the tray is
// the desktop's to offer, and stock GNOME offers none, so a machine without
// the library still runs the app and goes without the icon.
using IndicatorNew = GObject* (*)(const gchar*, const gchar*, int);
using IndicatorSetStatus = void (*)(GObject*, int);
using IndicatorSetMenu = void (*)(GObject*, GtkMenu*);
using IndicatorSetTitle = void (*)(GObject*, const gchar*);

static constexpr int kCategoryApplicationStatus = 0;
static constexpr int kStatusPassive = 0;
static constexpr int kStatusActive = 1;
static constexpr char kNotification[] = "background";

static GtkApplication* the_application = nullptr;
static GtkWindow* the_window = nullptr;
static gboolean owns_core = FALSE;
// A --background launch whose settings have not arrived yet.
static gboolean start_hidden = FALSE;
static gboolean enabled = FALSE;
static gboolean quitting = FALSE;
static std::string open_label;
static std::string quit_label;
static std::string running_title;
static std::string running_body;

static GObject* indicator = nullptr;
static IndicatorSetStatus indicator_set_status = nullptr;
static IndicatorSetMenu indicator_set_menu = nullptr;

static GObject* new_indicator() {
  void* library = nullptr;
  for (const char* name :
       {"libayatana-appindicator3.so.1", "libappindicator3.so.1"}) {
    library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (library != nullptr) {
      break;
    }
  }
  if (library == nullptr) {
    return nullptr;
  }
  auto create =
      reinterpret_cast<IndicatorNew>(dlsym(library, "app_indicator_new"));
  auto set_title = reinterpret_cast<IndicatorSetTitle>(
      dlsym(library, "app_indicator_set_title"));
  indicator_set_status = reinterpret_cast<IndicatorSetStatus>(
      dlsym(library, "app_indicator_set_status"));
  indicator_set_menu = reinterpret_cast<IndicatorSetMenu>(
      dlsym(library, "app_indicator_set_menu"));
  if (create == nullptr || set_title == nullptr ||
      indicator_set_status == nullptr || indicator_set_menu == nullptr) {
    return nullptr;
  }
  GObject* created =
      create(APPLICATION_ID, APPLICATION_ID, kCategoryApplicationStatus);
  set_title(created, "Lumeo");
  return created;
}

// Whether the icon is on screen: the library registers it with whatever
// StatusNotifierWatcher the desktop runs, and stock GNOME runs none.
static gboolean tray_shown() {
  if (indicator == nullptr) {
    return FALSE;
  }
  GDBusConnection* bus =
      g_application_get_dbus_connection(G_APPLICATION(the_application));
  if (bus == nullptr) {
    return FALSE;
  }
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "NameHasOwner",
      g_variant_new("(s)", "org.kde.StatusNotifierWatcher"),
      G_VARIANT_TYPE("(b)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr);
  gboolean owned = FALSE;
  if (reply != nullptr) {
    g_variant_get(reply, "(b)", &owned);
  }
  return owned;
}

static void open_activated(GtkMenuItem*, gpointer) { lumeo_background_show(); }

static void quit_activated(GtkMenuItem*, gpointer) { lumeo_background_quit(); }

static void set_menu() {
  GtkWidget* menu = gtk_menu_new();
  GtkWidget* open = gtk_menu_item_new_with_label(open_label.c_str());
  g_signal_connect(open, "activate", G_CALLBACK(open_activated), nullptr);
  GtkWidget* quit = gtk_menu_item_new_with_label(quit_label.c_str());
  g_signal_connect(quit, "activate", G_CALLBACK(quit_activated), nullptr);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), open);
  gtk_menu_shell_append(GTK_MENU_SHELL(menu), quit);
  gtk_widget_show_all(menu);
  indicator_set_menu(indicator, GTK_MENU(menu));
}

// The one sign of the app where there is no tray to carry its icon.
static void notify_running() {
  g_autoptr(GNotification) notification =
      g_notification_new(running_title.c_str());
  g_notification_set_body(notification, running_body.c_str());
  g_notification_set_default_action(notification, "app.show");
  g_notification_add_button(notification, quit_label.c_str(), "app.quit");
  g_application_send_notification(G_APPLICATION(the_application),
                                  kNotification, notification);
}

// Connected before Flutter's own handler, which asks the client and quits; a
// TRUE here keeps it from running.
static gboolean delete_event_cb(GtkWidget* window, GdkEvent*, gpointer) {
  if (!enabled || quitting) {
    return FALSE;
  }
  gtk_widget_hide(window);
  if (!tray_shown()) {
    notify_running();
  }
  lumeo_window_channel_hidden();
  return TRUE;
}

// An Exec value quoted as the desktop entry specification has it: inside
// double quotes, backslash before ", `, $ and \, then the backslashes doubled
// again for the string itself, and % doubled for field codes.
static std::string quoted_exec(const gchar* path) {
  std::string quoted = "\"";
  for (const gchar* c = path; *c != '\0'; c++) {
    switch (*c) {
      case '"':
      case '`':
      case '$':
        quoted += "\\\\";
        quoted += *c;
        break;
      case '\\':
        quoted += "\\\\\\\\";
        break;
      case '%':
        quoted += "%%";
        break;
      default:
        quoted += *c;
    }
  }
  return quoted + "\"";
}

// The XDG autostart entry, which GNOME, KDE and the rest read at login. It is
// written on every start, so it follows a bundle that has moved.
static void set_autostart(gboolean on) {
  g_autofree gchar* dir =
      g_build_filename(g_get_user_config_dir(), "autostart", nullptr);
  g_autofree gchar* path =
      g_build_filename(dir, APPLICATION_ID ".desktop", nullptr);
  if (!on) {
    if (g_unlink(path) != 0 && errno != ENOENT) {
      g_warning("could not remove %s: %s", path, g_strerror(errno));
    }
    return;
  }
  g_autofree gchar* self = g_file_read_link("/proc/self/exe", nullptr);
  if (self == nullptr) {
    return;
  }
  // TryExec: an entry left behind by a removed copy is skipped, not run.
  std::string entry = "[Desktop Entry]\nType=Application\nName=Lumeo\nIcon=" +
                      std::string(APPLICATION_ID) + "\nTryExec=" + self +
                      "\nExec=" + quoted_exec(self) + " --background\n";
  g_autoptr(GError) error = nullptr;
  if (g_mkdir_with_parents(dir, 0700) != 0 ||
      !g_file_set_contents(path, entry.c_str(), -1, &error)) {
    g_warning("could not write %s: %s", path,
              error != nullptr ? error->message : g_strerror(errno));
  }
}

static void show_action(GSimpleAction*, GVariant*, gpointer) {
  lumeo_background_show();
}

static void quit_action(GSimpleAction*, GVariant*, gpointer) {
  lumeo_background_quit();
}

void lumeo_background_init(GtkApplication* application, GtkWindow* window,
                           gboolean hidden, gboolean core) {
  the_application = application;
  the_window = window;
  start_hidden = hidden;
  owns_core = core;
  static const GActionEntry actions[] = {
      {"show", show_action, nullptr, nullptr, nullptr, {}},
      {"quit", quit_action, nullptr, nullptr, nullptr, {}},
  };
  g_action_map_add_action_entries(G_ACTION_MAP(application), actions,
                                  G_N_ELEMENTS(actions), nullptr);
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_event_cb),
                   nullptr);
}

static std::string text(FlValue* settings, const gchar* key) {
  FlValue* value = fl_value_lookup_string(settings, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value)
             : "";
}

static gboolean flag(FlValue* settings, const gchar* key) {
  FlValue* value = fl_value_lookup_string(settings, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

void lumeo_background_configure(FlValue* settings) {
  if (settings == nullptr || fl_value_get_type(settings) != FL_VALUE_TYPE_MAP) {
    return;
  }
  enabled = flag(settings, "enabled");
  open_label = text(settings, "open");
  quit_label = text(settings, "quit");
  running_title = text(settings, "running");
  running_body = text(settings, "runningBody");
  if (owns_core) {
    set_autostart(flag(settings, "autostart"));
  }
  if (enabled && indicator == nullptr) {
    indicator = new_indicator();
  }
  if (indicator != nullptr) {
    set_menu();
    indicator_set_status(indicator, enabled ? kStatusActive : kStatusPassive);
  }
  if (start_hidden) {
    start_hidden = FALSE;
    if (!enabled) {
      // A login entry left behind by a setting since turned off.
      lumeo_background_show();
    } else if (!tray_shown()) {
      notify_running();
    }
  }
}

void lumeo_background_show() {
  gtk_window_present(the_window);
  // A window first shown here missed the grab the first frame makes.
  gtk_widget_grab_focus(gtk_bin_get_child(GTK_BIN(the_window)));
  g_application_withdraw_notification(G_APPLICATION(the_application),
                                      kNotification);
}

void lumeo_background_quit() {
  quitting = TRUE;
  gtk_window_close(the_window);
}
