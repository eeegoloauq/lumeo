import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/widgets/download_rows.dart';

Download _d(
  String id, {
  String state = 'active',
  String itemId = 'tt1',
  int season = 0,
  int episode = 0,
  DateTime? waitingSince,
  bool pausedByUser = false,
  String error = '',
  int total = 100,
  int completed = 50,
  int rate = 0,
  int? eta,
  int peers = 5,
  bool resolved = true,
}) => Download(
  id: id,
  itemId: itemId,
  name: id,
  state: state,
  season: season,
  episode: episode,
  waitingSince: waitingSince,
  pausedByUser: pausedByUser,
  error: error,
  resolved: resolved,
  progress: Progress(
    total: total,
    completed: completed,
    rate: rate,
    eta: eta,
    peers: peers,
  ),
);

WatchEntry _entry(int episode, {bool watched = true, int position = 0}) =>
    WatchEntry(
      season: 2,
      episode: episode,
      position: Duration(seconds: position),
      duration: const Duration(minutes: 24),
      watched: watched,
      updatedAt: DateTime(2026),
    );

void main() {
  final now = DateTime.utc(2026, 9, 25, 12);

  group('DownloadKind.of', () {
    test('sorts every state into its section', () {
      expect(DownloadKind.of(_d('a', state: 'done')), DownloadKind.ready);
      expect(DownloadKind.of(_d('a')), DownloadKind.arriving);
      expect(DownloadKind.of(_d('a', waitingSince: now)), DownloadKind.stalled);
      expect(
        DownloadKind.of(_d('a', state: 'paused', pausedByUser: true)),
        DownloadKind.paused,
      );
      expect(DownloadKind.of(_d('a', state: 'failed')), DownloadKind.failed);
      expect(
        [
          DownloadKind.stalled,
          DownloadKind.paused,
          DownloadKind.failed,
        ].map((k) => k.section).toSet(),
        {DownloadSection.waiting},
      );
    });

    test('a download the core paused on its own is not listed', () {
      expect(DownloadKind.of(_d('a', state: 'paused')), isNull);
      expect(DownloadKind.of(_d('a', state: 'mystery')), isNull);
    });
  });

  group('arrangeDownloads', () {
    test('sections come in order, and empty ones are left out', () {
      final groups = arrangeDownloads([
        _d('w', waitingSince: now),
        _d('r', state: 'done'),
      ]);
      expect(groups.map((g) => g.section), [
        DownloadSection.ready,
        DownloadSection.waiting,
      ]);
    });

    test('episodes of one season in one state are one row', () {
      final groups = arrangeDownloads([
        _d('e4', state: 'done', season: 2, episode: 4),
        _d('e3', state: 'done', season: 2, episode: 3),
        _d('e5', season: 2, episode: 5),
        _d('e6', season: 2, episode: 6),
        _d('other', state: 'done', itemId: 'tt2', season: 2, episode: 1),
        _d('s1', state: 'done', season: 1, episode: 9),
      ]);
      final ready = groups.first;
      expect(ready.section, DownloadSection.ready);
      expect(ready.rows.map((r) => r.downloads.map((d) => d.id).toList()), [
        ['e3', 'e4'],
        ['other'],
        ['s1'],
      ]);
      expect(ready.rows.first.episodes, 'S2 E3–E4');
      expect(ready.rows.first.isSeason, isTrue);
      expect(ready.count, 4, reason: 'episodes, not rows');
      final arriving = groups[1];
      expect(arriving.rows.single.episodes, 'S2 E5–E6');
    });

    test('a season split across states is a row in each', () {
      final groups = arrangeDownloads([
        _d('e1', season: 1, episode: 1, state: 'paused', pausedByUser: true),
        _d('e2', season: 1, episode: 2, waitingSince: now),
      ]);
      expect(groups.single.rows.length, 2);
      expect(groups.single.rows.map((r) => r.kind), [
        DownloadKind.paused,
        DownloadKind.stalled,
      ]);
    });

    test('films, and files that belong to no title, are never merged', () {
      final groups = arrangeDownloads([
        _d('copy1', state: 'done'),
        _d('copy2', state: 'done'),
        _d('loose1', state: 'done', itemId: '', episode: 1),
        _d('loose2', state: 'done', itemId: '', episode: 2),
      ]);
      expect(groups.single.rows.length, 4);
      expect(groups.single.rows.first.episodes, '');
    });

    test('a film says which copy it is; a season row its episodes', () {
      final film = Download.fromJson({
        'id': 'f',
        'itemId': 'tt2',
        'state': 'done',
        'release': {
          'resolution': '2160p',
          'hdr': ['DV', 'HDR10'],
        },
      });
      final plain = Download.fromJson({
        'id': 'p',
        'itemId': 'tt3',
        'state': 'done',
      });
      final rows = arrangeDownloads([
        film,
        plain,
        _d('e1', state: 'done', season: 2, episode: 3),
      ]).single.rows;
      expect(
        rows.map((r) => r.tag),
        unorderedEquals(['2160p DV', '', 'S2 E3']),
      );
    });

    test('a row and its section take the longest time left', () {
      final groups = arrangeDownloads([
        _d('a', season: 1, episode: 1, rate: 100, eta: 60),
        _d('b', season: 1, episode: 2, rate: 200, eta: 720),
        _d('film', rate: 50),
      ]);
      final arriving = groups.single;
      expect(arriving.rows.first.eta, 720);
      expect(arriving.rows.first.rate, 300);
      expect(arriving.rows.last.eta, isNull);
      expect(arriving.eta, 720);
    });
  });

  test('episode runs', () {
    expect(episodeRuns([4]), 'E4');
    expect(episodeRuns([4, 3]), 'E3–E4');
    expect(episodeRuns([1, 2, 3, 6, 8, 9]), 'E1–E3, E6, E8–E9');
  });

  group('nextToPlay', () {
    final row = arrangeDownloads([
      for (final e in [3, 4, 5])
        _d('e$e', state: 'done', season: 2, episode: e),
    ]).single.rows.single;

    test('is the first episode not watched to the end', () {
      final progress = WatchProgress(entries: [_entry(3), _entry(5)]);
      expect(nextToPlay(row, progress).id, 'e4');
    });

    test('a rewatch under way is where it resumes', () {
      final progress = WatchProgress(
        entries: [_entry(3, position: 300), _entry(4)],
      );
      expect(nextToPlay(row, progress).id, 'e3');
    });

    test('with nothing known, or everything watched, is the first', () {
      expect(nextToPlay(row, null).id, 'e3');
      final all = WatchProgress(entries: [_entry(3), _entry(4), _entry(5)]);
      expect(nextToPlay(row, all).id, 'e3');
    });
  });

  group('waitingLine', () {
    DownloadRow one(Download d) => arrangeDownloads([d]).single.rows.single;

    test('says what it waits on, and for how long in whole minutes', () {
      expect(
        waitingLine(
          one(
            _d(
              'a',
              peers: 0,
              waitingSince: now.subtract(
                const Duration(minutes: 4, seconds: 50),
              ),
            ),
          ),
          now,
        ),
        'Finding peers · 4 min',
      );
      expect(
        waitingLine(
          one(
            _d(
              'a',
              peers: 0,
              waitingSince: now.subtract(const Duration(seconds: 20)),
            ),
          ),
          now,
        ),
        'Finding peers',
        reason: 'under a minute there is nothing to count',
      );
      expect(
        waitingLine(
          one(
            _d(
              'a',
              resolved: false,
              waitingSince: now.subtract(const Duration(minutes: 75)),
            ),
          ),
          now,
        ),
        'Fetching metadata · 1 h 15 min',
      );
    });

    test('paused, and failed with the core\'s reason', () {
      expect(
        waitingLine(one(_d('a', state: 'paused', pausedByUser: true)), now),
        'Paused',
      );
      expect(
        waitingLine(one(_d('a', state: 'failed', error: 'disk full')), now),
        'disk full',
      );
      expect(waitingLine(one(_d('a', state: 'failed')), now), 'Failed');
    });
  });

  test('spokenMinutes rounds up and never says zero', () {
    expect(spokenMinutes(const Duration(seconds: 5)), '1 min');
    expect(spokenMinutes(const Duration(seconds: 61)), '2 min');
    expect(spokenMinutes(const Duration(hours: 2)), '2 h');
    expect(spokenMinutes(const Duration(minutes: 125)), '2 h 5 min');
  });
}
