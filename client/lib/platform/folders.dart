import 'dart:io';

import 'package:flutter/services.dart';

import 'dirs.dart';

/// Shows a directory in whatever the desktop uses for that.
///
/// xdg-open on Linux and the Windows runner's ShellExecute rather than
/// url_launcher: one call per platform, where the plugin is four packages.
Future<void> openFolder(String path) => _open(path);

/// The Windows runner's shell calls (windows/runner/flutter_window.cpp).
const _shell = MethodChannel('dev.lumeo/shell');

Future<void> _open(String target) async {
  try {
    if (Platform.isWindows) {
      await _shell.invokeMethod<void>('open', target);
    } else {
      await Process.start('xdg-open', [
        target,
      ], mode: ProcessStartMode.detached);
    }
  } on Object catch (_) {
    // A desktop without xdg-open has nothing to open the target with, and
    // the client has nowhere useful to put that failure yet.
  }
}

/// mpv's log for the player being opened, with the previous one kept beside it.
///
/// mpv truncates its log on open and every player screen is a new mpv, while
/// the film a report is about is usually the one just closed: so the last log
/// moves aside first, and two files bound the size. Logs are state.
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

/// Where a frame grabbed out of a film goes.
///
/// mpv's own answer is the working directory of the process, which for an
/// application started from the desktop menu is wherever the session happened
/// to be standing — often `/`, which nobody can write to, and then `s` fails
/// with "Error writing screenshot!" and the frame is simply lost. The desktop
/// already answers this question for every application that produces images,
/// so it is asked rather than guessed: `xdg-user-dir` prints the configured
/// Pictures folder, under whatever name the account keeps it in.
///
/// Asked once. The answer is a process launch, and it does not change while
/// the application is running — but it is a process launch, so it is also
/// given a moment and no more, and it must never be waited for on the way to
/// playing something.
///
/// [environment] and [run] are the seam the tests use. A caller that brings
/// either is answered without the cache: the cached answer belongs to this
/// machine, and a test's does not.
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

/// Long enough for a program that prints one line, short enough that nothing
/// waiting on this is waiting on a machine where it hangs.
const _askTimeout = Duration(seconds: 2);

Future<String> _findPictures(
  Map<String, String> environment,
  Future<ProcessResult> Function(String, List<String>) run,
) async {
  // A trailing slash is a path to the filesystem and a different string to
  // the comparison below, and HOME=/home/me/ against an answer of /home/me
  // would put frames in the home directory itself.
  final home = _withoutTrailingSlash(environment['HOME'] ?? '');
  try {
    final found = await run('xdg-user-dir', ['PICTURES']).timeout(_askTimeout);
    final path = _withoutTrailingSlash((found.stdout as String).trim());
    // With no Pictures folder configured, xdg-user-dir answers with the home
    // directory itself. That is not a place to drop frames into.
    if (path.isNotEmpty && path != home) return path;
  } on Object catch (_) {
    // xdg-user-dirs is not installed on this machine, or did not answer in
    // time. The conventional path is still the conventional path.
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
