// A title's page: seasons, episode cards, downloads and the sources drawer.
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/platform/decoders.dart';
import 'package:lumeo/ui/screens/home_screen.dart';
import 'package:lumeo/ui/screens/item_screen.dart';
import 'package:lumeo/ui/widgets/library_actions.dart';
import 'package:lumeo/ui/widgets/episode_card.dart';
import 'package:lumeo/ui/widgets/horizontal_strip.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';

import 'fake_core.dart';

import 'app.dart';

void main() {
  Map<String, dynamic> secondEpisodeStarted(double position) {
    final second = watchEntry(
      episode: 2,
      position: position,
      duration: 1200,
      watched: false,
      updatedAt: '2026-09-20T12:00:00Z',
    );
    return {
      'entries': [
        watchEntry(
          episode: 1,
          position: 1200,
          duration: 1200,
          watched: true,
          updatedAt: '2026-09-20T11:00:00Z',
        ),
        second,
      ],
      'next': second,
    };
  }

  uiTest('a new episode opens its title on that episode', (tester) async {
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          newEpisodes: [
            {
              'item': {
                'id': 'tt0903747',
                'kind': 'series',
                'title': 'Breaking Bad',
              },
              'episode': {
                'season': 1,
                'number': 3,
                'title': 'And the Bag is in the River',
                'released': DateTime.now()
                    .toUtc()
                    .subtract(const Duration(days: 1))
                    .toIso8601String(),
              },
              'count': 2,
            },
          ],
        ),
      ),
    );
    await homeShown(tester);
    await openLibrary(tester);
    final shelf = find.byKey(const ValueKey('new-episodes'));
    expect(shelf, findsOneWidget);
    expect(
      find.descendant(
        of: shelf,
        matching: find.text('S1 E3 · Yesterday · 2 new'),
      ),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(of: shelf, matching: find.byType(PosterTile)),
    );
    await tester.pumpAndSettle();
    final card = find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == 3,
    );
    expect(tester.widget<EpisodeCard>(card).selected, isTrue);
  });

  uiTest('the bar takes a ground once the page scrolls under it', (
    tester,
  ) async {
    // Desktop ScrollView did not attach the shell's primary controller, so the
    // bar overlaid scrolled text.
    await openHome(tester);
    expect(
      tester.widget<TopBar>(find.byType(TopBar)).scrolled.value,
      isFalse,
      reason: 'at the top it is over artwork, and shows nothing',
    );
    final page = tester.widget(find.byType(HomeScreen));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(PosterTile).first));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();
    expect(tester.widget<TopBar>(find.byType(TopBar)).scrolled.value, isTrue);
    expect(
      tester.widget(find.byType(HomeScreen)),
      same(page),
      reason: 'the bar taking its ground rebuilt the page under it',
    );
  });

  uiTest('a title page that fits the window does not scroll', (tester) async {
    // The banner lacked 56 points below its strip, leaving no room for either
    // page to scroll.
    double scrollable() => tester
        .state<ScrollableState>(
          find
              .descendant(
                of: find.byType(ItemScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        )
        .position
        .maxScrollExtent;
    await openSeries(tester);
    expect(scrollable(), 0, reason: 'the series page');
    await openHome(tester);
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(EpisodeCard), findsNothing, reason: 'a film page');
    expect(scrollable(), 0, reason: 'the film page');
  });

  uiTest('download season asks for every released episode, one by one', (
    tester,
  ) async {
    final started = <String>[];
    await openSeries(tester, api: fakeCore(started: started));
    await tester.tap(find.byTooltip('Download season 1'));
    await waitFor(
      tester,
      () async => started.length == 6,
      what: 'the six released episodes of season 1 were started',
    );
    final asked = [
      for (final body in started) jsonDecode(body) as Map<String, dynamic>,
    ];
    expect(asked.map((b) => b['season']).toSet(), {1});
    expect(asked.map((b) => b['episode']), [1, 2, 3, 4, 5, 6]);
  });

  uiTest('download season says so when no provider answers', (tester) async {
    // A provider that did not answer listed nothing, and every episode was
    // skipped as if nobody had a copy: the press did nothing, silently.
    final started = <String>[];
    await openSeries(
      tester,
      api: fakeCore(
        started: started,
        sources: const [],
        failed: const [
          {'provider': 'torrentio', 'reason': 'no answer'},
        ],
      ),
    );
    await tester.tap(find.byTooltip('Download season 1'));
    await waitFor(
      tester,
      () async =>
          find.textContaining('The season did not start').evaluate().isNotEmpty,
      what: 'the failure was reported',
    );
    expect(started, isEmpty);
  });

  uiTest('an episode on disk plays without waiting for the providers', (
    tester,
  ) async {
    // Play waited for the source list, which the core answers once every
    // provider has: without a network, after they all timed out.
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          sourcesUnanswered: true,
          downloads: [
            fakeDownload(
              id: 'bb-s1e1',
              itemId: 'tt0903747',
              season: 1,
              episode: 1,
              state: 'done',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await pressCtrlF(tester);
    await tester.enterText(find.byType(TextField), 'breaking bad');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is PosterTile && w.item.id == 'tt0903747',
      ),
    );
    // Not settled: the list of copies never arrives.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Play S1 E1'));
    await tester.pump();
    expect(playing(tester), 'bb-s1e1');
    // The client's own timeout on the list that never came; fake time.
    await tester.pump(const Duration(minutes: 1));
  });

  uiTest('a film downloads without opening the player', (tester) async {
    final started = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(started: started)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await waitFor(
      tester,
      () async =>
          find.byKey(const ValueKey('source-chip')).evaluate().isNotEmpty,
      what: 'the copies arrived',
    );
    await tester.tap(find.byTooltip('Download'));
    await waitFor(
      tester,
      () async => started.isNotEmpty,
      what: 'the download was asked for',
    );
    await tester.pumpAndSettle();
    expect(playing(tester), isNull);
  });

  uiTest('progress chooses and positions the current episode', (tester) async {
    await openSeries(
      tester,
      progress: {'tt0903747': secondEpisodeStarted(120)},
    );

    expect(find.text('Resume S1 E2'), findsOneWidget);
    expect(find.text('18:00 left'), findsOneWidget);
    final second = find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == 2,
    );
    expect(tester.widget<EpisodeCard>(second).selected, isTrue);
    expect(
      tester.getRect(second).left,
      closeTo(48, 2),
      reason: 'the next episode is the first fully visible card',
    );

    await tester.drag(find.byType(HorizontalStrip), const Offset(400, 0));
    await tester.pumpAndSettle();
    final first = find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == 1,
    );
    expect(tester.widget<EpisodeCard>(first).progress?.watched, isTrue);
    final bar = find.descendant(
      of: first,
      matching: find.byType(LinearProgressIndicator),
    );
    expect(
      tester.widget<LinearProgressIndicator>(bar).value,
      1,
      reason: 'watched is a full bar',
    );
  });

  Finder cardAt(int number) => find.byWidgetPredicate(
    (w) => w is EpisodeCard && w.episode.number == number,
  );
  EpisodeCard card(WidgetTester tester, int number) =>
      tester.widget<EpisodeCard>(cardAt(number));
  Rect stripRect(WidgetTester tester) =>
      tester.getRect(find.byType(HorizontalStrip));
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, [
    int times = 1,
  ]) async {
    for (var i = 0; i < times; i++) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
  }

  uiTest('arrows walk the season and keep a neighbour in sight', (
    tester,
  ) async {
    await openSeries(tester);
    expect(
      card(tester, 1).focusNode.hasFocus,
      isTrue,
      reason: 'the arrows work without a click first',
    );
    await press(tester, LogicalKeyboardKey.arrowRight, 5);
    expect(
      card(tester, 6).selected,
      isTrue,
      reason: 'being on a card chooses it',
    );
    expect(
      find.textContaining('Episode 6 · Crazy Handful of Nothin'),
      findsOneWidget,
    );
    expect(
      tester.getRect(cardAt(5)).left,
      greaterThanOrEqualTo(stripRect(tester).left),
      reason: 'the card before the reached one stays in sight',
    );
  });

  uiTest('the strip stays where the arrows took it', (tester) async {
    // Changing between episodes with and without a synopsis used to reset the
    // strip to episode one.
    await openSeries(tester);
    await press(tester, LogicalKeyboardKey.arrowRight, 5);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(card(tester, 5).selected, isTrue);
    expect(find.text('The story continues.'), findsOneWidget);
    expect(
      tester.getRect(cardAt(5)).right,
      lessThanOrEqualTo(stripRect(tester).right),
    );
  });

  uiTest('arrows cross into the next season and back', (tester) async {
    await openSeries(tester);
    await press(tester, LogicalKeyboardKey.arrowRight, 6);
    expect(
      find.textContaining('Episode 1 · Seven Thirty-Seven'),
      findsOneWidget,
    );
    expect(card(tester, 1).focusNode.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(card(tester, 6).selected, isTrue);
    expect(
      tester.getRect(cardAt(6)).right,
      lessThanOrEqualTo(stripRect(tester).right),
    );
  });

  for (final slow in [false, true]) {
    uiTest(
      slow
          ? 'a slow source list is said under Play'
          : 'choosing an episode keeps the source line until its list is slow',
      (tester) async {
        await openSeries(
          tester,
          api: fakeCore(
            sourcesDelay: Duration(milliseconds: slow ? 3000 : 150),
          ),
        );
        final looking = find.text('Looking for sources…');
        // The buttons beside the line move whenever its width changes.
        Rect actions() => tester.getRect(find.byType(LibraryActions));
        await pumpFor(tester, const Duration(seconds: 4));
        final before = actions();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        for (var i = 0; i < 2; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          expect(looking, findsNothing);
          expect(actions(), before);
        }
        await tester.pump(const Duration(milliseconds: 200));
        expect(looking, slow ? findsOneWidget : findsNothing);
      },
    );
  }

  uiTest('Enter plays the episode the arrows reached', (tester) async {
    await openSeries(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      tester.widget<PlayerStandIn>(find.byType(PlayerStandIn)).screen.title,
      contains('S01E02'),
    );
  });
  uiTest('Play on a card that is not the chosen one plays that card', (
    tester,
  ) async {
    final started = <String>[];
    await openSeries(
      tester,
      api: fakeCore(
        started: started,
        sourcesDelay: const Duration(milliseconds: 800),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(
        find.byWidgetPredicate(
          (w) => w is EpisodeCard && w.episode.number == 3,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Play episode 3'));
    await waitFor(
      tester,
      () async => started.isNotEmpty,
      what: 'Play on episode 3 asked the core for a download',
      timeout: const Duration(seconds: 5),
    );
    expect(jsonDecode(started.single)['episode'], 3);
  });

  uiTest('progress failures do not replace the home or item screen', (
    tester,
  ) async {
    await tester.pumpWidget(testApp(api: fakeCore(progressFails: true)));
    await tester.pumpAndSettle();
    expect(find.text('Popular films'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);

    await pressCtrlF(tester);
    await tester.enterText(find.byType(TextField), 'breaking bad');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is PosterTile && w.item.id == 'tt0903747',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Breaking Bad'), findsWidgets);
    expect(find.byType(EpisodeCard), findsWidgets);
    expect(find.text('Try again'), findsNothing);
  });

  uiTest('a copy this machine cannot decode is marked, and not played', (
    tester,
  ) async {
    // Play used to choose an hevc/dts copy before checking decoders, producing
    // black video and no sound.
    DeviceDecoders.instance = DeviceDecoders(
      ask: () async =>
          '[{"codec":"h264","driver":"h264","description":"H.264"},'
          '{"codec":"ac3","driver":"ac3","description":"AC-3"}]',
      osRelease: () async => 'ID=fedora\n',
    );
    addTearDown(() => DeviceDecoders.instance = DeviceDecoders());

    final started = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(started: started)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-chip')));
    await tester.pumpAndSettle();
    expect(
      find.text('no hevc here'),
      findsOneWidget,
      reason: 'the row says what this machine would make of it',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('no hevc here'), findsNothing, reason: 'Esc closes it');

    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => started.isNotEmpty,
      what: 'Play asked the core for a download',
    );
    expect(started, isNotEmpty, reason: 'Play started something');
    expect(
      started.single,
      contains('abc'),
      reason: 'the copy it can decode, not the one ranked first',
    );
  });

  uiTest('the sources drawer puts what is here first, then sharpest', (
    tester,
  ) async {
    Map<String, dynamic> copy(
      String hash,
      String resolution, {
      String local = '',
      bool lastUsed = false,
      List<String> languages = const ['en'],
    }) => {
      'providerId': 'torrentio',
      'rawName': 'Night of the Living Dead 1968 $resolution $hash',
      'release': {'resolution': resolution, 'source': 'WEB-DL', 'group': hash},
      'locator': {'scheme': 'torrent', 'infoHash': hash},
      'size': 1024 * 1024 * 1024,
      'seeders': 10,
      'languages': languages,
      'local': local,
      'lastUsed': lastUsed,
    };
    final started = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          started: started,
          sources: [
            copy('disk', '720p', local: 'done'),
            copy('pack', '720p', lastUsed: true),
            copy('sharp', '2160p', languages: ['en', 'ru', 'ja', 'de', 'fr']),
            copy('mid', '1080p'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    await waitFor(
      tester,
      () async =>
          find.byKey(const ValueKey('source-chip')).evaluate().isNotEmpty,
      what: 'the copies arrived',
    );
    await tester.tap(find.byKey(const ValueKey('source-chip')));
    await tester.pumpAndSettle();

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('On disk'), lessThan(top('2160p')));
    expect(top('2160p'), lessThan(top('1080p')));
    expect(top('1080p'), lessThan(top('720p')));
    expect(top('720p · disk · WEB-DL'), lessThan(top('2160p')));
    expect(find.text('1.0 GB · on disk'), findsOneWidget);
    expect(find.text('last used'), findsOneWidget);
    expect(
      find.text('+2'),
      findsOneWidget,
      reason: 'five languages, three shown',
    );

    await tester.tap(find.text('mid · WEB-DL'));
    await tester.pumpAndSettle();
    expect(find.text('On disk'), findsNothing, reason: 'a pick closes it');
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => started.isNotEmpty,
      what: 'Play asked the core for a download',
    );
    expect(started.single, contains('mid'), reason: 'Play starts the pick');
  });

  uiTest('a provider that refuses is said as a block, with Play off', (
    tester,
  ) async {
    // A 403 used to look like an empty catalogue, with a Play button that did
    // nothing.
    final asked = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          sources: const [],
          failed: const [
            {'provider': 'Torrentio', 'reason': '403 Forbidden', 'status': 403},
          ],
          sourceCalls: asked,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await waitFor(
      tester,
      () async => find
          .text('Torrentio is blocking requests from here (403)')
          .evaluate()
          .isNotEmpty,
      what: 'the refusal in place of the source line',
    );
    final play = tester.widget<FilledButton>(
      find.ancestor(of: find.text('Play'), matching: find.byType(FilledButton)),
    );
    expect(play.onPressed, isNull, reason: 'nothing to start');
    final before = asked.length;
    await tester.tap(find.text('Try again'));
    await waitFor(
      tester,
      () async => asked.length > before,
      what: 'Try again asked the core again',
    );
  });

  uiTest('with no source addon, Play says so and leads to Sources', (
    tester,
  ) async {
    // A fresh install has no source addon; "No copies found" would blame the
    // title.
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          sources: const [],
          addons: [
            for (final addon in fakeAddons)
              if (!(addon['resources'] as List).contains('stream')) addon,
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await waitFor(
      tester,
      () async => find.text('No source addons').evaluate().isNotEmpty,
      what: 'the missing addon in place of the source line',
    );
    await tester.tap(find.text('Add one'));
    await tester.pumpAndSettle();
    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    final top = tester
        .getRect(find.byKey(const ValueKey('settings:sources')))
        .top;
    expect(top, inInclusiveRange(0, window.height));
  });
}
