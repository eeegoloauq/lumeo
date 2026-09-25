import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/screens/library_screen.dart';
import 'package:lumeo/ui/theme.dart';
import 'package:lumeo/ui/widgets/library_text.dart';
import 'package:lumeo/ui/widgets/rating_button.dart';

void main() {
  group('dayLabel', () {
    final today = DateTime(2026, 9, 24, 21); // a Thursday evening

    test('says today, yesterday and the weekday within the week', () {
      expect(dayLabel(DateTime(2026, 9, 24, 8), today), 'Today');
      expect(dayLabel(DateTime(2026, 9, 23, 23, 59), today), 'Yesterday');
      expect(dayLabel(DateTime(2026, 9, 19), today), 'Sat');
      expect(dayLabel(DateTime(2026, 9, 18), today), 'Fri');
    });

    test(
      'a week ago is a date, with the year only when it is not this one',
      () {
        expect(dayLabel(DateTime(2026, 9, 17), today), '17 Sep');
        expect(dayLabel(DateTime(2025, 12, 31), today), '31 Dec 2025');
      },
    );
  });

  MediaItem film() => const MediaItem(id: 'f', kind: 'movie', title: 'Film');
  MediaItem series() =>
      const MediaItem(id: 's', kind: 'series', title: 'Series');
  ListedTitle listed(
    MediaItem item, {
    int watched = 0,
    int released = 0,
    int rating = 0,
    int year = 0,
    String title = '',
    DateTime? added,
  }) => ListedTitle(
    item: MediaItem(
      id: title.isEmpty ? item.id : title,
      kind: item.kind,
      title: title.isEmpty ? item.title : title,
      year: year,
    ),
    addedAt: added ?? DateTime.utc(2026),
    watched: watched,
    released: released,
    rating: rating,
  );

  group('listedCaption', () {
    test('says how far the viewer is', () {
      expect(
        listedCaption(listed(series(), watched: 2, released: 10)),
        '2 of 10 seen',
      );
      expect(
        listedCaption(listed(series(), watched: 10, released: 10, rating: 8)),
        'watched',
      );
      expect(
        listedCaption(listed(film(), watched: 1, released: 1, rating: 9)),
        'watched',
      );
    });

    test('the kind only when there is neither progress nor a score', () {
      expect(listedCaption(listed(film(), released: 1)), 'Film');
      expect(listedCaption(listed(series())), 'Series');
      // The score is drawn after it, as a star.
      expect(listedCaption(listed(series(), rating: 7)), '');
    });
  });

  test('a new episode says which, when, and how many there are', () {
    final now = DateTime.utc(2026, 9, 24, 18);
    NewEpisodes found(int count, DateTime released) => NewEpisodes(
      item: series(),
      episode: Episode(season: 4, number: 18, released: released),
      count: count,
    );
    expect(
      newEpisodeCaption(found(1, DateTime.utc(2026, 9, 24)), now),
      'S4 E18 · Today',
    );
    expect(
      newEpisodeCaption(found(3, DateTime.utc(2026, 9, 19)), now),
      'S4 E18 · Sat · 3 new',
    );
  });

  group('a line of the history', () {
    WatchEntry entry({int position = 0, bool watched = false}) => WatchEntry(
      season: 4,
      episode: 17,
      position: Duration(seconds: position),
      duration: const Duration(minutes: 24),
      watched: watched,
      updatedAt: DateTime.utc(2026, 9, 24),
    );

    test('says the time left, or that it was finished', () {
      expect(viewingState(entry(position: 12 * 60)), '12 min left');
      expect(viewingState(entry(watched: true)), 'watched');
      // A rewatch under way is where it is now.
      expect(
        viewingState(entry(position: 20 * 60, watched: true)),
        '4 min left',
      );
    });

    test('names the series, the episode and its title', () {
      expect(
        viewingTitle(
          Viewing(
            item: series(),
            entry: entry(),
            episode: const Episode(season: 4, number: 17, title: 'Good Loser'),
          ),
        ),
        'Series · S4 E17 Good Loser',
      );
      // A provider that titles an episode by its number says nothing more.
      expect(
        viewingTitle(
          Viewing(
            item: series(),
            entry: entry(),
            episode: const Episode(season: 4, number: 17, title: 'Episode 17'),
          ),
        ),
        'Series · S4 E17',
      );
      expect(viewingTitle(Viewing(item: film(), entry: entry())), 'Film');
    });
  });

  group('sortListed', () {
    final titles = [
      listed(
        film(),
        title: 'The Bear',
        year: 2022,
        rating: 7,
        added: DateTime.utc(2026, 9, 1),
      ),
      listed(
        film(),
        title: 'Andor',
        year: 2022,
        added: DateTime.utc(2026, 9, 3),
      ),
      listed(
        film(),
        title: 'Arrival',
        rating: 9,
        added: DateTime.utc(2026, 9, 2),
      ),
      listed(
        film(),
        title: 'Dune',
        year: 2024,
        added: DateTime.utc(2026, 8, 1),
      ),
    ];
    List<String> order(String by) => [
      for (final t in sortListed(titles, by)) t.item.title,
    ];

    test('recently added is the default', () {
      expect(order('added'), ['Andor', 'Arrival', 'The Bear', 'Dune']);
      expect(order('nonsense'), order('added'));
    });

    test('titles sort without their article', () {
      expect(order('title'), ['Andor', 'Arrival', 'The Bear', 'Dune']);
    });

    test('by year and by score, what has neither goes last', () {
      expect(order('year'), ['Dune', 'Andor', 'The Bear', 'Arrival']);
      expect(order('rating'), ['Arrival', 'The Bear', 'Andor', 'Dune']);
    });
  });

  group('RatingButton', () {
    Future<List<Object>> open(WidgetTester tester, {int score = 0}) async {
      final calls = <Object>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: lumeoTheme(),
          home: Scaffold(
            body: Center(
              child: RatingButton(
                score: score,
                label: 'Rate',
                onRate: calls.add,
                onClear: () => calls.add('clear'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('rating-button')));
      await tester.pumpAndSettle();
      return calls;
    }

    testWidgets('a number in the row is the score given', (tester) async {
      final calls = await open(tester);
      expect(find.text('Your rating'), findsOneWidget);
      expect(find.text('Remove rating'), findsNothing);
      await tester.tap(find.text('8'));
      await tester.pumpAndSettle();
      expect(calls, [8]);
      expect(find.text('Your rating'), findsNothing, reason: 'it closed');
    });

    testWidgets('the arrows walk the row and Enter picks', (tester) async {
      final calls = await open(tester, score: 6);
      // The keyboard starts on the score there is.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('8 of 10'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, [8]);
    });

    testWidgets('a score can be taken back', (tester) async {
      final calls = await open(tester, score: 6);
      await tester.tap(find.text('Remove rating'));
      await tester.pumpAndSettle();
      expect(calls, ['clear']);
    });
  });
}
