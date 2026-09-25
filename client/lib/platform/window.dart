import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// The toplevel window, for a client that draws its own title bar.
///
/// The runner hides the one the system would have drawn
/// (linux/runner/my_application.cc, windows/runner/flutter_window.cpp), so
/// moving, maximising, minimising and closing have to come back over a
/// channel. Fullscreen lives here for a different reason: it belongs to the
/// window either way, and asking for it this way keeps the widget tree — and a
/// running mpv inside it — exactly where it is.
///
/// A [ChangeNotifier] rather than a set of futures, because two places draw
/// from the same state: the bar's maximise button, and every piece of chrome
/// that has to get out of the way in fullscreen.
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

  /// Called once a press on the bar has turned into a drag: from here the
  /// window manager owns the pointer, which is what makes edge snapping and
  /// drag-to-maximise work like they do for every other window.
  Future<void> startDrag() => _invoke('startDrag');

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

  /// Every listener here is a widget, and the two calls that matter arrive from
  /// inside a frame: a film asks for the screen while its screen is being
  /// built, and hands it back while that screen is being unmounted. Notifying
  /// there is a setState against a locked tree, which the framework rejects
  /// outright — so a change made during a frame is announced at the end of it.
  /// One guard here rather than a post-frame callback at every call site: the
  /// next caller would not know it needed one.
  void _announce() {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifyListeners();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
  }

  /// The channel is the runner's, so it is missing under `flutter test` and
  /// under any host that is not one of our runners. A window that cannot be
  /// asked is not an error worth showing anybody.
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
