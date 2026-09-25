import 'dart:async';

import 'package:flutter/foundation.dart';

import 'client.dart';
import 'models.dart';

/// Live download state, polled from the core.
///
/// The core deliberately does not persist progress, so the client asks for it
/// rather than being told — a poll every couple of seconds is honest for a
/// number that only ever moves while someone is looking at it.
class DownloadsStore extends ChangeNotifier {
  DownloadsStore(this._api) {
    _started = _api.started.listen(_adopt);
    refresh();
    _schedule();
  }

  /// Fast while something is moving, slow when nothing is: a poll that keeps
  /// firing every two seconds at an idle core is a wasted wake-up, and there
  /// is nothing to see between two zeroes.
  static const _activeInterval = Duration(seconds: 2);
  static const _idleInterval = Duration(seconds: 15);

  final LumeoApi _api;
  late final StreamSubscription<Download> _started;
  Timer? _timer;
  bool _disposed = false;
  // Moves with every download adopted: a poll asked before one began answers
  // without it, and must not take it back off the list.
  int _adopted = 0;

  List<Download> _downloads = const [];
  final Map<String, MediaItem> _items = {};

  List<Download> get all => _downloads;

  /// What is actually moving. A failed or stopped download is not "1
  /// downloading" with a frozen percentage.
  List<Download> get running =>
      _downloads.where((d) => d.isActive).toList(growable: false);

  /// The download of a given catalog item, if there is one. This is what puts
  /// a fill bar under a poster the user already started acquiring.
  /// How much of a title is on disk, across every download that belongs to
  /// it. A series is many downloads, and the bar under its poster is about
  /// the title, not about whichever episode happens to be first in the list.
  Progress? progressFor(String itemId) {
    var completed = 0, total = 0, count = 0;
    for (final d in _downloads) {
      if (d.itemId != itemId) continue;
      completed += d.progress.completed;
      total += d.progress.total;
      count++;
    }
    return count == 0 ? null : Progress(completed: completed, total: total);
  }

  bool isDoneFor(String itemId) {
    var any = false;
    for (final d in _downloads) {
      if (d.itemId != itemId) continue;
      if (!d.isDone) return false;
      any = true;
    }
    return any;
  }

  /// Drop a download from the list now, without waiting to be told.
  ///
  /// Stopping one is a request over HTTP and the list is a poll: between them
  /// sat up to two seconds in which the row somebody had just discarded was
  /// still sitting there, which reads as the click having missed. If the stop
  /// actually failed, the next poll puts the row back — the poll replaces this
  /// list wholesale, so nothing here can drift.
  void forget(String id) {
    final before = _downloads.length;
    _downloads = _downloads.where((d) => d.id != id).toList(growable: false);
    if (_downloads.length != before) notifyListeners();
  }

  /// Pauses a download, keeping what arrived.
  Future<void> pause(Download download) =>
      _patch(() => _api.pauseDownload(download.id));

  /// Fetches a paused download again, or retries a failed one.
  Future<void> resume(Download download) =>
      _patch(() => _api.resumeDownload(download.id));

  /// Puts the core's answer in the list at once, for the same reason [forget]
  /// does: the button pressed should change the row now, not on the next poll.
  /// A request that failed changes nothing here, and the next poll shows the
  /// state the core really has.
  Future<void> _patch(Future<Download> Function() request) async {
    final Download answer;
    try {
      answer = await request();
    } on Object catch (_) {
      return;
    }
    if (_disposed) return;
    // A poll asked before the answer must not put the old state back.
    _adopted++;
    _downloads = [for (final d in _downloads) d.id == answer.id ? answer : d];
    notifyListeners();
    // A resumed download is polled at the pace of something moving.
    _schedule();
  }

  /// A download just started, in the list at once: the poll behind the list
  /// is slow while nothing moves, and a download is at its least visible
  /// exactly when it has just begun. One the core already had (Play on a
  /// copy on disk) is updated where it is. The next poll replaces the list
  /// wholesale, so nothing here can drift.
  void _adopt(Download download) {
    if (_disposed) return;
    _adopted++;
    final known = _downloads.any((d) => d.id == download.id);
    _downloads = [
      if (!known) download,
      for (final d in _downloads) d.id == download.id ? download : d,
    ];
    notifyListeners();
    unawaited(_resolveTitles());
    // Polled at the pace of something moving from now, not after the idle
    // wait that was already running.
    _schedule();
  }

  /// The catalogue title behind a download, once it is known. A download row
  /// carries the release name, which is provenance rather than a name anyone
  /// asked for; the title comes from the item it belongs to.
  String? titleOf(Download download) => _items[download.itemId]?.title;

  /// The catalogue item behind a download, for its poster and artwork.
  MediaItem? itemOf(Download download) => _items[download.itemId];

  Future<void> _resolveTitles() async {
    var resolved = false;
    for (final d in _downloads) {
      if (d.itemId.isEmpty || _items.containsKey(d.itemId)) continue;
      try {
        _items[d.itemId] = await _api.item(d.itemId);
        resolved = true;
      } on Object catch (_) {
        // A missing title costs a line of detail, not the download.
      }
    }
    // One notification for the batch: each title otherwise rebuilds every
    // poster on screen.
    if (resolved && !_disposed) notifyListeners();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(running.isEmpty ? _idleInterval : _activeInterval, () async {
      await refresh();
      if (!_disposed) _schedule();
    });
  }

  /// Asks now rather than waiting for the next poll.
  Future<void> refresh() async {
    try {
      final asked = _adopted;
      final fresh = await _api.downloads();
      if (_disposed || asked != _adopted) return;
      final changed = _differs(_downloads, fresh);
      _downloads = fresh;
      // Only when something actually moved: every notification rebuilds the
      // visible posters, and most polls find the same numbers.
      if (changed) notifyListeners();
      unawaited(_resolveTitles());
    } on Object catch (_) {
      // A failed poll is not worth clearing the screen over: keep the last
      // known state and try again on the next tick. A core that is gone is
      // said by the screens, whose own requests fail too.
    }
  }

  static bool _differs(List<Download> before, List<Download> after) {
    if (before.length != after.length) return true;
    for (var i = 0; i < after.length; i++) {
      final a = before[i], b = after[i];
      if (a.id != b.id ||
          a.state != b.state ||
          a.ready != b.ready ||
          a.resolved != b.resolved ||
          a.progress.completed != b.progress.completed ||
          a.progress.total != b.progress.total ||
          a.progress.rate != b.progress.rate ||
          a.progress.peers != b.progress.peers ||
          a.progress.eta != b.progress.eta ||
          a.waitingSince != b.waitingSince ||
          a.pausedByUser != b.pausedByUser ||
          a.error != b.error) {
        return true;
      }
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_started.cancel());
    _timer?.cancel();
    super.dispose();
  }
}
