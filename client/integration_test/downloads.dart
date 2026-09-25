// The downloads panel under the bar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/ui/player/player_screen.dart';

import 'fake_core.dart';

import 'helpers.dart';

void downloadsTests() {
  testWidgets('the downloads panel opens and its stop button can be pressed', (
    tester,
  ) async {
    // It opened inside a bar 68 points tall and was clipped at its edge: the
    // list was there and nothing in it could be reached, the stop button
    // included. Pressing it is the assertion — a rectangle with sensible
    // coordinates proves nothing, because the clipped one had those too.
    // Stop is on what is waiting; what is arriving is paused instead.
    final stopped = <String>[];
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          downloads: [fakeDownload(waitingSince: DateTime.now())],
          stopped: stopped,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Stop and discard'));
    await waitFor(
      tester,
      () async =>
          stopped.contains('d1') &&
          find.byKey(const ValueKey('downloads')).evaluate().isEmpty,
      what: 'the download stopped and its row went',
    );
    expect(stopped, contains('d1'), reason: 'the core was told to stop it');
    expect(
      find.byKey(const ValueKey('downloads')),
      findsNothing,
      reason: 'and the row goes at once, not on the next poll',
    );
  });

  testWidgets('a download starting moves nothing else in the bar', (
    tester,
  ) async {
    // The whole reason the bar is a Stack. The indicator used to sit in a row
    // between search and the window buttons, so the moment a download started
    // everything to its left slid across — a control moving out from under a
    // pointer already aimed at it, and a screenshot run that typed a title
    // into whatever had taken the field's place.
    await openHome(tester);
    final quietTabs = tester.getCenter(find.text('Home'));
    final quietSearch = tester.getCenter(find.byTooltip('Search  ·  Ctrl+F'));

    // A key, because pumpWidget of the same widget type reuses the State that
    // is already there — and this application takes its core once, in a `late
    // final`. Without it the second window is the first one again, with no
    // downloads in it, and this test passes by proving nothing.
    await tester.pumpWidget(
      LumeoApp(
        key: UniqueKey(),
        api: fakeCore(downloads: [fakeDownload()]),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('downloads')),
      findsOneWidget,
      reason: 'the indicator is there to have moved something',
    );
    expect(tester.getCenter(find.text('Home')), quietTabs);
    expect(tester.getCenter(find.byTooltip('Search  ·  Ctrl+F')), quietSearch);
  });

  testWidgets('the downloads panel hangs to the left of its button', (
    tester,
  ) async {
    // The indicator is the last control before the window's own buttons, and a
    // menu opens to the right of what it hangs from: on the real window the
    // panel went off the frame and took the release name and the peer count
    // with it. The menu's own edge-avoidance did not save it, so the offset is
    // stated in the widget — and measured here rather than against the edge of
    // the window, because a test that compares the panel to the same bound the
    // menu clamps to cannot fail.
    await openHome(tester, downloads: [fakeDownload()]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    final panel = tester.getRect(find.byKey(const ValueKey('download:d1')));
    final button = tester.getRect(find.byKey(const ValueKey('downloads')));
    expect(
      panel.right,
      closeTo(button.right, 1),
      reason: 'to the right of the button there is only the window edge',
    );
    expect(panel.left, greaterThanOrEqualTo(0));
  });

  testWidgets('a download with nothing to play yet opens its title', (
    tester,
  ) async {
    // What is arriving is the most likely reason this window is open at all,
    // and the page where it can be watched was two clicks away through a
    // catalogue that does not know it is downloading.
    await openHome(tester, downloads: [fakeDownload(ready: false)]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    // By key, not by the title on it: the same title is printed on the poster
    // in the shelf behind the panel, and a tap that lands there is a tap
    // outside an open menu — which the menu eats to close itself.
    await tester.tap(find.byKey(const ValueKey('download:d1')));
    await tester.pumpAndSettle();
    expect(find.text('Popular films'), findsNothing, reason: 'on the title');
  });

  testWidgets('a download with something to play plays from the panel', (
    tester,
  ) async {
    await openHome(tester, downloads: [fakeDownload()]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download:d1')));
    await tester.pump();
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  testWidgets('a season in the downloads panel is one row per state that '
      'opens into its episodes, and Clear takes what finished', (tester) async {
    final now = DateTime.now();
    await openHome(
      tester,
      downloads: [
        for (final e in [1, 2, 3])
          fakeDownload(
            id: 'bb$e',
            itemId: 'tt0903747',
            season: 1,
            episode: e,
            state: e == 1 ? 'done' : 'active',
            updatedAt: now,
          ),
        fakeDownload(state: 'done', updatedAt: now),
        // Finished before the keep time: not listed.
        fakeDownload(
          id: 'old',
          itemId: 'tt0000001',
          state: 'done',
          updatedAt: now.subtract(const Duration(days: 3)),
        ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    expect(find.text('READY TO WATCH'), findsOneWidget);
    expect(find.text('S1 E1'), findsOneWidget);
    expect(find.text('S1 E2–E3'), findsOneWidget, reason: 'one row for both');
    expect(find.text('E2'), findsNothing, reason: 'collapsed');
    expect(find.byKey(const ValueKey('download:old')), findsNothing);

    await tester.tap(find.text('S1 E2–E3'));
    await tester.pumpAndSettle();
    for (final e in ['E2', 'E3']) {
      expect(find.text(e), findsOneWidget);
    }

    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('READY TO WATCH'), findsNothing);
    expect(find.byKey(const ValueKey('download:d1')), findsNothing);
    expect(find.text('S1 E1'), findsNothing);
    expect(find.text('E2'), findsOneWidget, reason: 'the season still runs');
  });

  testWidgets('a download is paused from the panel and resumed', (
    tester,
  ) async {
    final patches = <String>[];
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(downloads: [fakeDownload()], downloadPatches: patches),
      ),
    );
    await homeShown(tester);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    expect(find.text('ARRIVING'), findsOneWidget);
    expect(find.text('3.0 MB/s · 12 min left'), findsOneWidget);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(patches, ['d1 {"paused":true}']);
    expect(
      find.text('Paused'),
      findsOneWidget,
      reason: 'the row changes with the answer, not on the next poll',
    );
    expect(find.text('ARRIVING'), findsNothing);

    await tester.tap(find.byTooltip('Resume'));
    await tester.pumpAndSettle();
    expect(patches.last, 'd1 {"paused":false}');
    expect(find.text('ARRIVING'), findsOneWidget);
  });

  testWidgets('Storage in the downloads panel opens the downloads settings', (
    tester,
  ) async {
    await openHome(tester, downloads: [fakeDownload()]);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Storage ›'));
    await tester.pumpAndSettle();
    expect(find.text('ARRIVING'), findsNothing, reason: 'the panel closed');
    // On screen, not merely built: settings opened where the disk is managed.
    final limit = find.text('Disk limit');
    expect(limit, findsOneWidget);
    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    final rect = tester.getRect(limit);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(window.height));
  });
}
