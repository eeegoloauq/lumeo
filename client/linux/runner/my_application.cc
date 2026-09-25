#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"
#include "window_channel.h"
#include "window_state.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  // The lumeo-core shipped beside this binary; null in a build without one.
  gchar* core_path;
  // Held for the life of the process: its stdin is the pipe whose closing
  // stops it, and the process ending is what closes it.
  GSubprocess* core;
  GtkWindow* window;
  FlMethodChannel* open_channel;
  // Set once the last window has closed: an activation still queued from
  // before the name was released must not open a window in a process that is
  // shutting down.
  gboolean ending;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
  // And again here, on a window that is finally on screen. The grab at the
  // end of activate() happens while the toplevel is still unmapped — it is
  // where the Flutter template puts it — and a widget that is not mapped is
  // not what the desktop hands the keyboard to when it maps the window a
  // moment later. Without the focus on the view, no key reaches the engine at
  // all until the first click gives it one.
  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// The core an installed copy ships with, next to this binary in the bundle.
// A build from the source tree (flutter run, the UI tests) has none and talks
// to whatever core answers on the address it was built with.
static gchar* bundled_core_path() {
  g_autofree gchar* self_path = g_file_read_link("/proc/self/exe", nullptr);
  if (self_path == nullptr) {
    return nullptr;
  }
  g_autofree gchar* dir = g_path_get_dirname(self_path);
  gchar* core = g_build_filename(dir, "lumeo-core", nullptr);
  if (!g_file_test(core, G_FILE_TEST_IS_EXECUTABLE)) {
    g_free(core);
    return nullptr;
  }
  return core;
}

static void core_exited_cb(GObject* source, GAsyncResult* result, gpointer) {
  g_autoptr(GError) error = nullptr;
  if (g_subprocess_wait_check_finish(G_SUBPROCESS(source), result, &error)) {
    g_warning("lumeo-core stopped while the app was running");
  } else {
    g_warning("lumeo-core stopped: %s", error->message);
  }
}

// Starts the core as this process's child. Nothing is ever written to its
// stdin: the core stops when the pipe closes, which the kernel does when this
// process ends, kill -9 included. Our end of the pipe is close-on-exec, so no
// program started from here keeps the core alive after us.
static void start_core(MyApplication* self) {
  g_autoptr(GSubprocessLauncher) launcher =
      g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDIN_PIPE);
  g_subprocess_launcher_setenv(launcher, "LUMEO_EXIT_ON_STDIN_EOF", "1", TRUE);
  g_autoptr(GError) error = nullptr;
  self->core = g_subprocess_launcher_spawn(launcher, &error, self->core_path,
                                           nullptr);
  if (self->core == nullptr) {
    g_warning("could not start %s: %s", self->core_path, error->message);
    return;
  }
  g_subprocess_wait_async(self->core, nullptr, core_exited_cb, nullptr);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->ending) {
    return;
  }
  // A second launch lands here in the running instance, which has its one
  // window come forward instead of opening another.
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  // Cleared when the window goes, so an activation arriving between the last
  // window closing and the process ending does not present a freed one.
  self->window = window;
  g_object_add_weak_pointer(G_OBJECT(window),
                            reinterpret_cast<gpointer*>(&self->window));

  // No title bar of the desktop's making. A media application is a picture
  // edge to edge, and a grey strip above it with the application's name in it
  // is a second wordmark over the one the page already carries — which is
  // exactly what it looked like. The bar is the client's own, drawn in the
  // client's colours, at the top of the artwork rather than above it.
  //
  // Setting an (immediately hidden) title bar rather than clearing the
  // decorations outright is what keeps client-side decorations on: GTK goes on
  // drawing the resize edges, the drop shadow and the rounded corners, so the
  // window still resizes and snaps like every other one. Everything a title
  // bar does that is not decoration — move, maximise, minimise, close — comes
  // back over dev.lumeo/window.
  GtkWidget* titlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_window_set_titlebar(window, titlebar);
  gtk_widget_hide(titlebar);

  // The name is still needed even with nothing to print it: it is what the
  // window carries into the task switcher.
  gtk_window_set_title(window, "Lumeo");
  // And the icon, which the window would otherwise not have at all — the
  // desktop only knows to look for one by name, and the name is the same one
  // the .desktop file and the installed hicolor PNGs use.
  gtk_window_set_default_icon_name(APPLICATION_ID);

  // A media app opens on artwork: give it a window wide enough for a hero
  // and one full row of posters under it.
  gtk_window_set_default_size(window, 1440, 900);
  lumeo_window_state_init(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  lumeo_window_channel_init(messenger, window);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_clear_object(&self->open_channel);
  self->open_channel =
      fl_method_channel_new(messenger, "dev.lumeo/open", FL_METHOD_CODEC(codec));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::open: "Open with Lumeo", or `lumeo <file>`.
static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar*) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->ending) {
    return;
  }
  // The player plays one file: the first one on this machine's filesystem.
  g_autofree gchar* path = nullptr;
  for (gint i = 0; i < n_files && path == nullptr; i++) {
    path = g_file_get_path(files[i]);
  }
  if (self->window == nullptr) {
    // The first launch: Dart reads it from its arguments in main().
    if (path != nullptr) {
      g_strfreev(self->dart_entrypoint_arguments);
      self->dart_entrypoint_arguments = g_new0(char*, 2);
      self->dart_entrypoint_arguments[0] = g_strdup(path);
    }
    g_application_activate(application);
    return;
  }
  // A later one, forwarded here by the launch that found us running.
  gtk_window_present(self->window);
  if (path != nullptr) {
    g_autoptr(FlValue) value = fl_value_new_string(path);
    fl_method_channel_invoke_method(self->open_channel, "open", value, nullptr,
                                    nullptr, nullptr);
  }
}

// Implements GtkApplication::window_removed. The last window gone is this
// instance ending, so it gives up the application id then rather than when the
// process exits, which is only after the engine and the player are torn down.
// Until then a launch finds the name taken, hands its file over to a process
// that is past handling it, and exits: nothing comes up at all. GLib releases
// the name the same way when the application is finalized. A new instance
// started meanwhile runs its own core, which waits for this one's to finish
// its downloads and let go of the data directory.
static void my_application_window_removed(GtkApplication* application,
                                          GtkWindow* window) {
  MyApplication* self = MY_APPLICATION(application);
  GTK_APPLICATION_CLASS(my_application_parent_class)
      ->window_removed(application, window);
  if (gtk_application_get_windows(application) != nullptr) {
    return;
  }
  self->ending = TRUE;
  if (g_application_get_flags(G_APPLICATION(application)) &
      G_APPLICATION_NON_UNIQUE) {
    return;
  }
  GDBusConnection* bus =
      g_application_get_dbus_connection(G_APPLICATION(application));
  if (bus == nullptr) {  // no session bus, so no name was owned
    return;
  }
  g_autoptr(GError) error = nullptr;
  g_autoptr(GVariant) reply = g_dbus_connection_call_sync(
      bus, "org.freedesktop.DBus", "/org/freedesktop/DBus",
      "org.freedesktop.DBus", "ReleaseName",
      g_variant_new("(s)", g_application_get_application_id(
                               G_APPLICATION(application))),
      G_VARIANT_TYPE("(u)"), G_DBUS_CALL_FLAGS_NONE, -1, nullptr, &error);
  if (reply == nullptr) {
    g_warning("could not release the application id: %s", error->message);
  }
}

// Implements GApplication::startup, which runs in the primary instance only.
static void my_application_startup(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  if (self->core_path != nullptr) {
    start_core(self);
  }
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  lumeo_window_state_save();
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_pointer(&self->core_path, g_free);
  g_clear_object(&self->core);
  g_clear_object(&self->open_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  GTK_APPLICATION_CLASS(klass)->window_removed = my_application_window_removed;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->dart_entrypoint_arguments = g_new0(char*, 1);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // One instance per session when the app owns its core: a second launch
  // hands its file to the first over D-Bus and exits, so there is never a
  // second core, nor a window left talking to one that another window took
  // down. A build without a core stays non-unique, so the UI tests and
  // flutter run start beside an installed copy instead of waking it.
  gchar* core_path = bundled_core_path();
  GApplicationFlags flags = G_APPLICATION_HANDLES_OPEN;
  if (core_path == nullptr) {
    flags = static_cast<GApplicationFlags>(flags | G_APPLICATION_NON_UNIQUE);
  }
  MyApplication* self = MY_APPLICATION(g_object_new(
      my_application_get_type(), "application-id", APPLICATION_ID, "flags",
      flags, nullptr));
  self->core_path = core_path;
  return self;
}
