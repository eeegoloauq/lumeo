import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'frame_grabber.dart';

/// The scrubber's preview frames, from an mpv of our own on the same stream.
/// thumbfast does the same from a script, through a file and a second
/// process. Nothing starts until the pointer first reaches the bar, and a
/// newer position replaces one still waiting.
class Thumbnails {
  Thumbnails(this.url, {this.headers = const {}});

  final String url;

  /// What the core asks every request to carry.
  final Map<String, String> headers;

  /// The latest frame while the pointer is on the bar, null otherwise.
  final frame = ValueNotifier<ui.Image?>(null);

  FrameGrabber? _grabber;
  Duration? _wanted;
  // Set until the file is loaded, and for good if it fails to.
  bool _busy = true;
  bool _shown = false;
  bool _disposed = false;

  void show(Duration at) {
    if (_disposed) return;
    _shown = true;
    _wanted = at;
    if (_grabber == null) {
      final grabber = _grabber = FrameGrabber(url, headers: headers);
      unawaited(
        grabber.opened.then((opened) {
          if (!opened) return;
          _busy = false;
          _next();
        }),
      );
    }
    _next();
  }

  void hide() {
    if (_disposed) return;
    _shown = false;
    _wanted = null;
    final old = frame.value;
    frame.value = null;
    old?.dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    frame.value?.dispose();
    frame.dispose();
    _grabber?.dispose();
  }

  Future<void> _next() async {
    final at = _wanted;
    if (_busy || _disposed || at == null) return;
    _wanted = null;
    _busy = true;
    final seconds = (at.inMilliseconds / 1000).toString();
    final image = await _grabber!.frame(seconds, 'absolute+keyframes');
    _busy = false;
    if (image != null && (_disposed || !_shown)) {
      image.dispose();
    } else if (image != null) {
      final old = frame.value;
      frame.value = image;
      old?.dispose();
    }
    unawaited(_next());
  }
}
