import 'dart:io';

import 'package:flutter/services.dart';

/// The file the desktop asked us to open (`Exec=lumeo %F`), if any.
String? fileToOpen(List<String> args) {
  for (final arg in args) {
    if (FileSystemEntity.isFileSync(arg)) return File(arg).absolute.path;
  }
  return null;
}

/// Files opened while the app is already running. The app is one instance: a
/// later "Open with Lumeo" hands its file to this one and exits
/// (linux/runner/my_application.cc, windows/runner/main.cpp).
///
/// The returned function stops listening, unless a later call has taken the
/// channel since: a shell replaced by another is disposed after the new one
/// has started listening.
void Function() onFileOpened(void Function(String path) handler) {
  Future<void> listener(MethodCall call) async {
    if (call.method == 'open' && call.arguments is String) {
      handler(call.arguments as String);
    }
  }

  _opened.setMethodCallHandler(listener);
  _listener = listener;
  return () {
    if (!identical(_listener, listener)) return;
    _opened.setMethodCallHandler(null);
    _listener = null;
  };
}

const _opened = MethodChannel('dev.lumeo/open');
Object? _listener;
