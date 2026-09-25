import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';

void main() {
  test('a running series shows an open-ended year range', () {
    const series = MediaItem(
      id: 'a',
      kind: 'series',
      title: 'Severance',
      year: 2022,
    );
    expect(series.years, '2022–');
  });

  test('a finished series shows both years', () {
    const series = MediaItem(
      id: 'a',
      kind: 'series',
      title: 'Breaking Bad',
      year: 2008,
      yearEnd: 2013,
    );
    expect(series.years, '2008–2013');
  });

  test('a film shows one year', () {
    const film = MediaItem(id: 'a', kind: 'movie', title: 'Dune', year: 2021);
    expect(film.years, '2021');
  });

  test('progress is zero until the size is known, never full', () {
    const fresh = Progress(completed: 0, total: 0);
    expect(fresh.fraction, 0);
    const half = Progress(completed: 50, total: 100);
    expect(half.fraction, 0.5);
  });

  _upcomingTests();
  _dateTests();
}

// Providers list a whole season as soon as the dates are known, so a page can
// carry episodes nobody can watch yet. Offering to play those would be a lie.
void _upcomingTests() {
  test('an episode dated in the future is not playable yet', () {
    final soon = Episode(
      season: 3,
      number: 11,
      released: DateTime.now().toUtc().add(const Duration(days: 7)),
    );
    expect(soon.isUpcoming, isTrue);
  });

  test('an aired episode is not upcoming', () {
    final aired = Episode(
      season: 3,
      number: 10,
      released: DateTime.now().toUtc().subtract(const Duration(days: 1)),
    );
    expect(aired.isUpcoming, isFalse);
  });

  test('an episode with no date is treated as aired, not as upcoming', () {
    const undated = Episode(season: 1, number: 1);
    expect(undated.isUpcoming, isFalse);
  });
}

// An air date earns its place on a card only when it says something: that the
// episode is not out yet, or that it just landed.
void _dateTests() {
  test('an episode from years ago is neither upcoming nor recent', () {
    final old = Episode(
      season: 1,
      number: 1,
      released: DateTime.utc(2008, 1, 20),
    );
    expect(old.isUpcoming, isFalse);
    expect(old.isRecent, isFalse);
  });

  test('an episode from this week is recent', () {
    final fresh = Episode(
      season: 3,
      number: 10,
      released: DateTime.now().toUtc().subtract(const Duration(days: 3)),
    );
    expect(fresh.isRecent, isTrue);
  });

  test('an episode still to air is upcoming, not recent', () {
    final soon = Episode(
      season: 3,
      number: 11,
      released: DateTime.now().toUtc().add(const Duration(days: 5)),
    );
    expect(soon.isUpcoming, isTrue);
    expect(soon.isRecent, isFalse);
  });
}
