// A title's page: seasons, episode cards, downloads and the sources drawer.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/platform/decoders.dart';
import 'package:lumeo/ui/player/episode_frames.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:lumeo/ui/screens/item_screen.dart';
import 'package:lumeo/ui/widgets/episode_card.dart';
import 'package:lumeo/ui/widgets/horizontal_strip.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';

import 'fake_core.dart';

import 'helpers.dart';

void titleTests() {
  testWidgets('a new episode opens its title on that episode', (tester) async {
    await tester.pumpWidget(
      LumeoApp(
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

  testWidgets('the bar takes a ground once the page scrolls under it', (
    tester,
  ) async {
    // It never did on this platform. A vertical ScrollView adopts the primary
    // controller by itself on phones only, so the shell's controller had no
    // position attached and the offset it watched stayed zero for the life of
    // the window: the wordmark and the search field sat over whatever text of
    // the page happened to be passing under them.
    await openHome(tester);
    expect(
      tester.widget<TopBar>(find.byType(TopBar)).scrolled,
      isFalse,
      reason: 'at the top it is over artwork, and shows nothing',
    );
    // The wheel, over a shelf, which is where a pointer actually rests.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(find.byType(PosterTile).first));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pumpAndSettle();
    expect(tester.widget<TopBar>(find.byType(TopBar)).scrolled, isTrue);
  });

  testWidgets('a season is on screen without scrolling', (tester) async {
    // The banner was 70% of the window and the cast sat under it, so the
    // seasons and the episode strip — the reason a series page is opened at
    // all — started below the fold: the page looked like a poster with
    // nothing on it until you scrolled.
    await openHome(tester);
    await pressCtrlF(tester);
    await tester.enterText(find.byType(TextField), 'breaking bad');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    // By which title it is, not by where it landed: the grid is ranked the
    // same way the search panel is, so the position of a tile is a property of
    // what the catalogue answered rather than of the order it was asked in.
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is PosterTile && w.item.id == 'tt0903747',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EpisodeCard), findsWidgets, reason: 'a series page');
    final view = tester.view;
    final fold = view.physicalSize.height / view.devicePixelRatio;
    final card = tester.getRect(find.byType(EpisodeCard).first);
    expect(
      card.bottom,
      lessThanOrEqualTo(fold),
      reason:
          'the whole card, not the top of it: a strip cut by the bottom '
          'of the window is a strip nobody knows is there',
    );
  });

  testWidgets('a title page that fits the window does not scroll', (
    tester,
  ) async {
    // 56 points under the strip that the banner was not measured to leave,
    // so both pages moved under the wheel with nothing below to move to.
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

  testWidgets('download season asks for every released episode, one by one', (
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

  testWidgets('a film downloads without opening the player', (tester) async {
    final started = <String>[];
    await tester.pumpWidget(LumeoApp(api: fakeCore(started: started)));
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
    expect(find.byType(PlayerScreen), findsNothing);
  });

  testWidgets('progress chooses and positions the current episode', (
    tester,
  ) async {
    await openSeries(
      tester,
      progress: {
        'tt0903747': [
          watchEntry(
            episode: 1,
            position: 1200,
            duration: 1200,
            watched: true,
            updatedAt: '2026-09-20T11:00:00Z',
          ),
          watchEntry(
            episode: 2,
            position: 120,
            duration: 1200,
            watched: false,
            updatedAt: '2026-09-20T12:00:00Z',
          ),
        ],
      },
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

  testWidgets('episode marks read over a real still', (tester) async {
    // The suite's stills were grey tiles, and marks that looked fine on them
    // were heavy boxes and mush over a real picture. So this one serves a
    // picture, and leaves the screen in build/ui-shots for a look by eye.
    late final List<int> still;
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      const size = Size(640, 360);
      Canvas(recorder).drawRect(
        Offset.zero & size,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            size.bottomRight(Offset.zero),
            const [Color(0xFFE8C9A0), Color(0xFF3A5A78), Color(0xFF101418)],
            const [0, 0.5, 1],
          ),
      );
      final image = await recorder.endRecording().toImage(640, 360);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      still = png!.buffer.asUint8List();
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(still)
        ..close();
    });
    await openSeries(
      tester,
      api: fakeCore(
        stills: 'http://127.0.0.1:${server.port}',
        preferences: const {
          'subtitleLanguages': ['en'],
          'episodeArtwork': 'show',
        },
        downloads: [
          fakeDownload(
            itemId: 'tt0903747',
            season: 1,
            episode: 1,
            state: 'done',
          ),
          fakeDownload(id: 'd2', itemId: 'tt0903747', season: 1, episode: 3),
        ],
        progress: {
          'tt0903747': [
            watchEntry(
              episode: 1,
              position: 1200,
              duration: 1200,
              watched: true,
              updatedAt: '2026-09-20T11:00:00Z',
            ),
            watchEntry(
              episode: 2,
              position: 500,
              duration: 1200,
              watched: false,
              updatedAt: '2026-09-20T12:00:00Z',
            ),
          ],
        },
      ),
    );
    await tester.drag(find.byType(HorizontalStrip), const Offset(400, 0));
    await pumpFor(tester, const Duration(seconds: 1));
    Finder card(int number) => find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == number,
    );
    double? bar(int number) => tester
        .widget<LinearProgressIndicator>(
          find.descendant(
            of: card(number),
            matching: find.byType(LinearProgressIndicator),
          ),
        )
        .value;
    expect(bar(1), 1, reason: 'watched is a full bar, not a check');
    expect(
      find.descendant(of: card(1), matching: find.byIcon(Icons.check)),
      findsNothing,
    );
    expect(
      find.descendant(of: card(1), matching: find.byIcon(Icons.download)),
      findsOneWidget,
      reason: 'on disk',
    );
    expect(bar(2), closeTo(500 / 1200, 0.01));
    expect(
      find.descendant(
        of: card(3),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
      reason: 'on its way',
    );

    final view = tester.binding.renderViews.first;
    final layer = view.debugLayer! as OffsetLayer;
    await tester.runAsync(() async {
      final image = await layer.toImage(view.paintBounds);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/ui-shots/episode-marks.png')
        ..parent.createSync(recursive: true);
      file.writeAsBytesSync(png!.buffer.asUint8List());
      debugPrint('shot: ${file.absolute.path}');
    });
  });

  testWidgets('arrows walk the season, keep a neighbour in sight, and Enter '
      'plays', (tester) async {
    await openSeries(tester);
    EpisodeCard card(int number) => tester.widget<EpisodeCard>(
      find.byWidgetPredicate(
        (w) => w is EpisodeCard && w.episode.number == number,
      ),
    );
    Finder cardAt(int number) => find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == number,
    );
    final strip = tester.getRect(find.byType(HorizontalStrip));

    expect(
      card(1).focusNode.hasFocus,
      isTrue,
      reason: 'the arrows work without a click first',
    );
    expect(card(1).selected, isTrue);
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(card(6).selected, isTrue, reason: 'being on a card chooses it');
    expect(
      find.textContaining('Episode 6 · Crazy Handful of Nothin'),
      findsOneWidget,
    );
    expect(
      tester.getRect(cardAt(5)).left,
      greaterThanOrEqualTo(strip.left),
      reason: 'the card before the reached one stays in sight',
    );

    // Episode 6 has no synopsis and 5 has one. The line above the strip used
    // to appear only with a synopsis, which rebuilt the strip under it and
    // scrolled it back to the first episode.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(card(5).selected, isTrue);
    expect(find.text('The story continues.'), findsOneWidget);
    expect(
      tester.getRect(cardAt(5)).right,
      lessThanOrEqualTo(strip.right),
      reason: 'the strip stayed where the keyboard took it',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Episode 1 · Seven Thirty-Seven'),
      findsOneWidget,
      reason: 'right past the last episode opens the next season',
    );
    expect(card(1).focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(card(6).selected, isTrue, reason: 'and left comes back');
    expect(tester.getRect(cardAt(6)).right, lessThanOrEqualTo(strip.right));

    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    }
    await tester.pumpAndSettle();
    expect(card(2).selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      tester.widget<PlayerScreen>(find.byType(PlayerScreen)).title,
      contains('S01E02'),
    );
  });

  testWidgets('Play on a card that is not the chosen one plays that card', (
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

  testWidgets('progress failures do not replace the home or item screen', (
    tester,
  ) async {
    await tester.pumpWidget(LumeoApp(api: fakeCore(progressFails: true)));
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

  testWidgets('episode artwork preference hides and blurs spoilers', (
    tester,
  ) async {
    final progress = {
      'tt0903747': [
        watchEntry(
          episode: 1,
          position: 1200,
          duration: 1200,
          watched: true,
          updatedAt: '2026-09-20T11:00:00Z',
        ),
        watchEntry(
          episode: 2,
          position: 120,
          duration: 1200,
          watched: false,
          updatedAt: '2026-09-20T12:00:00Z',
        ),
      ],
    };
    await openSeries(
      tester,
      progress: progress,
      preferences: const {
        'subtitleLanguages': ['en'],
        'episodeArtwork': 'hide',
      },
    );
    expect(
      find.descendant(
        of: find.byType(EpisodeCard),
        matching: find.byType(Image),
      ),
      findsNothing,
    );

    // A still that never arrives is not a spoiler. The fixtures point every
    // still at a port nothing listens on, and the blur used to wrap the
    // placeholder that took its place, episode number and all.
    await openSeries(
      tester,
      progress: progress,
      preferences: const {
        'subtitleLanguages': ['en'],
        'episodeArtwork': 'blur',
      },
    );
    final second = find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == 2,
    );
    expect(
      find.descendant(of: second, matching: find.byType(ImageFiltered)),
      findsNothing,
      reason: 'a placeholder for a still that failed is not blurred',
    );

    // One that does arrive is: served from a socket of this test's own.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(base64Decode(pngFourByFour))
        ..close();
    });
    await openSeries(
      tester,
      progress: progress,
      preferences: const {
        'subtitleLanguages': ['en'],
        'episodeArtwork': 'blur',
      },
      stills: 'http://127.0.0.1:${server.port}',
    );
    expect(
      find.descendant(of: second, matching: find.byType(ImageFiltered)),
      findsOneWidget,
      reason: 'the unwatched episode is still a spoiler',
    );
    await tester.drag(find.byType(HorizontalStrip), const Offset(400, 0));
    await tester.pumpAndSettle();
    final first = find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == 1,
    );
    expect(
      find.descendant(of: first, matching: find.byType(ImageFiltered)),
      findsNothing,
      reason: 'watched artwork stays sharp',
    );
  });

  testWidgets('an episode on disk without a still shows a frame of its file', (
    tester,
  ) async {
    final server = await serveFilm();
    // The real cache: a frame left by an earlier run would pass this test.
    final taken = File('${EpisodeFrames.cacheDirectory()}/tt0903747-s1e2.jpg');
    if (taken.existsSync()) taken.deleteSync();
    addTearDown(() {
      if (taken.existsSync()) taken.deleteSync();
    });
    // Episode 2's still points at a port nothing listens on, as metahub's
    // missing ones effectively do.
    await openSeries(
      tester,
      api: fakeCore(
        downloads: [
          fakeDownload(
            id: 'e2',
            itemId: 'tt0903747',
            state: 'done',
            season: 1,
            episode: 2,
          ),
        ],
        baseUrl: 'http://127.0.0.1:${server.port}',
      ),
    );
    bool fromFile(int number) => tester
        .widgetList<Image>(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is EpisodeCard && w.episode.number == number,
            ),
            matching: find.byType(Image),
          ),
        )
        .any(
          (image) =>
              image.image is ResizeImage &&
              (image.image as ResizeImage).imageProvider is FileImage,
        );
    await waitFor(
      tester,
      () async => fromFile(2),
      what: 'a frame of the episode on disk on its card',
    );
    expect(taken.existsSync(), isTrue);
    expect(fromFile(1), isFalse, reason: 'episode 1 is not on disk');
  });

  testWidgets('a copy this machine cannot decode is marked, and not played', (
    tester,
  ) async {
    // The whole point of asking mpv before anything is chosen. The sharpest
    // copy is hevc with dts sound, and on a machine with neither it is a black
    // screen with no sound — which is what Play used to start, with the news
    // arriving after the download had begun.
    DeviceDecoders.instance = DeviceDecoders(
      ask: () async =>
          '[{"codec":"h264","driver":"h264","description":"H.264"},'
          '{"codec":"ac3","driver":"ac3","description":"AC-3"}]',
      osRelease: () async => 'ID=fedora\n',
    );
    addTearDown(() => DeviceDecoders.instance = DeviceDecoders());

    final started = <String>[];
    await tester.pumpWidget(LumeoApp(api: fakeCore(started: started)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    // The line under Play opens the drawer of copies.
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

  testWidgets('the sources drawer puts what is here first, then sharpest', (
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
      LumeoApp(
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
    // The list waits for mpv's decoder answer before it is shown.
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

  testWidgets('a provider that refuses is said as a block, with Play off', (
    tester,
  ) async {
    // An empty list used to read "Nothing to play yet — no provider has
    // this one" whatever the reason, with a Play button that did nothing. A
    // 403 is not an empty catalogue: it says so, and asking again is offered.
    final asked = <String>[];
    await tester.pumpWidget(
      LumeoApp(
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

  testWidgets('with no source addon, Play says so and leads to Sources', (
    tester,
  ) async {
    // No source ships with the app, so this is where a fresh install starts:
    // "No copies found" would blame the title for what is a missing addon.
    await tester.pumpWidget(
      LumeoApp(
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
    // On screen, not merely built: settings opened where an addon is added.
    final window = tester.view.physicalSize / tester.view.devicePixelRatio;
    final top = tester
        .getRect(find.byKey(const ValueKey('settings:sources')))
        .top;
    expect(top, inInclusiveRange(0, window.height));
  });
}
