import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/screens/item_screen.dart';

void main() {
  WatchEntry entry(
    int season,
    int episode,
    String at, {
    bool watched = false,
  }) => WatchEntry(
    season: season,
    episode: episode,
    position: const Duration(minutes: 20),
    duration: const Duration(minutes: 24),
    watched: watched,
    updatedAt: DateTime.parse(at),
  );

  test('the episode to play next is the one the page opens on', () {
    final progress = WatchProgress(
      entries: [entry(1, 1, '2026-09-01T20:00:00Z', watched: true)],
      next: entry(1, 2, '2026-09-01T20:00:00Z'),
    );
    expect(openingEpisode(progress)?.episode, 2);
  });

  test('a series that has been caught up with opens where it was left', () {
    // The regression this is written against: the core answers next: null
    // once the last aired episode is watched and the next one has not aired,
    // and the page read that as "nothing at all" and opened at S01E01 — four
    // seasons behind, with Play pointed at the pilot.
    final progress = WatchProgress(
      entries: [
        entry(1, 1, '2026-01-01T20:00:00Z', watched: true),
        entry(4, 12, '2026-09-20T22:00:00Z', watched: true),
        entry(4, 11, '2026-09-19T22:00:00Z', watched: true),
      ],
    );
    final opensAt = openingEpisode(progress);
    expect(opensAt?.season, 4);
    expect(opensAt?.episode, 12);
  });

  test('a title nobody has watched opens at the beginning', () {
    expect(openingEpisode(const WatchProgress(entries: [])), isNull);
  });

  group('pageEpisode', () {
    final now = DateTime.now().toUtc();
    Episode episode(int season, int number, int days) => Episode(
      season: season,
      number: number,
      released: now.add(Duration(days: days)),
    );
    final e17 = episode(4, 17, -7);
    final announced = [episode(5, 1, 30), episode(5, 2, 37)];

    test('an announced season keeps Play on the episode from before', () {
      expect(
        pageEpisode(season: 5, episodes: announced, resumed: e17),
        same(e17),
      );
    });

    test('a season opens on its first aired episode', () {
      final season = [episode(5, 1, -1), episode(5, 2, 6)];
      expect(
        pageEpisode(season: 5, episodes: season, resumed: e17),
        same(season.first),
      );
    });
  });
}
