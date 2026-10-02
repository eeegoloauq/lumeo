// The shell: the bar, the window, the keyboard and Escape.
import 'dart:convert';

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';
import 'package:lumeo/platform/release_notes.dart';
import 'package:lumeo/ui/widgets/release_notes_card.dart';
import 'package:lumeo/ui/screens/app_shell.dart' show updateQuiet;

import 'fake_core.dart';

import 'app.dart';

void main() {
  uiTest('a first run shows no release notes', (tester) async {
    final settings = temporarySettings();
    await tester.pumpWidget(testApp(settings: settings));
    await tester.pumpAndSettle();
    expect(settings.lastSeenVersion, appVersion);
    expect(find.text('Got it'), findsNothing);
  });

  uiTest('release notes show once after an update', (tester) async {
    bundleNotes(tester, ['Subtitles stay put.']);
    final settings = temporarySettings()..lastSeenVersion = '0.0.1';
    await tester.pumpWidget(testApp(settings: settings));
    await tester.pumpAndSettle();
    expect(find.text('Subtitles stay put.'), findsOneWidget);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('Subtitles stay put.'), findsNothing);
    expect(settings.lastSeenVersion, appVersion);
  });

  uiTest('a newer release is offered until its notice is closed', (
    tester,
  ) async {
    final settings = temporarySettings();
    await tester.pumpWidget(
      testApp(
        api: fakeCore(update: fakeUpdate),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lumeo 0.2.1 is out'), findsOneWidget);
    // Both skipped releases, the newest first.
    expect(
      find.text('Episodes remember their subtitle track.'),
      findsOneWidget,
    );
    expect(find.text('A new home page.'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(ReleaseNotesCard),
        matching: find.byTooltip('Close'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lumeo 0.2.1 is out'), findsNothing);
    expect(settings.dismissedUpdate, '0.2.1');

    // The next start remembers it.
    await tester.pumpWidget(
      testApp(
        key: UniqueKey(),
        api: fakeCore(update: fakeUpdate),
        settings: temporarySettings()..dismissedUpdate = '0.2.1',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lumeo 0.2.1 is out'), findsNothing);
  });

  uiTest('a long notice fits a short window and opens the rest', (
    tester,
  ) async {
    final items = [
      for (var i = 1; i <= 10; i++)
        'Change $i, told at the length a real release note runs to.',
    ];
    bundleNotes(tester, items);
    await tester.binding.setSurfaceSize(const Size(1000, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      testApp(settings: temporarySettings()..lastSeenVersion = '0.0.1'),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(ReleaseNotesCard)).top, greaterThan(0));
    expect(find.text(items.last), findsNothing);

    // On a short window the count is reached by scrolling the card.
    await tester.ensureVisible(find.text('And 4 more'));
    await tester.tap(find.text('And 4 more'));
    await tester.pumpAndSettle();
    expect(find.text(items.last), findsOneWidget);
    expect(tester.getRect(find.byType(ReleaseNotesCard)).top, greaterThan(0));
  });

  uiTest('a closed notice keeps newer releases quiet for a week', (
    tester,
  ) async {
    Future<void> start(DateTime closed) async {
      await tester.pumpWidget(
        testApp(
          key: UniqueKey(),
          api: fakeCore(update: fakeUpdate),
          settings: temporarySettings()
            ..dismissedUpdate = '0.2.0'
            ..updateDismissedAt = closed,
        ),
      );
      await tester.pumpAndSettle();
    }

    await start(DateTime.now().subtract(const Duration(days: 6)));
    expect(find.text('Lumeo 0.2.1 is out'), findsNothing);
    await start(DateTime.now().subtract(updateQuiet));
    expect(find.text('Lumeo 0.2.1 is out'), findsOneWidget);
  });

  uiTest('an update that was offered first tells only that it is in', (
    tester,
  ) async {
    bundleNotes(tester, ['Subtitles stay put.']);
    await tester.pumpWidget(
      testApp(
        settings: temporarySettings()
          ..lastSeenVersion = '0.0.1'
          ..dismissedUpdate = appVersion,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Updated to $appVersion'), findsOneWidget);
    expect(find.text('Subtitles stay put.'), findsNothing);

    await tester.tap(find.text('What’s new: 1 change'));
    await tester.pumpAndSettle();
    expect(find.text('Subtitles stay put.'), findsOneWidget);
  });

  uiTest('a newer release comes before the notes of this one', (tester) async {
    bundleNotes(tester, ['Subtitles stay put.']);
    final settings = temporarySettings()..lastSeenVersion = '0.0.1';
    await tester.pumpWidget(
      testApp(
        api: fakeCore(update: fakeUpdate),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lumeo 0.2.1 is out'), findsOneWidget);
    expect(find.text('Subtitles stay put.'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(ReleaseNotesCard),
        matching: find.byTooltip('Close'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ReleaseNotesCard), findsNothing);
    expect(settings.lastSeenVersion, appVersion);
  });

  uiTest('the wordmark is printed once', (tester) async {
    // The banner and floating bar used to print overlapping wordmarks, making
    // one blurred logo.
    await openHome(tester);
    expect(find.text('LUMEO'), findsOneWidget);
  });

  uiTest('the home screen does not wait for a title\'s details', (
    tester,
  ) async {
    // The banner asked the core for its title's details; for one never
    // opened, without a network, that is the provider's whole timeout.
    await tester.pumpWidget(testApp(api: fakeCore(providerDown: true)));
    await homeShown(tester);
    expect(find.text('More info'), findsOneWidget);
  });

  uiTest('watch progress stays when the catalogue cannot be fetched', (
    tester,
  ) async {
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          providerDown: true,
          catalogUncached: true,
          continueWatching: [
            continueItem('tt0063350', {
              'season': 0,
              'episode': 0,
              'position': 900.0,
              'duration': 5700.0,
              'watched': false,
              'updatedAt': '2026-09-20T12:00:00Z',
            }),
          ],
        ),
      ),
    );
    await waitFor(
      tester,
      () async =>
          find.byKey(const ValueKey('continue-watching')).evaluate().isNotEmpty,
      what: 'watch progress',
    );
  });

  uiTest('watch progress is the first home shelf only when it exists', (
    tester,
  ) async {
    await openHome(tester);
    expect(find.byKey(const ValueKey('continue-watching')), findsNothing);

    await tester.pumpWidget(
      testApp(
        key: UniqueKey(),
        api: fakeCore(
          continueWatching: [
            continueItem('tt0063350', {
              'season': 0,
              'episode': 0,
              'position': 900.0,
              'duration': 5700.0,
              'watched': false,
              'updatedAt': '2026-09-20T12:00:00Z',
            }),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final shelf = find.byKey(const ValueKey('continue-watching'));
    expect(shelf, findsOneWidget);
    final tiles = find.descendant(of: shelf, matching: find.byType(PosterTile));
    expect(tiles, findsWidgets);
    expect(tester.widget<PosterTile>(tiles.first).item.id, 'tt0063350');
    // The first catalogue shelf can be below the fold or not built yet.
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

  uiTest('the bar carries the window buttons', (tester) async {
    await openHome(tester);
    expect(find.byTooltip('Minimise'), findsOneWidget);
    expect(find.byTooltip('Maximise'), findsOneWidget);
    expect(find.byTooltip('Close'), findsOneWidget);
  });

  uiTest('a right click on the bar opens the window manager\'s menu', (
    tester,
  ) async {
    await openHome(tester);
    // Left of the wordmark: bar, and nothing on it.
    final y = tester.getCenter(find.byTooltip('Minimise')).dy;
    await tester.tapAt(Offset(20, y), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(windowCalls.map((c) => c.method), contains('showWindowMenu'));
  });

  uiTest('Ctrl+Q quits, which closing does not in the background', (
    tester,
  ) async {
    await openHome(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(windowCalls.map((c) => c.method), contains('quit'));
  });

  uiTest('F11 reaches the window from a screen nobody has clicked', (
    tester,
  ) async {
    // Shortcuts once failed until the first click because nothing held focus.
    await openHome(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    expect(windowCalls.map((c) => c.method), contains('setFullscreen'));
  });

  uiTest('no text on screen falls back to the missing-Material style', (
    tester,
  ) async {
    // Text outside Material once gave the downloads panel Flutter's yellow
    // fallback underline.
    await openHome(tester, downloads: [fakeDownload()]);
    expectNoFallbackStyle(tester);
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    expectNoFallbackStyle(tester);
  });

  uiTest('escape comes back even from a fullscreen window', (tester) async {
    // Escape used to spend itself on leaving fullscreen, so on a window wrongly
    // believed fullscreen it did nothing visible.
    await openHome(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await homeShown(tester);
  });

  uiTest('the keyboard comes back to the shell when it lands nowhere', (
    tester,
  ) async {
    // Desktop focus return once left no focused node, disabling Ctrl+F until
    // the first click.
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

  uiTest('Play in the banner starts something', (tester) async {
    // The banner Play button used to open the title page without starting
    // playback.
    final started = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(started: started)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => started.isNotEmpty,
      what: 'Play asked the core for a download',
    );
    expect(started, isNotEmpty, reason: 'Play asked the core for a download');
  });

  uiTest('leaving a film started from the banner does not start it again', (
    tester,
  ) async {
    // Play from the banner used to leave "start this" set, so leaving the film
    // started it again.
    final started = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(started: started, downloads: [fakeDownload()]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => playing(tester) != null,
      what: 'the film opened',
    );
    tester.widget<PlayerStandIn>(find.byType(PlayerStandIn)).screen.onClose();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(playing(tester), isNull);
    expect(started, hasLength(1));
  });

  uiTest('a file the core refuses says why', (tester) async {
    await tester.pumpWidget(
      testApp(open: '/films/notes.txt', api: fakeCore(openFails: true)),
    );
    await tester.pumpAndSettle();
    expect(playing(tester), isNull);
    expect(
      find.text('Could not open notes.txt: not a video file'),
      findsOneWidget,
    );
  });
}

/// Serves a metainfo file whose release for this version lists [items].
void bundleNotes(WidgetTester tester, List<String> items) {
  const path = 'assets/dev.lumeo.lumeo.metainfo.xml';
  final source =
      '<component><releases><release version="$appVersion">'
      '<description><ul>${items.map((i) => '<li>$i</li>').join()}</ul>'
      '</description></release></releases></component>';
  tester.binding.defaultBinaryMessenger.setMockMessageHandler(
    'flutter/assets',
    (message) async => utf8.decode(message!.buffer.asUint8List()) != path
        ? null
        : utf8.encoder.convert(source).buffer.asByteData(),
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      null,
    ),
  );
  // rootBundle keeps what an earlier test read of the real file.
  rootBundle.evict(path);
  addTearDown(() => rootBundle.evict(path));
}
