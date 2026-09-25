import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../platform/dirs.dart';
import 'frame_grabber.dart';

/// A frame from each episode on disk, for the cards metahub has no still for
/// (every season after the first, for many series). Taken once, a third of
/// the way in, and kept in the cache. An episode that is not on disk is never
/// opened for one: that would start its torrent.
class EpisodeFrames extends ChangeNotifier {
  EpisodeFrames(this._api, this._downloads, {Map<String, String>? environment})
    : directory = cacheDirectory(environment) {
    _downloads.addListener(_update);
    unawaited(_load());
  }

  final LumeoApi _api;
  final DownloadsStore _downloads;
  final String directory;

  final _known = <String>{};
  // Taken or failed this session; a failure is not retried until a restart.
  final _tried = <String>{};
  FrameGrabber? _grabber;
  // One frame at a time, from the moment one is chosen: the grabber itself
  // exists only once the token is at hand.
  bool _taking = false;
  bool _loaded = false;
  bool _disposed = false;

  File? of(String itemId, int season, int episode) {
    final name = _name(itemId, season, episode);
    return _known.contains(name) ? File('$directory/$name') : null;
  }

  @override
  void dispose() {
    _disposed = true;
    _downloads.removeListener(_update);
    _grabber?.dispose();
    super.dispose();
  }

  static String cacheDirectory([Map<String, String>? environment]) =>
      '${cacheDir(environment)}/stills';

  static String _name(String itemId, int season, int episode) =>
      '${Uri.encodeComponent(itemId)}-s${season}e$episode.jpg';

  Future<void> _load() async {
    try {
      await for (final entry in Directory(directory).list()) {
        final name = entry.uri.pathSegments.last;
        // A dot is a frame mpv was still writing when the client quit.
        if (!name.startsWith('.')) _known.add(name);
      }
    } on FileSystemException catch (_) {
      // No directory yet: no frame taken so far.
    }
    if (_disposed) return;
    _loaded = true;
    notifyListeners();
    _update();
  }

  void _update() {
    if (!_loaded || _taking || _disposed) return;
    for (final d in _downloads.all) {
      if (!d.isDone || d.episode == 0) continue;
      final name = _name(d.itemId, d.season, d.episode);
      if (_known.contains(name) || !_tried.add(name)) continue;
      _taking = true;
      unawaited(_take(d, name));
      return;
    }
  }

  Future<void> _take(Download download, String name) async {
    final headers = await _api.token.headers();
    if (_disposed) return;
    final grabber = _grabber = FrameGrabber(
      _api.streamUrl(download.id),
      headers: headers,
    );
    final part = '$directory/.$name';
    try {
      await Directory(directory).create(recursive: true);
      if (await grabber.opened &&
          await grabber.save('33', 'absolute-percent+keyframes', part)) {
        await File(part).rename('$directory/$name');
        _known.add(name);
        if (!_disposed) notifyListeners();
      }
    } on FileSystemException catch (_) {
      // A cache that cannot be written leaves the card on its number.
    } finally {
      grabber.dispose();
      _grabber = null;
      _taking = false;
      _update();
    }
  }
}
