// Playback, opening files and moving to the next episode.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:lumeo/ui/player/episode_frames.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:lumeo/ui/player/panels.dart';
import 'package:lumeo/ui/widgets/download_glyph.dart';
import 'package:lumeo/ui/widgets/episode_card.dart';

import 'helpers.dart';

void playbackTests() {
  testWidgets('a film the core cannot serve yet is never handed to mpv', (
    tester,
  ) async {
    // The core can know a file name before receiving any bytes; opening it then
    // made mpv report no picture.
    final asked = <HttpRequest>[];
    final core = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    core.listen(asked.add);
    addTearDown(() => core.close(force: true));
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload(ready: false)],
          baseUrl: 'http://127.0.0.1:${core.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await pumpFor(tester, const Duration(seconds: 6));
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(asked, isEmpty, reason: 'nothing to open, so nothing was opened');
    expect(
      find.text('This copy would not start'),
      findsNothing,
      reason: 'nobody has said anything about this copy',
    );
    expect(
      find
          .byType(CircularProgressIndicator)
          .evaluate()
          .where(
            (e) => e.findAncestorWidgetOfExactType<DownloadGlyph>() == null,
          ),
      hasLength(1),
      reason:
          'and the screen says it is still coming, besides the '
          'download button',
    );
  });

  testWidgets('a film that will not start is reported in the end', (
    tester,
  ) async {
    // A stream can fail while opening; retry before declaring it unplayable.
    // Shorten openPatience so the test need not wait thirty seconds.
    final patience = openPatience;
    openPatience = const Duration(seconds: 3);
    addTearDown(() => openPatience = patience);
    await tester.pumpWidget(
      testApp(api: fakeCore(downloads: [fakeDownload()])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerOpened(tester);
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      find.text('This copy would not start'),
      findsNothing,
      reason: 'one failure is not a verdict',
    );
    await waitFor(
      tester,
      () async => find.text('This copy would not start').evaluate().isNotEmpty,
      what: 'the verdict once the patience ran out',
    );
    expect(
      find.text('Try again'),
      findsOneWidget,
      reason: 'there is something to do about it',
    );
  });

  testWidgets('an error mpv logs while it finds a decoder does not reopen '
      'the film', (tester) async {
    // Windows logs "Failed to allocate AVHWDeviceContext." before falling back
    // to software. That decoder error used to reopen the film repeatedly; vd
    // reproduces its log prefix.
    final server = await serveFilm();
    final download = fakeDownload(ready: false);
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [download],
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await pumpFor(tester, const Duration(seconds: 1));
    final scripts = Directory.systemTemp.createTempSync('lumeo-vd');
    addTearDown(() => scripts.deleteSync(recursive: true));
    final script = File('${scripts.path}/vd.lua')
      ..writeAsStringSync(
        'local loads = 0\n'
        'mp.add_hook("on_load", 50, function()\n'
        '  loads = loads + 1\n'
        '  mp.set_property_native("user-data/loads", loads)\n'
        '  mp.msg.error("Failed to allocate AVHWDeviceContext.")\n'
        'end)\n',
      );
    final mpv = mpvOnScreen(tester);
    await mpv.command(['load-script', script.path]);
    download['ready'] = true;
    await waitFor(
      tester,
      () async => (double.tryParse(await mpv.getProperty('time-pos')) ?? 0) > 3,
      what: 'the film playing',
    );
    expect(
      await mpv.getProperty('user-data/loads'),
      '1',
      reason: 'opened once, not again for a decoder mpv did without',
    );
    expect(find.text('This copy would not start'), findsNothing);
  });

  testWidgets('a file opened with Lumeo plays at once', (tester) async {
    // "Open with Lumeo" used to ignore the file argument.
    final server = await serveFilm();
    final opened = <String>[];
    await tester.pumpWidget(
      testApp(
        open: testFilm().path,
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
          opened: opened,
        ),
      ),
    );
    await pumpFor(tester, const Duration(seconds: 1));
    expect(opened, [testFilm().path]);
    final mpv = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async => (double.tryParse(await mpv.getProperty('time-pos')) ?? 0) > 0,
      what: 'the file played',
    );
    expect(await mpv.getProperty('hwdec'), 'auto-safe');
  });

  testWidgets('a file opened while the app runs plays in it', (tester) async {
    // A second "Open with Lumeo" used to launch another window instead of using
    // dev.lumeo/open.
    final server = await serveFilm();
    final opened = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
          opened: opened,
        ),
      ),
    );
    await homeShown(tester);
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'dev.lumeo/open',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('open', testFilm().path),
      ),
      (_) {},
    );
    await pumpFor(tester, const Duration(seconds: 1));
    expect(opened, [testFilm().path]);
    expect(find.byType(PlayerScreen), findsOneWidget);
  });

  testWidgets('an episode on disk starts the next one downloading, unless '
      'prefetch is off', (tester) async {
    Future<List<String>> play({required bool prefetch}) async {
      final started = <String>[];
      await openSeries(
        tester,
        api: fakeCore(
          started: started,
          preferences: {
            'subtitleLanguages': ['en'],
            'prefetch': prefetch,
          },
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
      );
      await tester.tap(find.text('Play S1 E1'));
      await playerOpened(tester);
      return started;
    }

    bool asksForNext(List<String> started) =>
        started.map(jsonDecode).any((body) => body['episode'] == 2);
    bool prefetched(List<String> started) => started
        .map(jsonDecode)
        .any((body) => body['episode'] == 2 && body['prefetch'] == true);

    var asked = await play(prefetch: true);
    await waitFor(
      tester,
      () async => prefetched(asked),
      what: 'the next episode was prefetched',
    );

    await tester.tap(find.byTooltip('On disk'));
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(find.text('This episode'), findsOneWidget);
    expect(find.textContaining('Next · E2'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await pumpFor(tester, const Duration(milliseconds: 500));

    asked = await play(prefetch: false);
    await pumpFor(tester, const Duration(seconds: 5));
    expect(asksForNext(asked), isFalse);
  });

  testWidgets('a prefetch the core has no room for can be downloaded anyway', (
    tester,
  ) async {
    final started = <String>[];
    await openSeries(
      tester,
      api: fakeCore(
        started: started,
        prefetchRefused: true,
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
    );
    await tester.tap(find.text('Play S1 E1'));
    await playerOpened(tester);
    await waitFor(
      tester,
      () async => started.any((b) => b.contains('"prefetch":true')),
      what: 'the next episode was prefetched',
    );
    await tester.tap(find.byTooltip('On disk'));
    await waitFor(
      tester,
      () async => find.text('No room').evaluate().isNotEmpty,
      what: 'the refusal is shown',
    );
    started.clear();
    await tester.tap(find.text('Download anyway'));
    await waitFor(
      tester,
      () async => started.isNotEmpty,
      what: 'the next episode was asked for again',
    );
    final body = jsonDecode(started.single) as Map<String, dynamic>;
    expect(body['episode'], 2);
    expect(body.containsKey('prefetch'), isFalse);
  });

  testWidgets('a prefetch no provider answered is asked for again', (
    tester,
  ) async {
    // Without a network every provider fails and the list comes back empty;
    // the prefetch took that for "no copy" and never asked again.
    final retry = prefetchRetry;
    prefetchRetry = const Duration(seconds: 1);
    addTearDown(() => prefetchRetry = retry);
    final started = <String>[];
    final sources = <Map<String, dynamic>>[];
    final failed = [
      {'provider': 'torrentio', 'reason': 'no answer'},
    ];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          started: started,
          sources: sources,
          failed: failed,
          downloads: [
            fakeDownload(
              id: 'bb-s1e1',
              itemId: 'tt0903747',
              season: 1,
              episode: 1,
              state: 'done',
              updatedAt: DateTime.now(),
            ),
          ],
        ),
      ),
    );
    await homeShown(tester);
    final panel = find.byKey(const ValueKey('downloads'));
    await waitFor(
      tester,
      () async => panel.evaluate().isNotEmpty,
      what: 'the downloads button',
    );
    await tester.tap(panel);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download:bb-s1e1')));
    await playerOpened(tester);
    await tester.tap(find.byTooltip('On disk'));
    await waitFor(
      tester,
      () async => find.text('Failed').evaluate().isNotEmpty,
      what: 'the prefetch failed',
    );
    failed.clear();
    sources.addAll(fakeSources);
    await waitFor(
      tester,
      () async => started.any((b) => b.contains('"prefetch":true')),
      what: 'the prefetch was asked for again',
    );
  });

  testWidgets('an episode that runs out starts the next one', (tester) async {
    // 0.1.19 froze on the first frame despite green unit tests; this runs real
    // libmpv through episode handoff. With no ending chapter, mpv holds the
    // last frame for the five-second next-episode countdown.
    final server = await serveFilm();
    final started = <String>[];
    final progressCalls = <String>[];
    final api = fakeCore(
      started: started,
      progressCalls: progressCalls,
      downloads: [
        fakeDownload(id: 'bb-s1e1', itemId: 'tt0903747', season: 1, episode: 1),
        fakeDownload(id: 'bb-s1e2', itemId: 'tt0903747', season: 1, episode: 2),
      ],
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    await openSeries(tester, api: api);
    await tester.tap(find.text('Play S1 E1'));
    await pumpFor(tester, const Duration(seconds: 1));

    final first = mpvOnScreen(tester);
    Future<double> positionOf(NativePlayer mpv) async =>
        double.tryParse(await mpv.getProperty('time-pos')) ?? 0;
    await waitFor(
      tester,
      () async => await positionOf(first) > 0.5,
      what: 'the first episode played',
    );
    expect(
      tester.widget<PlayerScreen>(find.byType(PlayerScreen)).download,
      'bb-s1e1',
    );

    // The handoff starts at the last frame of this thirty-second film.
    await first.command(['seek', '29', 'absolute']);
    await waitFor(
      tester,
      () async => await first.getProperty('eof-reached') == 'yes',
      what: 'the film played out to its end',
    );
    await waitFor(
      tester,
      () async => find.byType(NextEpisodeCard).evaluate().isNotEmpty,
      what: 'the next episode card appeared over the held frame',
    );
    expect(find.text("Episode 2 · Cat's in the Bag..."), findsOneWidget);

    // media_kit once stopped reporting `completed` after replaying from the
    // held frame.
    await first.command(['seek', '27', 'absolute']);
    await first.command(['set', 'pause', 'no']);
    await waitFor(
      tester,
      () async => find.byType(NextEpisodeCard).evaluate().isEmpty,
      what: 'seeking back took the card away',
    );
    await waitFor(
      tester,
      () async => find.byType(NextEpisodeCard).evaluate().isNotEmpty,
      what: 'the card came back at the end',
    );

    await waitFor(
      tester,
      () async => started.any((body) {
        final asked = jsonDecode(body) as Map<String, dynamic>;
        return asked['season'] == 1 && asked['episode'] == 2;
      }),
      what: 'the player ordered a copy of the next episode',
    );

    await waitFor(
      tester,
      () async =>
          find.byType(PlayerScreen).evaluate().isNotEmpty &&
          tester.widget<PlayerScreen>(find.byType(PlayerScreen)).download ==
              'bb-s1e2',
      what: 'the player moved on to the next episode',
    );
    await tester.sendEventToBinding(
      TestPointer(99, PointerDeviceKind.mouse).hover(const Offset(400, 400)),
    );
    await waitFor(
      tester,
      () async => find
          .textContaining('S1 E2', findRichText: true)
          .evaluate()
          .isNotEmpty,
      what: 'the bar says which episode this is now',
    );
    await waitFor(
      tester,
      () async => await positionOf(mpvOnScreen(tester)) > 0.5,
      what: 'the next episode is playing, not merely opened',
    );

    // Anime endings can start at 87%, before the core latches watched at 90%.
    // Finishing must mark the episode watched instead of offering its credits
    // in Continue watching.
    expect(
      progressCalls.any((body) {
        final sent = jsonDecode(body) as Map<String, dynamic>;
        return sent['season'] == 1 &&
            sent['episode'] == 1 &&
            sent['watched'] == true;
      }),
      isTrue,
      reason: 'the episode moved on from was reported as watched',
    );
  });

  testWidgets('the player episodes panel starts a released episode', (
    tester,
  ) async {
    final started = <String>[];
    final api = fakeCore(
      started: started,
      downloads: [
        fakeDownload(
          id: 'ep1',
          itemId: 'tt0903747',
          season: 1,
          episode: 1,
          ready: false,
        ),
        fakeDownload(
          id: 'ep2',
          itemId: 'tt0903747',
          season: 1,
          episode: 2,
          ready: false,
        ),
      ],
    );
    await openSeries(tester, api: api);
    await tester.tap(find.text('Play S1 E1'));
    await waitFor(
      tester,
      () async => find.byType(PlayerScreen).evaluate().isNotEmpty,
      what: 'the first episode opened',
    );
    await waitFor(
      tester,
      () async => find.byTooltip('Episodes').evaluate().isNotEmpty,
      what: 'the bar knows this is an episode',
    );
    await tester.tap(find.byTooltip('Episodes'));
    await waitFor(
      tester,
      () async => find.byType(EpisodesPanel).evaluate().isNotEmpty,
      what: 'the episodes panel opened',
    );
    expect(find.text('Season 1 ▾'), findsOneWidget);
    expect(find.text("2 · Cat's in the Bag..."), findsOneWidget);
    await tester.tap(find.text("2 · Cat's in the Bag..."));
    await waitFor(
      tester,
      () async =>
          tester.widget<PlayerScreen>(find.byType(PlayerScreen)).download ==
          'ep2',
      what: 'the selected episode opened',
    );
    expect(jsonDecode(started.last)['episode'], 2);
  });

  testWidgets('tracks picked by hand carry over to the next episode by title', (
    tester,
  ) async {
    // `slang=eng` selects the default subtitle; "English Honorifics" needs a
    // title match.
    final server = await serveFilm(tracksFilm());
    final patches = <String>[];
    await openSeries(
      tester,
      api: fakeCore(
        choicePatches: patches,
        downloads: [
          fakeDownload(
            id: 'bb-s1e1',
            itemId: 'tt0903747',
            season: 1,
            episode: 1,
          ),
          fakeDownload(
            id: 'bb-s1e2',
            itemId: 'tt0903747',
            season: 1,
            episode: 2,
          ),
        ],
        baseUrl: 'http://127.0.0.1:${server.port}',
      ),
    );
    await tester.tap(find.text('Play S1 E1'));
    await pumpFor(tester, const Duration(seconds: 1));

    final first = mpvOnScreen(tester);
    Future<String> current(NativePlayer mpv, String type) =>
        mpv.getProperty('current-tracks/$type/title');
    Future<String> idOf(NativePlayer mpv, String type, String title) async {
      final tracks = jsonDecode(await mpv.getProperty('track-list')) as List;
      return '${tracks.firstWhere((t) => t['type'] == type && t['title'] == title)['id']}';
    }

    await waitFor(
      tester,
      () async =>
          (double.tryParse(await first.getProperty('time-pos')) ?? 0) > 0.5,
      what: 'the first episode played',
    );
    expect(await current(first, 'audio'), 'English Dub');
    expect(await current(first, 'sub'), 'English Full');
    await pumpFor(tester, const Duration(seconds: 1));
    expect(patches, isEmpty, reason: 'what mpv picked by itself is not a pick');

    // mpv owns these key bindings; the screen learns the result from
    // properties.
    await first.setProperty('aid', await idOf(first, 'audio', 'Japanese'));
    await first.setProperty(
      'sid',
      await idOf(first, 'sub', 'English Honorifics'),
    );
    await waitFor(
      tester,
      () async => patches.length >= 2,
      what: 'both picks reached the core',
    );
    expect(patches.map(jsonDecode), [
      {
        'audio': {'language': 'jpn', 'title': 'Japanese'},
      },
      {
        'subtitle': {'language': 'eng', 'title': 'English Honorifics'},
      },
    ]);

    // The core carries track choices to a new player screen on the next
    // episode.
    await playerKeysReady(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.byType(PlayerScreen), findsNothing);
    final secondCard = find.byWidgetPredicate(
      (w) => w is EpisodeCard && w.episode.number == 2,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: tester.getCenter(secondCard));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Play episode 2'));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      tester.widget<PlayerScreen>(find.byType(PlayerScreen)).download,
      'bb-s1e2',
    );
    final second = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async =>
          (double.tryParse(await second.getProperty('time-pos')) ?? 0) > 0.5,
      what: 'the next episode is playing',
    );
    expect(await current(second, 'audio'), 'Japanese');
    expect(
      await current(second, 'sub'),
      'English Honorifics',
      reason: 'the title chose between the two English tracks',
    );
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      patches,
      hasLength(2),
      reason: 'the selection the screen made itself was not written back',
    );

    await second.setProperty('sid', 'no');
    await waitFor(
      tester,
      () async => patches.length == 3,
      what: 'turning the subtitle off reached the core',
    );
    expect(jsonDecode(patches.last), {
      'subtitle': {'off': true},
    });
  });

  testWidgets('the player waits on a core that has not answered yet', (
    tester,
  ) async {
    // media_kit sets a five-second network timeout, shorter than a slow torrent
    // piece. A silent test server lets this check mpv received the longer
    // timeout without waiting it out.
    final asked = <HttpRequest>[];
    final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    stalled.listen(asked.add);
    addTearDown(() => stalled.close(force: true));
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${stalled.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => asked.isNotEmpty,
      what: 'mpv asked the core for the file',
    );
    expect(
      double.parse(await mpvOnScreen(tester).getProperty('network-timeout')),
      60,
      reason: 'mpv waits on the core as long as a swarm may take',
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
    // A missing still is represented by an address with no listener.
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
}
