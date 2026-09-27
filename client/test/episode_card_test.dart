import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/ui/widgets/episode_card.dart';

import 'ui/app.dart' show pngFourByFour, waitForIo;
import 'ui/fake_core.dart' show fakeDownload;

void main() {
  late File still;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('lumeo-still-');
    addTearDown(() => dir.deleteSync(recursive: true));
    still = File('${dir.path}/still.png')
      ..writeAsBytesSync(base64Decode(pngFourByFour));
  });

  WatchEntry progress({
    required bool watched,
    Duration position = const Duration(minutes: 20),
  }) => WatchEntry(
    season: 1,
    episode: 2,
    position: position,
    duration: const Duration(minutes: 24),
    watched: watched,
    updatedAt: DateTime.utc(2026, 9, 20),
  );

  Future<void> card(
    WidgetTester tester, {
    File? frame,
    String artwork = 'show',
    WatchEntry? progress,
    Download? download,
  }) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: EpisodeCard(
            episode: const Episode(season: 1, number: 2),
            selected: false,
            focusNode: focus,
            tabStop: false,
            onSelect: () {},
            onPlay: () {},
            onStep: (_) {},
            frame: frame,
            artworkPreference: artwork,
            progress: progress,
            download: download,
          ),
        ),
      ),
    );
  }

  double? bar(WidgetTester tester) => tester
      .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
      .value;

  testWidgets('a watched episode is a full bar, not a check', (tester) async {
    // The check read as a heavy box over a real still.
    await card(
      tester,
      progress: progress(watched: true, position: Duration.zero),
    );
    expect(bar(tester), 1);
    expect(find.byIcon(Icons.check), findsNothing);
  });

  testWidgets('a started episode shows how far it got', (tester) async {
    await card(tester, progress: progress(watched: false));
    expect(bar(tester), closeTo(20 / 24, 0.01));
  });

  testWidgets('an episode on disk is marked so', (tester) async {
    await card(
      tester,
      download: Download.fromJson(fakeDownload(state: 'done')),
    );
    expect(find.byIcon(Icons.download), findsOneWidget);
  });

  testWidgets('an episode arriving is marked with its progress', (
    tester,
  ) async {
    await card(tester, download: Download.fromJson(fakeDownload()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  // The stills a title page gets over HTTP take the same path once decoded;
  // a file is the one source a widget test can load without a network.
  testWidgets('a still that arrived is blurred until it is watched', (
    tester,
  ) async {
    await card(
      tester,
      frame: still,
      artwork: 'blur',
      progress: progress(watched: false),
    );
    await waitForIo(tester, find.byType(RawImage));
    expect(find.byType(ImageFiltered), findsOneWidget);
    await card(
      tester,
      frame: still,
      artwork: 'blur',
      progress: progress(watched: true),
    );
    await waitForIo(tester, find.byType(RawImage));
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('a still that never arrives is not blurred', (tester) async {
    // The placeholder is the episode number, not a spoiler.
    await card(
      tester,
      frame: File('${still.parent.path}/missing.png'),
      artwork: 'blur',
      progress: progress(watched: false),
    );
    await waitForIo(tester, find.text('2'));
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('hidden stills are not loaded at all', (tester) async {
    await card(tester, frame: still, artwork: 'hide');
    expect(find.byType(Image), findsNothing);
    expect(find.text('2'), findsOneWidget);
  });
}
