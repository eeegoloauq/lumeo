library;

import 'dart:io';

/// Where frames go: the folder chosen in Settings, else Pictures/Lumeo, else
/// empty when neither is known.
String screenshotsFolder({required String pictures, String chosen = ''}) =>
    chosen.isNotEmpty
    ? chosen
    : pictures.isEmpty
    ? ''
    : '$pictures/Lumeo';

/// An empty folder preserves mpv's current screenshot directory.
Map<String, String> screenshotProperties({
  required String title,
  required String pictures,
  String chosen = '',
}) {
  final folder = screenshotsFolder(pictures: pictures, chosen: chosen);
  return {
    if (folder.isNotEmpty) 'screenshot-dir': folder,
    // Paused frames share a timestamp; `%n` lets mpv save repeated grabs.
    'screenshot-template': '${_fileSafe(title)} %P %#01n',
  };
}

/// Escape `%` for mpv templates, and replace what the filesystem does not take
/// in a name: `/`, and on Windows `\ : * ? " < > |` too ("Mission: Impossible").
String _fileSafe(String title) {
  final safe = title
      .replaceAll('%', '%%')
      .replaceAll(Platform.isWindows ? RegExp(r'[\\/:*?"<>|]') : '/', '-')
      .trim();
  return safe.isEmpty ? 'Lumeo' : safe;
}
