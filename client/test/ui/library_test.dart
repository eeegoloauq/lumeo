// My list, scores and the history.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/widgets/episode_card.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';

import 'fake_core.dart';

import 'app.dart';

void main() {
  bool libraryLit(WidgetTester tester) => tester
      .widget<PillTab>(
        find.descendant(
          of: find.byType(TopBar),
          matching: find.widgetWithText(PillTab, 'Library'),
        ),
      )
      .selected;

  uiTest('a title added on its page is on My list, and comes off it', (
    tester,
  ) async {
    final calls = <String>[];
    await openSeries(tester, api: fakeCore(libraryCalls: calls));
    await tester.tap(find.byKey(const ValueKey('list-button')));
    await tester.pumpAndSettle();
    expect(calls, ['PUT /api/v1/list/tt0903747']);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('list-button')))
          .isSelected,
      isTrue,
    );

    await openLibrary(tester);
    final tile = find.byKey(const ValueKey('listed:tt0903747'));
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.text('Series')),
      findsOneWidget,
      reason: 'nothing watched and no score: the kind is all there is to say',
    );
    expect(libraryLit(tester), isTrue);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(libraryLit(tester), isTrue);
    await tester.tap(find.byKey(const ValueKey('list-button')));
    await tester.pumpAndSettle();
    expect(calls.last, 'DELETE /api/v1/list/tt0903747');

    // Reopening Library from its title used to stack another route, requiring
    // extra Escape presses.
    await openLibrary(tester);
    // Refresh on return so changes from the title page appear.
    expect(find.byKey(const ValueKey('listed:tt0903747')), findsNothing);
    expect(find.text('Nothing on your list yet'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(libraryLit(tester), isFalse);
    expect(find.text('Nothing on your list yet'), findsNothing);
  });

  uiTest('a title is scored from its page', (tester) async {
    final calls = <String>[];
    await openSeries(tester, api: fakeCore(libraryCalls: calls));
    await tester.tap(find.byKey(const ValueKey('rating-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7'));
    await tester.pumpAndSettle();
    expect(calls, [
      'PUT /api/v1/ratings/tt0903747 {"season":0,"episode":0,"rating":7}',
    ]);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('rating-button')),
        matching: find.text('7'),
      ),
      findsOneWidget,
    );
  });

  uiTest('the history lists what was watched, scores it and forgets it', (
    tester,
  ) async {
    final calls = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          libraryCalls: calls,
          progress: {
            'tt0903747': {
              'entries': [
                watchEntry(
                  episode: 1,
                  position: 0,
                  duration: 1200,
                  watched: true,
                  updatedAt: '2026-09-20T11:00:00Z',
                ),
                watchEntry(
                  episode: 2,
                  position: 480,
                  duration: 1200,
                  watched: false,
                  updatedAt: '2026-09-20T12:00:00Z',
                ),
              ],
              'next': watchEntry(
                episode: 2,
                position: 480,
                duration: 1200,
                watched: false,
                updatedAt: '2026-09-20T12:00:00Z',
              ),
            },
          },
          continueWatching: [
            continueItem(
              'tt0903747',
              watchEntry(
                episode: 2,
                position: 480,
                duration: 1200,
                watched: false,
                updatedAt: '2026-09-20T12:00:00Z',
              ),
            ),
          ],
          history: [
            for (final episode in [2, 1])
              {
                'item': Map<String, dynamic>.of(fakeItem('tt0903747'))
                  ..remove('episodes'),
                'entry': watchEntry(
                  episode: episode,
                  position: episode == 2 ? 480 : 0,
                  duration: 1200,
                  watched: episode == 1,
                  updatedAt: episode == 2
                      ? '2026-09-20T12:00:00Z'
                      : '2026-09-20T11:00:00Z',
                ),
                'episode':
                    (fakeItem('tt0903747')['episodes'] as List)[episode - 1],
              },
          ],
        ),
      ),
    );
    await waitFor(
      tester,
      () async => find.text('Continue watching').evaluate().isNotEmpty,
      what: 'the home screen',
    );
    await openLibrary(tester);
    await tester.tap(find.byKey(const ValueKey('library:history')));
    await tester.pumpAndSettle();

    final second = find.byKey(const ValueKey('viewing:tt0903747:1:2'));
    final first = find.byKey(const ValueKey('viewing:tt0903747:1:1'));
    expect(
      find.descendant(
        of: second,
        matching: find.text("Breaking Bad · S1 E2 Cat's in the Bag..."),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: second, matching: find.textContaining('12 min left')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: first, matching: find.textContaining('watched')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(second).dy,
      lessThan(tester.getTopLeft(first).dy),
      reason: 'the latest first',
    );

    await tester.tap(find.descendant(of: first, matching: find.text('Rate')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('9'));
    await tester.pumpAndSettle();
    expect(calls, [
      'PUT /api/v1/ratings/tt0903747 {"season":1,"episode":1,"rating":9}',
    ]);
    expect(
      find.descendant(of: first, matching: find.text('9')),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: second,
        matching: find.byTooltip('Remove from history'),
      ),
    );
    await tester.pumpAndSettle();
    expect(second, findsNothing);
    expect(first, findsOneWidget);

    await tester.tap(
      find.descendant(of: first, matching: find.textContaining('Pilot')),
    );
    await tester.pumpAndSettle();
    final card = find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == 1,
    );
    expect(tester.widget<EpisodeCard>(card).selected, isTrue);
  });
}
