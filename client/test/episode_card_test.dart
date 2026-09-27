import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/ui/widgets/episode_card.dart';

import 'ui/app.dart' show pngFourByFour, waitForIo;

void main() {
  late File still;

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('lumeo-still-');
    addTearDown(() => dir.deleteSync(recursive: true));
    still = File('${dir.path}/still.png')
      ..writeAsBytesSync(base64Decode(pngFourByFour));
  });

  Future<void> card(WidgetTester tester, {required bool watched}) async {
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
            frame: still,
            artworkPreference: 'blur',
            progress: WatchEntry(
              season: 1,
              episode: 2,
              position: const Duration(minutes: 20),
              duration: const Duration(minutes: 24),
              watched: watched,
              updatedAt: DateTime.utc(2026, 9, 20),
            ),
          ),
        ),
      ),
    );
    // Decoded for real, which fake time does not wait for.
    await waitForIo(tester, find.byType(RawImage));
  }

  // The stills a title page gets over HTTP take the same path once decoded;
  // a file is the one source a widget test can load without a network.
  testWidgets('a still that arrived is blurred until it is watched', (
    tester,
  ) async {
    await card(tester, watched: false);
    expect(find.byType(ImageFiltered), findsOneWidget);
    await card(tester, watched: true);
    expect(find.byType(ImageFiltered), findsNothing);
  });
}
