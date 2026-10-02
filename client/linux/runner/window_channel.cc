#include "window_channel.h"

#include <cstring>

#include "background.h"

static constexpr char kChannelName[] = "dev.lumeo/window";

// One window, one channel, for the life of the process: the channel has to
// outlive the call that made it in order to push state back, and there is
// nothing here worth a GObject of its own.
static FlMethodChannel* channel = nullptr;
static GtkWindow* the_window = nullptr;

// What the client's own title bar has to know to draw itself: whether the
// maximise button should say "restore", and whether to disappear entirely.
static FlValue* state_value(GdkWindowState state) {
  FlValue* value = fl_value_new_map();
  fl_value_set_string_take(
      value, "maximized",
      fl_value_new_bool((state & GDK_WINDOW_STATE_MAXIMIZED) != 0));
  fl_value_set_string_take(
      value, "fullscreen",
      fl_value_new_bool((state & GDK_WINDOW_STATE_FULLSCREEN) != 0));
  return value;
}

// The window's state as it stands, for the one question Dart asks on startup.
static GdkWindowState current_state() {
  GdkWindow* gdk_window =
      the_window == nullptr ? nullptr
                            : gtk_widget_get_window(GTK_WIDGET(the_window));
  return gdk_window == nullptr ? static_cast<GdkWindowState>(0)
                               : gdk_window_get_state(gdk_window);
}

static gboolean window_state_cb(GtkWidget*, GdkEventWindowState* event,
                                gpointer) {
  if (channel == nullptr) {
    return FALSE;
  }
  // From the event rather than from the window. GtkWindow keeps its own idea of
  // "maximised" and updates it in the class handler, which for a RUN_LAST
  // signal runs after this one — so gtk_window_is_maximized() here answers with
  // the state the window is leaving, and the button spent its life one click
  // behind.
  g_autoptr(FlValue) state = state_value(event->new_window_state);
  fl_method_channel_invoke_method(channel, "state", state, nullptr, nullptr,
                                  nullptr);
  return FALSE;
}

// Hands the drag to the window manager at the pointer's current position.
//
// Dart starts this once a press has turned into a drag, so a press that stays
// a press is still a click on whatever the bar has there. From here on the
// pointer belongs to the WM, which is what makes edge snapping and
// drag-to-maximise behave the way every other window on the desktop does.
static void begin_move(GtkWindow* window) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window == nullptr) {
    return;
  }
  GdkSeat* seat = gdk_display_get_default_seat(gdk_window_get_display(gdk_window));
  GdkDevice* pointer = seat == nullptr ? nullptr : gdk_seat_get_pointer(seat);
  if (pointer == nullptr) {
    return;
  }
  gint x = 0, y = 0;
  gdk_device_get_position(pointer, nullptr, &x, &y);
  gtk_window_begin_move_drag(window, GDK_BUTTON_PRIMARY, x, y, GDK_CURRENT_TIME);
}

// The window manager's own menu for the window, as a right click on any title
// bar opens it: always on top, move to another workspace, and the rest. The
// event only names the pointer and where it is: on Wayland GDK sends the
// serial of the pointer's last press with it, which is the right click that
// got us here.
static void show_window_menu(GtkWindow* window) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (gdk_window == nullptr) {
    return;
  }
  GdkSeat* seat = gdk_display_get_default_seat(gdk_window_get_display(gdk_window));
  GdkDevice* pointer = seat == nullptr ? nullptr : gdk_seat_get_pointer(seat);
  if (pointer == nullptr) {
    return;
  }
  gdouble x = 0, y = 0, x_root = 0, y_root = 0;
  gdk_window_get_device_position_double(gdk_window, pointer, &x, &y, nullptr);
  gdk_device_get_position_double(pointer, nullptr, &x_root, &y_root);
  GdkEvent* event = gdk_event_new(GDK_BUTTON_PRESS);
  event->button.window = GDK_WINDOW(g_object_ref(gdk_window));
  event->button.button = GDK_BUTTON_SECONDARY;
  event->button.time = GDK_CURRENT_TIME;
  event->button.x = x;
  event->button.y = y;
  event->button.x_root = x_root;  // what X11 places the menu by
  event->button.y_root = y_root;
  gdk_event_set_device(event, pointer);
  gdk_window_show_window_menu(gdk_window, event);
  gdk_event_free(event);
}

static void method_call_cb(FlMethodChannel*, FlMethodCall* method_call,
                           gpointer user_data) {
  GtkWindow* window = GTK_WINDOW(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "state") == 0) {
    g_autoptr(FlValue) state = state_value(current_state());
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(state));
  } else if (strcmp(method, "minimize") == 0) {
    gtk_window_iconify(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "toggleMaximize") == 0) {
    if (gtk_window_is_maximized(window)) {
      gtk_window_unmaximize(window);
    } else {
      gtk_window_maximize(window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "close") == 0) {
    gtk_window_close(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "setFullscreen") == 0) {
    if (args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_BOOL &&
        fl_value_get_bool(args)) {
      gtk_window_fullscreen(window);
    } else {
      gtk_window_unfullscreen(window);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "startDrag") == 0) {
    begin_move(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "configureBackground") == 0) {
    lumeo_background_configure(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "quit") == 0) {
    lumeo_background_quit();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "showWindowMenu") == 0) {
    show_window_menu(window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("failed to answer %s: %s", method, error->message);
  }
}

void lumeo_window_channel_init(FlBinaryMessenger* messenger,
                               GtkWindow* window) {
  the_window = window;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(messenger, kChannelName,
                                  FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb, window,
                                            nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   nullptr);
}

void lumeo_window_channel_hidden() {
  if (channel != nullptr) {
    fl_method_channel_invoke_method(channel, "hidden", nullptr, nullptr,
                                    nullptr, nullptr);
  }
}
