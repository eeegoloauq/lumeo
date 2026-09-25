// The shell: the bar, the window, the keyboard and Escape.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';

import 'fake_core.dart';

import 'helpers.dart';

void shellTests() {
  testWidgets('the wordmark is printed once', (tester) async {
    // It was printed twice, in the same place, a point apart: the banner had
    // one and the bar that floats over the banner had another. On screen that
    // is not two logos, it is one blurred one.
    await openHome(tester);
    expect(find.text('LUMEO'), findsOneWidget);
  });

  testWidgets('watch progress is the first home shelf only when it exists', (
    tester,
  ) async {
    await openHome(tester);
    expect(find.byKey(const ValueKey('continue-watching')), findsNothing);

    await tester.pumpWidget(
      LumeoApp(
        key: UniqueKey(),
        api: fakeCore(
          progress: {
            'tt0063350': [
              {
                'season': 0,
                'episode': 0,
                'position': 900.0,
                'duration': 5700.0,
                'watched': false,
                'updatedAt': '2026-09-20T12:00:00Z',
              },
            ],
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    final shelf = find.byKey(const ValueKey('continue-watching'));
    expect(shelf, findsOneWidget);
    final tiles = find.descendant(of: shelf, matching: find.byType(PosterTile));
    expect(tiles, findsWidgets);
    expect(tester.widget<PosterTile>(tiles.first).item.id, 'tt0063350');
    // Above the catalogues: the first catalogue shelf is either further down
    // the screen, or not built yet because it is below the fold.
    final continueTop = tester.getTopLeft(find.text('Continue watching')).dy;
    final popular = find.text('Popular films');
    if (popular.evaluate().isEmpty) {
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(popular, findsOneWidget, reason: 'the catalogues follow');
    } else {
      expect(
        continueTop,
        lessThan(tester.getTopLeft(popular).dy),
        reason: 'watch progress is above the catalogues',
      );
    }
  });

  testWidgets('the bar carries the window buttons', (tester) async {
    await openHome(tester);
    expect(find.byTooltip('Minimise'), findsOneWidget);
    expect(find.byTooltip('Maximise'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  testWidgets('F11 reaches the window from a screen nobody has clicked', (
    tester,
  ) async {
    // It did not: shortcuts arrive by walking up from whatever holds the focus,
    // and nothing held it until the first click.
    await openHome(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(windowCalls.map((c) => c.method), contains('setFullscreen'));
  });

  testWidgets('no text on screen falls back to the missing-Material style', (
    tester,
  ) async {
    // Flutter marks text that has no Material above it with red monospace and
    // a yellow double underline, on purpose. Our styles set colour and family
    // but not decoration, so what came through was the underline alone and the
    // whole downloads panel looked hyperlinked.
    await openHome(tester, downloads: [fakeDownload()]);
    expectNoFallbackStyle(tester);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    expectNoFallbackStyle(tester);
  });

  testWidgets('escape comes back from a title', (tester) async {
    await openHome(tester);
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    expect(find.text('Popular films'), findsNothing, reason: 'on the title');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await homeShown(tester);
  });

  testWidgets('escape comes back even from a fullscreen window', (
    tester,
  ) async {
    // The regression this replaces: Escape used to spend itself on leaving
    // fullscreen, so on a window it believed was fullscreen it did nothing a
    // viewer could see.
    await openHome(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await homeShown(tester);
  });

  testWidgets('the keyboard comes back to the shell when it lands nowhere', (
    tester,
  ) async {
    // What a desktop does a moment after the window opens: it gives the window
    // the keyboard, and Flutter — which had dropped the focus while the view
    // was unfocused — puts nothing back. The focus then sits on a scope with
    // no node in it, no key climbs anywhere, and Ctrl+F works only after the
    // first click somewhere in the page. It is also what happens whenever a
    // focused widget is unmounted.
    await openHome(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
      reason: 'the shell picked the keyboard back up on its own',
    );
  });

  testWidgets('Play in the banner starts something', (tester) async {
    // Both buttons under the banner opened the title page, so the one labelled
    // Play started nothing at all.
    final started = <String>[];
    await tester.pumpWidget(LumeoApp(api: fakeCore(started: started)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => started.isNotEmpty,
      what: 'Play asked the core for a download',
    );
    expect(started, isNotEmpty, reason: 'Play asked the core for a download');
  });
}
