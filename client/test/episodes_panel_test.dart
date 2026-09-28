import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/ui/player/panels.dart';

void main() {
  Future<ScrollPosition> open(
    WidgetTester tester, {
    required int episodes,
    required int current,
  }) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A panel of its own each time: opening is what is under test.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: EpisodesPanel(
              episodes: [
                for (var n = 1; n <= episodes; n++)
                  Episode(season: 1, number: n),
              ],
              currentSeason: 1,
              currentEpisode: current,
              progress: null,
              runtime: '',
              artwork: 'hide',
              frameOf: (_) => null,
              onPlay: (_) {},
            ),
          ),
        ),
      ),
    );
    return tester.state<ScrollableState>(find.byType(Scrollable)).position;
  }

  // The defect: the list was drawn from the top for a frame and then jumped,
  // which reads as the panel twitching every time it opens.
  testWidgets('the episode list opens on the playing episode and stays put', (
    tester,
  ) async {
    Future<double> settled(ScrollPosition position) async {
      final opened = position.pixels;
      await tester.pumpAndSettle();
      expect(position.pixels, opened, reason: 'nothing moves after the frame');
      return opened;
    }

    final long = await open(tester, episodes: 30, current: 20);
    expect(await settled(long), 18 * 88, reason: 'the one before it shows');

    final last = await open(tester, episodes: 30, current: 30);
    expect(await settled(last), last.maxScrollExtent);

    final short = await open(tester, episodes: 3, current: 3);
    expect(await settled(short), 0);
  });
}
