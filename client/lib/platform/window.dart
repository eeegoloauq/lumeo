import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// The toplevel window, for a client that draws its own title bar: the
/// runner hides the system's (linux/runner/my_application.cc,
/// windows/runner/flutter_window.cpp), so moving, maximising, minimising and
/// closing come back over a channel. Fullscreen too, which keeps the widget
/// tree, and a running mpv in it, where it is.
class AppWindow extends ChangeNotifier {
  AppWindow._() {
    _channel.setMethodCallHandler(_onPush);
    _pull();
  }

  static final AppWindow instance = AppWindow._();

  static const _channel = MethodChannel('dev.lumeo/window');

  bool _maximized = false;
  bool _fullscreen = false;

  bool get maximized => _maximized;
  bool get fullscreen => _fullscreen;

  Future<void> minimize() => _invoke('minimize');
  Future<void> toggleMaximize() => _invoke('toggleMaximize');
  Future<void> close() => _invoke('close');

  /// Called once a press on the bar has turned into a drag: the window manager
  /// owns the pointer from here, which gives edge snapping and
  /// drag-to-maximise.
  Future<void> startDrag() => _invoke('startDrag');

  /// The window manager's menu for the window; on Wayland the only way to keep
  /// a window on top.
  Future<void> showWindowMenu() => _invoke('showWindowMenu');

  /// Quits even where closing would only send the window to the background.
  Future<void> quit() => _invoke('quit');

  /// Hands the runner the background settings and the words it shows for them
  /// (the tray's menu, the notification), which only the client can translate.
  Future<void> configureBackground({
    required bool enabled,
    required bool autostart,
    required String open,
    required String quit,
    required String running,
    required String runningBody,
  }) => _invoke('configureBackground', {
    'enabled': enabled,
    'autostart': autostart,
    'open': open,
    'quit': quit,
    'running': running,
    'runningBody': runningBody,
  });

  /// The window was closed into the background.
  Stream<void> get hidden => _hidden.stream;
  final _hidden = StreamController<void>.broadcast(sync: true);

  Future<void> setFullscreen(bool on) async {
    if (on == _fullscreen) return;
    // Moved here rather than waiting for the window-state event, so the chrome
    // leaves in the same frame as the request. The event confirms it.
    _maximizedAndFullscreen(_maximized, on);
    await _invoke('setFullscreen', on);
  }

  Future<void> toggleFullscreen() => setFullscreen(!_fullscreen);

  Future<void> _pull() async {
    final state = await _invoke('state');
    if (state is Map) _apply(state);
  }

  Future<void> _onPush(MethodCall call) async {
    if (call.method == 'state' && call.arguments is Map) {
      _apply(call.arguments as Map);
    } else if (call.method == 'hidden') {
      _hidden.add(null);
    }
  }

  void _apply(Map<dynamic, dynamic> state) => _maximizedAndFullscreen(
    state['maximized'] == true,
    state['fullscreen'] == true,
  );

  void _maximizedAndFullscreen(bool maximized, bool fullscreen) {
    if (maximized == _maximized && fullscreen == _fullscreen) return;
    _maximized = maximized;
    _fullscreen = fullscreen;
    _announce();
  }

  /// A film asks for fullscreen while its screen is built and hands it back
  /// while it is unmounted; notifying listeners then is a setState on a locked
  /// tree. So a change made during a frame is announced at its end, guarded
  /// here rather than at every call site.
  void _announce() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  /// The channel is the runner's, missing under `flutter test`; a window that
  /// cannot be asked is not an error.
  Future<Object?> _invoke(String method, [Object? argument]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, argument);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('window.$method: ${e.message}');
      return null;
    }
  }
}
