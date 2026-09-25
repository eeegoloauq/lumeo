import '../../api/models.dart';

/// What the downloads panel says about one download, which decides the
/// section it is listed under and the one thing its row lets you do.
enum DownloadKind {
  /// On disk: play it.
  ready,

  /// Bytes are flowing: pause it.
  arriving,

  /// Active, and nothing has arrived for a while: resolving, no peers, or
  /// peers that send nothing.
  stalled,

  /// Paused by the viewer: resume it.
  paused,

  /// The core gave up on it: retry it.
  failed;

  DownloadSection get section => switch (this) {
    ready => DownloadSection.ready,
    arriving => DownloadSection.arriving,
    stalled || paused || failed => DownloadSection.waiting,
  };

  /// Null for what the panel does not list: a download paused because the
  /// core stopped, rather than by anybody, is the core's to pick up again.
  static DownloadKind? of(Download d) {
    if (d.locatorScheme == 'file') return null;
    if (d.isDone) return ready;
    if (d.isActive) return d.waitingSince == null ? arriving : stalled;
    if (d.isPaused) return d.pausedByUser ? paused : null;
    if (d.isFailed) return failed;
    return null;
  }
}

enum DownloadSection {
  ready('Ready to watch'),
  arriving('Arriving'),
  waiting('Waiting');

  const DownloadSection(this.title);

  final String title;
}

/// One row of the panel: a film, an episode, or the episodes of one season
/// that are in the same state.
class DownloadRow {
  DownloadRow(this.key, this.kind, this.downloads);

  /// Stable across polls, so a season opened stays open while it moves.
  final String key;
  final DownloadKind kind;

  /// In episode order; never empty.
  final List<Download> downloads;

  Download get first => downloads.first;

  /// Several episodes read as one row, which opens into them.
  bool get isSeason => downloads.length > 1;

  /// "S2 E3–E4", "S4 E18", or nothing for a film.
  String get episodes {
    if (first.episode <= 0) return '';
    return 'S${first.season} ${episodeRuns([for (final d in downloads) d.episode])}';
  }

  /// What sits beside the title: the episodes, or for a film which copy it
  /// is ("2160p DV"), the one thing that tells two copies of it apart.
  String get tag {
    if (episodes.isNotEmpty) return episodes;
    final release = first.release;
    return [
      if (release.resolution.isNotEmpty) release.resolution,
      if (release.hdr.isNotEmpty) release.hdr.first,
    ].join(' ');
  }

  /// What the whole row weighs, and how much of it is here.
  int get size => downloads.fold(0, (n, d) => n + d.progress.total);
  double get fraction {
    final completed = downloads.fold(0, (n, d) => n + d.progress.completed);
    return size <= 0 ? 0 : (completed / size).clamp(0, 1);
  }

  int get rate => downloads.fold(0, (n, d) => n + d.progress.rate);

  /// The episodes of a season arrive side by side, so the row is done when
  /// the slowest of them is. Null when none of them knows.
  int? get eta => _longest(downloads.map((d) => d.progress.eta));

  /// How long the row has been waiting: since the first of it stopped
  /// receiving.
  DateTime? get waitingSince {
    DateTime? since;
    for (final d in downloads) {
      final s = d.waitingSince;
      if (s != null && (since == null || s.isBefore(since))) since = s;
    }
    return since;
  }

  /// Why the row failed, in the core's words.
  String get error => downloads
      .map((d) => d.error)
      .firstWhere((e) => e.isNotEmpty, orElse: () => '');
}

/// A section of the panel with what is in it.
class DownloadGroup {
  DownloadGroup(this.section, this.rows);

  final DownloadSection section;
  final List<DownloadRow> rows;

  /// Downloads rather than rows: "3 ready" is episodes one can watch, and
  /// the rows are already on screen to be counted.
  int get count => rows.fold(0, (n, r) => n + r.downloads.length);

  /// When everything arriving will be here.
  int? get eta => _longest(rows.map((r) => r.eta));
}

int? _longest(Iterable<int?> etas) {
  int? longest;
  for (final e in etas) {
    if (e != null && (longest == null || e > longest)) longest = e;
  }
  return longest;
}

/// The panel's sections in their order, empty ones left out. Episodes of one
/// season in the same state are one row; a film is always a row of its own.
/// Rows keep the order the downloads came in.
List<DownloadGroup> arrangeDownloads(Iterable<Download> listed) {
  final rows = <String, DownloadRow>{};
  for (final d in listed) {
    final kind = DownloadKind.of(d);
    if (kind == null) continue;
    final key = d.episode > 0 && d.itemId.isNotEmpty
        ? '${kind.name}:${d.itemId}:${d.season}'
        : 'one:${d.id}';
    (rows[key] ??= DownloadRow(key, kind, [])).downloads.add(d);
  }
  for (final r in rows.values) {
    r.downloads.sort((a, b) => a.episode.compareTo(b.episode));
  }
  final groups = <DownloadGroup>[];
  for (final section in DownloadSection.values) {
    final inSection = [
      for (final r in rows.values)
        if (r.kind.section == section) r,
    ];
    if (inSection.isNotEmpty) groups.add(DownloadGroup(section, inSection));
  }
  return groups;
}

/// Episode numbers as runs: 3, 4, 6 is "E3–E4, E6".
String episodeRuns(List<int> episodes) {
  final sorted = episodes.toSet().toList()..sort();
  final runs = <String>[];
  var i = 0;
  while (i < sorted.length) {
    var j = i;
    while (j + 1 < sorted.length && sorted[j + 1] == sorted[j] + 1) {
      j++;
    }
    runs.add(i == j ? 'E${sorted[i]}' : 'E${sorted[i]}–E${sorted[j]}');
    i = j + 1;
  }
  return runs.join(', ');
}

/// The episode of a finished row that Play opens: the first one not watched
/// to the end, a rewatch under way included. When every one of them is, or
/// what was watched is not known yet, the first.
Download nextToPlay(DownloadRow row, WatchProgress? progress) {
  if (progress == null) return row.first;
  for (final d in row.downloads) {
    final entry = progress.entry(d.season, d.episode);
    if (entry == null || !entry.watched || entry.position > Duration.zero) {
      return d;
    }
  }
  return row.first;
}

/// A span of time as the panel says it: "12 min", "1 h 5 min", "2 h".
/// Rounded up, so something a few seconds away is never "0 min".
String spokenMinutes(Duration d) {
  final minutes = d.inSeconds <= 60 ? 1 : (d.inSeconds / 60).ceil();
  if (minutes < 60) return '$minutes min';
  final rest = minutes % 60;
  return rest == 0 ? '${minutes ~/ 60} h' : '${minutes ~/ 60} h $rest min';
}

/// The line under a row that is waiting: what it waits on and for how long,
/// "Paused", or the reason it failed.
String waitingLine(DownloadRow row, DateTime now) {
  switch (row.kind) {
    case DownloadKind.paused:
      return 'Paused';
    case DownloadKind.failed:
      return row.error.isEmpty ? 'Failed' : row.error;
    case DownloadKind.stalled:
      final d = row.first;
      final what = d.progress.peers == 0
          ? 'Finding peers'
          : !d.resolved
          ? 'Fetching metadata'
          : 'Peers not sending';
      final since = row.waitingSince;
      // Under a minute, a number would only say that the clock is running.
      if (since == null || now.difference(since) < const Duration(minutes: 1)) {
        return what;
      }
      // Whole minutes waited, not rounded up: "1 min" after 61 seconds.
      final waited = Duration(minutes: now.difference(since).inMinutes);
      return '$what · ${spokenMinutes(waited)}';
    case DownloadKind.ready || DownloadKind.arriving:
      return '';
  }
}
