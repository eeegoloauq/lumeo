import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'dirs.dart';

/// Shows a directory in whatever the desktop uses for that. Through
/// url_launcher rather than xdg-open: on Wayland GTK hands on the focus, so
/// the file manager comes to the front.
Future<void> openFolder(String path) => _open(Uri.directory(path));

Future<void> openUrl(String url) => _open(Uri.parse(url));

Future<void> _open(Uri target) async {
  try {
    await launchUrl(target);
  } on Object catch (_) {
    // A desktop with nothing registered for the target has nothing to open
    // it with, and the client has nowhere useful to put that failure yet.
  }
}

/// The Windows runner's shell calls (windows/runner/flutter_window.cpp).
const _shell = MethodChannel('dev.lumeo/shell');

/// mpv's log for the player being opened, with the previous one kept beside
/// it: mpv truncates its log on open, and a report is usually about the film
/// just closed. Two files bound the size.
String mpvLogFile({Map<String, String>? environment}) {
  final dir = stateDir(environment);
  final path = '$dir/mpv.log';
  try {
    Directory(dir).createSync(recursive: true);
    final last = File(path);
    if (last.existsSync()) last.renameSync('$dir/mpv.old.log');
  } on FileSystemException catch (_) {
    // mpv reports a log it cannot open in its own log; playback goes on.
  }
  return path;
}

/// Where a frame grabbed out of a film goes. mpv's default is the process's
/// working directory, often `/` for an app started from the menu, where the
/// screenshot fails. `xdg-user-dir` prints the configured Pictures folder.
///
/// Asked once, with a short timeout, and never waited for on the way to
/// playing. [environment] and [run] are for tests, which bypass the cache.
Future<String> picturesFolder({
  Map<String, String>? environment,
  Future<ProcessResult> Function(String, List<String>)? run,
}) {
  if (environment != null || run != null) {
    return _findPictures(
      environment ?? Platform.environment,
      run ?? Process.run,
    );
  }
  return _pictures ??= Platform.isWindows
      ? _windowsPictures()
      : _findPictures(Platform.environment, Process.run);
}

Future<String>? _pictures;

/// Puts an answer in place of asking, for tests that show the folder; null
/// asks again.
@visibleForTesting
set picturesFolderAnswer(String? answer) =>
    _pictures = answer == null ? null : Future.value(answer);

/// Long enough for a program that prints one line, short enough that nothing
/// waiting on this is waiting on a machine where it hangs.
@visibleForTesting
Duration picturesAskTimeout = const Duration(seconds: 2);

Future<String> _findPictures(
  Map<String, String> environment,
  Future<ProcessResult> Function(String, List<String>) run,
) async {
  // A trailing slash would defeat the comparison with HOME below.
  final home = _withoutTrailingSlash(environment['HOME'] ?? '');
  try {
    final found = await run('xdg-user-dir', [
      'PICTURES',
    ]).timeout(picturesAskTimeout);
    final path = _withoutTrailingSlash((found.stdout as String).trim());
    // With no Pictures folder configured, xdg-user-dir answers with home.
    if (path.isNotEmpty && path != home) return path;
  } on Object catch (_) {
    // xdg-user-dirs missing or too slow: the conventional path.
  }
  return home.isEmpty ? '' : '$home/Pictures';
}

/// The Pictures known folder, which OneDrive moves when it backs it up, so
/// `%USERPROFILE%\Pictures` is a guess where the shell has the answer.
Future<String> _windowsPictures() async {
  try {
    return await _shell.invokeMethod<String>('pictures') ?? '';
  } on PlatformException catch (_) {
    return '';
  }
}

String _withoutTrailingSlash(String path) {
  var end = path.length;
  // "/" itself is a path, not a trailing slash on a path.
  while (end > 1 && path[end - 1] == '/') {
    end--;
  }
  return path.substring(0, end);
}
