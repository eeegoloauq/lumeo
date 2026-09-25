// Getting a film to play and on to the next one: waits, failures, files opened with Lumeo, the next episode.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:lumeo/ui/player/panels.dart';
import 'package:lumeo/ui/widgets/download_glyph.dart';
import 'package:lumeo/ui/widgets/episode_card.dart';

import 'fake_core.dart';

import 'helpers.dart';

void playbackTests() {
  testWidgets('the wait for a film stands on the title\'s artwork', (
    tester,
  ) async {
    // Black under the name of the film, until the first frame, was what the
    // wait looked like. Every player puts the title's artwork there, dimmed:
    // it says which film this is while nothing else can, and the first frame
    // fades in over it rather than flashing on over black. The picture has to
    // be the size of the screen — the switcher that fades it out lays its
    // child out loose, and an image left to itself takes its own proportions.
    //
    // Served from a socket of this test's own: the fixtures point every other
    // picture at a port nothing listens on, and Image.network does not go
    // through the fake core.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(base64Decode(pngFourByFour))
        ..close();
    });
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          background: 'http://127.0.0.1:${server.port}/backdrop.png',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => find
          .descendant(
            of: find.byType(PlayerScreen),
            matching: find.byType(Image),
          )
          .evaluate()
          .isNotEmpty,
      what: 'the player is up with the artwork under the wait',
    );
    expect(find.byType(PlayerScreen), findsOneWidget);
    final artwork = find.descendant(
      of: find.byType(PlayerScreen),
      matching: find.byType(Image),
    );
    expect(
      artwork,
      findsOneWidget,
      reason: 'the wait has the artwork under it',
    );
    expect(
      tester.getRect(artwork),
      tester.getRect(find.byType(PlayerScreen)),
      reason: 'and it covers the screen',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a film started from the banner does not start it again', (
    tester,
  ) async {
    // It did: Play from the banner opened the title page with "start this"
    // still set on it, so Escape out of the film landed on a page that started
    // the film — a loop you had to outrun with the Escape key.
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(downloads: [fakeDownload()])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => find.byType(PlayerScreen).evaluate().isNotEmpty,
      what: 'the player opened',
    );
    expect(
      find.byType(PlayerScreen),
      findsOneWidget,
      reason: 'the film opened',
    );
    await playerKeysReady(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await pumpFor(tester, const Duration(seconds: 6));
    expect(
      find.byType(PlayerScreen),
      findsNothing,
      reason: 'and it stays shut',
    );
  });

  testWidgets('a film the core cannot serve yet is never handed to mpv', (
    tester,
  ) async {
    // The bug this whole group is about: the core said ready when it had only
    // learned the name of the file, the player opened a stream whose every
    // read blocked on a swarm that had handed over nothing, mpv ran out of
    // patience, and an episode at 3% with two peers feeding it got the whole
    // screen saying the copy had no picture. Nothing reaches the server here
    // because nothing should: there is nothing to play yet, and the screen
    // says so with the name and a moving line.
    final asked = <HttpRequest>[];
    final core = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    core.listen(asked.add);
    addTearDown(() => core.close(force: true));
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          downloads: [fakeDownload(ready: false)],
          baseUrl: 'http://127.0.0.1:${core.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    // The player asks the core every two seconds: three asks, all "not yet".
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

  testWidgets('escape works while the film is still arriving', (tester) async {
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(downloads: [fakeDownload(ready: false)])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerKeysReady(tester);
    bool fullscreen() =>
        windowCalls.lastWhere((c) => c.method == 'setFullscreen').arguments
            as bool;
    expect(fullscreen(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(
      tester,
      () async => !fullscreen(),
      what: 'the first escape left fullscreen',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(
      tester,
      () async => find.byType(PlayerScreen).evaluate().isEmpty,
      what: 'the second escape went back to the title',
    );
  });

  testWidgets('a film that will not start is reported in the end', (
    tester,
  ) async {
    // The other half: the core says the beginning of the file is there and mpv
    // still cannot start it. Worth another go or two, because a stream can be
    // dropped in the middle of being opened — and then worth saying, because a
    // moving line over a film that is never going to play is a promise nobody
    // is keeping. The core here does not exist at all, so every attempt fails
    // at once. The patience is shortened: its thirty seconds are a number, the
    // behaviour is failures retried and then a verdict.
    final patience = openPatience;
    openPatience = const Duration(seconds: 3);
    addTearDown(() => openPatience = patience);
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(downloads: [fakeDownload()])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
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

  testWidgets('a file opened with Lumeo plays at once', (tester) async {
    // "Open with Lumeo" on a file did nothing: nothing read the argument.
    // The core makes the file a download, and the player plays that.
    final server = await serveFilm();
    final opened = <String>[];
    await tester.pumpWidget(
      LumeoApp(
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
    // A second "Open with Lumeo" opened a second window with a core of its
    // own. The app is one instance now: the runner hands the running one the
    // file on dev.lumeo/open.
    final server = await serveFilm();
    final opened = <String>[];
    await tester.pumpWidget(
      LumeoApp(
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

  testWidgets('a file the core refuses says why', (tester) async {
    await tester.pumpWidget(
      LumeoApp(open: testFilm().path, api: fakeCore(openFails: true)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlayerScreen), findsNothing);
    expect(
      find.text(
        'Could not open ${testFilm().path.split('/').last}: '
        'not a video file',
      ),
      findsOneWidget,
    );
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
      await pumpFor(tester, const Duration(seconds: 1));
      return started;
    }

    // Asked for episode 2 at all: prefetch is the only thing here that would.
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

    // On disk, the button stays and says so.
    await tester.tap(find.byTooltip('On disk'));
    await tester.pumpAndSettle();
    expect(find.text('This episode'), findsOneWidget);
    expect(find.textContaining('Next · E2'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    // Two polls of the playing download: the first finds it on disk, the
    // second has the next episode too.
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

  testWidgets('an episode that runs out starts the next one', (tester) async {
    // The whole path with nothing faked in the middle: a real film served
    // over the endpoint the core serves, played by the real libmpv, run to
    // its end, and the player left to do what it does — ask the core what
    // comes after this episode, order a copy of it, and open that copy.
    // Every piece of this has a unit test and none of them says the pieces
    // meet; in this player that is not a theoretical gap, because 0.1.19
    // shipped with every film frozen on its first frame under a green suite.
    //
    // The test film carries no chapters, so this is the path where nothing
    // warned anybody: mpv holds the last frame — keep-open — the button
    // counts five seconds over it, and the next episode starts. The other
    // path, an ending chapter and no wait, is what skipMoment is unit-tested
    // on; what is not unit-testable is any of this.
    final server = await serveFilm();
    final started = <String>[];
    final api = fakeCore(
      started: started,
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

    // To the end rather than through it: the film is thirty seconds long and
    // what is being tested starts at the last frame.
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

    // Back from the held frame and on with mpv's own keys, as the user does:
    // the card has to come back at the end. media_kit's `completed` stayed
    // silent the second time.
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

    // Five seconds of held last frame, and then a copy of the next episode
    // is ordered — from the core, by number, without anybody pressing
    // anything.
    await waitFor(
      tester,
      () async => started.any((body) {
        final asked = jsonDecode(body) as Map<String, dynamic>;
        return asked['season'] == 1 && asked['episode'] == 2;
      }),
      what: 'the player ordered a copy of the next episode',
    );

    // And it is playing it: a new screen, on the new download, with the new
    // number in the bar, showing picture of its own.
    await waitFor(
      tester,
      () async =>
          find.byType(PlayerScreen).evaluate().isNotEmpty &&
          tester.widget<PlayerScreen>(find.byType(PlayerScreen)).download ==
              'bb-s1e2',
      what: 'the player moved on to the next episode',
    );
    expect(
      find.text('Breaking Bad · S01E02'),
      findsWidgets,
      reason: 'the bar says which episode this is now',
    );
    await waitFor(
      tester,
      () async => await positionOf(mpvOnScreen(tester)) > 0.5,
      what: 'the next episode is playing, not merely opened',
    );

    // The episode that was left is finished, and the core was told so. An
    // anime ending starts at 87% and the core latches watched at 90%, so
    // without this the episode stays in Continue watching offering to resume
    // into its own credits.
    final progress = await api.progress('tt0903747');
    expect(
      progress.entry(1, 1)?.watched,
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
    // Both soundtracks and both subtitles are what a dual-audio release has:
    // the dub flagged default, and two English subtitles that only their
    // titles tell apart. `slang=eng` alone takes the default one of those,
    // so the second episode landing on "English Honorifics" is the title
    // match and nothing else.
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

    // Straight to mpv, the way its own `#` and `j` get there: the screen
    // hears of it only from the properties.
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

    // Out and back in on the next episode, rather than by playing to the
    // end: what carries the pick over is the core, and a new screen on a new
    // file asks it afresh either way.
    await playerKeysReady(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.byType(PlayerScreen), findsNothing);
    // The button on the still plays its episode, the way somebody picking
    // one with the mouse would; it shows while the pointer is on the card.
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
    // media_kit hands mpv a five second network timeout, which is a number for
    // a web server. A read from the core returns when the piece behind it
    // arrives, and on the swarm this was found on — two peers — that is longer
    // than five seconds every time, so the film never opened at all: the
    // screen said the copy had no picture over a download that was fine.
    //
    // The server here takes the connection and never answers, which is the
    // core in the middle of fetching the first piece. What is checked is that
    // the file is asked for, and the mpv holding the request has our timeout,
    // not media_kit's: which one mpv obeys is mpv's business, and waiting out
    // five seconds of it only proved that slowly.
    final asked = <HttpRequest>[];
    final stalled = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    stalled.listen(asked.add);
    addTearDown(() => stalled.close(force: true));
    await tester.pumpWidget(
      LumeoApp(
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
}
