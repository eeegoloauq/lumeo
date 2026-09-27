// Player controls, keys and mpv properties.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:lumeo/ui/player/bindings.dart';
import 'package:lumeo/ui/player/chrome.dart';
import 'package:lumeo/ui/player/menus.dart';
import 'package:lumeo/ui/player/mpv_host.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:lumeo/ui/player/panels.dart';
import 'package:lumeo/ui/player/screenshots.dart';
import 'package:lumeo/ui/player/subtitle_style.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';

import 'helpers.dart';

void playerTests() {
  testWidgets('a film takes the screen, and gives it back', (tester) async {
    // A maximised window used to leave the desktop panel over the film;
    // playback must restore its prior window state.
    await tester.pumpWidget(
      testApp(api: fakeCore(downloads: [fakeDownload()])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => windowCalls.any(
        (c) => c.method == 'setFullscreen' && c.arguments == true,
      ),
      what: 'the player took the window fullscreen',
    );
    expect(find.byType(PlayerScreen), findsOneWidget);
    expect(
      windowCalls
          .where((c) => c.method == 'setFullscreen')
          .map((c) => c.arguments),
      contains(true),
    );
    await playerKeysReady(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await waitFor(
      tester,
      () async => find.byType(TracksMenu).evaluate().isNotEmpty,
      what: 'mpv opened the tracks menu',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(
      tester,
      () async => find.byType(TracksMenu).evaluate().isEmpty,
      what: 'mpv closed the menu',
    );
    bool lastFullscreen() =>
        windowCalls.lastWhere((c) => c.method == 'setFullscreen').arguments
            as bool;
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await waitFor(
      tester,
      () async => !lastFullscreen(),
      what: 'mpv toggled the window',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await waitFor(tester, () async => lastFullscreen(), what: 'and back');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(
      tester,
      () async => !lastFullscreen(),
      what: 'Esc left fullscreen',
    );
    expect(find.byType(PlayerScreen), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await waitFor(
      tester,
      () async => find.byType(PlayerScreen).evaluate().isEmpty,
      what: 'mpv closed the player',
    );
    expect(
      windowCalls
          .where((c) => c.method == 'setFullscreen')
          .map((c) => c.arguments)
          .last,
      isFalse,
      reason: 'the window is handed back in the state it was taken in',
    );
  });

  testWidgets('a player menu hangs off its button and closes without pausing', (
    tester,
  ) async {
    // Dismissing the panel used to click through and pause the film.
    await tester.pumpWidget(
      testApp(api: fakeCore(downloads: [fakeDownload()])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => find.byTooltip('Settings').evaluate().isNotEmpty,
      what: 'the player bar is up',
    );
    expect(find.byType(PlayerScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('Speed'), findsOneWidget, reason: 'the menu opened');

    final button = tester.getRect(find.byTooltip('Settings'));
    final panel = tester.getRect(find.byType(MenuPanel));
    expect(
      panel.bottom,
      lessThanOrEqualTo(button.top),
      reason: 'above the button it hangs from, not off the bottom edge',
    );
    expect(panel.left, greaterThanOrEqualTo(0));

    final mpv = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async => await mpv.getProperty('pause') == 'no',
      what: 'the film plays',
    );
    await tester.tapAt(const Offset(120, 200));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('Speed'), findsNothing, reason: 'the menu closed');
    expect(
      await mpv.getProperty('pause'),
      'no',
      reason: 'and the click that closed it did not reach the film',
    );

    await tester.tap(find.byTooltip('Settings'));
    await pumpFor(tester, const Duration(milliseconds: 500));
    await tester.tap(find.byTooltip('Subtitles (C)'));
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(find.byType(SettingsMenu), findsNothing);
    expect(find.byType(TracksMenu), findsOneWidget);
  });

  testWidgets('gear Speed page sets mpv speed and stores nothing', (
    tester,
  ) async {
    final patched = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(downloads: [fakeDownload()], patched: patched),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerKeysReady(tester);
    final host = await MpvHost.attach(mpvOnScreen(tester));
    addTearDown(host.dispose);
    await tester.sendEventToBinding(
      TestPointer(99, PointerDeviceKind.mouse).hover(const Offset(400, 400)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Speed'));
    await pumpFor(tester, const Duration(milliseconds: 300));
    expect(find.widgetWithText(MenuBack, 'Speed'), findsOneWidget);
    await tester.tap(find.text('1.5×'));
    await waitFor(
      tester,
      () async => (double.tryParse(await host.get('speed') ?? '') ?? 0) == 1.5,
      what: 'mpv speed changed to 1.5',
    );
    // Past the preferences store's burst delay.
    await pumpFor(tester, const Duration(seconds: 1));
    expect(patched, isEmpty, reason: 'speed belongs to this film only');
  });

  testWidgets('mpv fits the picture to the view, so fill keeps its OSD', (
    tester,
  ) async {
    final server = await serveFilm();
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerKeysReady(tester);
    final host = await MpvHost.attach(mpvOnScreen(tester));
    addTearDown(host.dispose);
    // mpv draws its OSD against the view size in pixels, not the film size.
    final view =
        tester.getSize(find.byType(Video)) * tester.view.devicePixelRatio;
    await waitFor(
      tester,
      () async =>
          int.tryParse(await host.get('osd-width') ?? '') ==
              view.width.round() &&
          int.tryParse(await host.get('osd-height') ?? '') ==
              view.height.round(),
      what: 'mpv renders at the view\'s size',
    );

    await tester.sendEventToBinding(
      TestPointer(99, PointerDeviceKind.mouse).hover(const Offset(400, 400)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Picture'));
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Fill'));
    await waitFor(
      tester,
      () async =>
          double.tryParse(await host.get('panscan') ?? '') == 1 &&
          await host.get('keepaspect') == 'yes',
      what: 'fill is mpv\'s panscan',
    );
    await tester.tap(find.text('Stretch'));
    await waitFor(
      tester,
      () async =>
          double.tryParse(await host.get('panscan') ?? '') == 0 &&
          await host.get('keepaspect') == 'no',
      what: 'stretch drops mpv\'s aspect',
    );
  });

  testWidgets('a subtitle background is drawn by mpv and kept', (tester) async {
    final patched = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(downloads: [fakeDownload()], patched: patched),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerKeysReady(tester);
    final host = await MpvHost.attach(mpvOnScreen(tester));
    addTearDown(host.dispose);
    await tester.sendEventToBinding(
      TestPointer(99, PointerDeviceKind.mouse).hover(const Offset(400, 400)),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Subtitles (C)'));
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Subtitle style'));
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Box'));
    final borderStyle = await host.get('sub-border-style') != null;
    final box = subtitleBackgroundProperties('box', borderStyle: borderStyle);
    await waitFor(
      tester,
      () async =>
          (await host.get('sub-back-color'))?.toUpperCase() ==
          box['sub-back-color'],
      what: 'mpv draws the box',
    );
    await pumpFor(tester, const Duration(seconds: 1));
    expect(patched, [
      jsonEncode({'subtitleBackground': 'box'}),
    ]);
  });

  testWidgets('the shortcut page is read from mpv', (tester) async {
    // The displayed bindings come from mpv; a pause line proves its own and the
    // host bindings were read.
    await tester.pumpWidget(
      testApp(api: fakeCore(downloads: [fakeDownload()])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => find.byTooltip('Settings').evaluate().isNotEmpty,
      what: 'the player bar is up',
    );
    expect(find.byType(PlayerScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await pumpFor(tester, const Duration(seconds: 1));
    await tester.tap(find.text('Keyboard shortcuts'));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.widgetWithText(MenuBack, 'Keyboard shortcuts'), findsOneWidget);
    expect(find.text('Back to the title'), findsOneWidget);
    expect(find.text('Toggle pause/playback mode'), findsOneWidget);
    expect(
      find.text('Click, Right click, P, Space'),
      findsOneWidget,
      reason: "our binding of the left button sits with mpv's own",
    );
    expect(
      find.textContaining('quit'),
      findsNothing,
      reason: 'a key that would end the core is not offered',
    );

    await tester.tap(find.widgetWithText(MenuBack, 'Keyboard shortcuts'));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('Speed'), findsOneWidget);
  });

  testWidgets('mpv quitting closes the player', (tester) async {
    await tester.pumpWidget(
      testApp(api: fakeCore(downloads: [fakeDownload()])),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerKeysReady(tester);
    unawaited(mpvOnScreen(tester).command(['quit']));
    await waitFor(
      tester,
      () async => find.byType(PlayerScreen).evaluate().isEmpty,
      what: 'the player closed',
    );
  });

  testWidgets('every property mpv is given is one mpv knows', (tester) async {
    // mpv silently ignores unknown option names, so read properties back to
    // catch misspellings.
    final player = Player();
    addTearDown(player.dispose);
    final mpv = player.platform! as NativePlayer;
    for (final property in {
      ...playerProperties,
      ...screenshotProperties(title: 'Andor', pictures: '/tmp'),
      // sub-border-style is conditional on the installed mpv version.
      ...subtitleBackgroundProperties(
        'shadow',
        borderStyle: (await mpv.getProperty('sub-border-style')).isNotEmpty,
      ),
      ...subtitleStyleProperties(colour: 'cream', keepStyling: false),
    }.entries) {
      await mpv.setProperty(property.key, property.value);
      expect(
        await mpv.getProperty(property.key),
        isNotEmpty,
        reason: 'mpv has no property called ${property.key}',
      );
    }
  });

  testWidgets('a screenshot is taken by the GPU renderer', (tester) async {
    // mpv 0.41 cannot read nvdec frames through its software screenshot
    // fallback. The log identifies which screenshot path ran on this machine.
    final server = await serveFilm();
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await pumpFor(tester, const Duration(seconds: 1));

    final mpv = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async => (double.tryParse(await mpv.getProperty('time-pos')) ?? 0) > 1,
      what: 'the film played into its second second',
    );
    final dir = await Directory.systemTemp.createTemp('lumeo-shot');
    addTearDown(() => dir.delete(recursive: true));
    final log = File('${dir.path}/mpv.log');
    final shot = File('${dir.path}/shot.jpg');
    await mpv.setProperty('log-file', log.path);
    await mpv.command(['screenshot-to-file', shot.path]);
    await waitFor(
      tester,
      () async => shot.existsSync() && shot.lengthSync() > 0,
      what: 'the frame was written',
    );
    await mpv.setProperty('log-file', '');
    expect(
      log.readAsStringSync(),
      isNot(contains('Falling back to software screenshot')),
      reason: 'the render thread took the screenshot on the GPU',
    );
  });

  testWidgets('the bar shows the frame under the pointer, and drops it when '
      'the pointer leaves', (tester) async {
    final server = await serveFilm();
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await pumpFor(tester, const Duration(seconds: 1));
    final mpv = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async => (double.tryParse(await mpv.getProperty('time-pos')) ?? 0) > 0,
      what: 'the film played',
    );

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(120, 200)));
    await pumpFor(tester, const Duration(milliseconds: 300));
    final bar = tester.getRect(find.byType(Scrubber));
    await tester.sendEventToBinding(
      pointer.hover(Offset(bar.left + bar.width * 0.6, bar.center.dy)),
    );
    Iterable<ui.Image> frames() => tester
        .widgetList<RawImage>(
          find.descendant(
            of: find.byType(Scrubber),
            matching: find.byType(RawImage),
          ),
        )
        .map((raw) => raw.image)
        .nonNulls;
    await waitFor(
      tester,
      () async => frames().isNotEmpty,
      what: 'a frame came from the second mpv',
    );
    expect(frames().single.width, 480, reason: 'mpv scaled it, not Dart');

    await tester.sendEventToBinding(pointer.hover(const Offset(120, 200)));
    await tester.pump();
    expect(frames(), isEmpty);
  });

  testWidgets('the keys are mpv\'s: space pauses, an arrow seeks, and the bar '
      'stays down', (tester) async {
    // Keys once stopped at the player's own binding table; this checks they
    // reach real mpv.
    final server = await serveFilm();

    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await pumpFor(tester, const Duration(seconds: 1));

    final mpv = mpvOnScreen(tester);
    Future<double> position() async =>
        double.tryParse(await mpv.getProperty('time-pos')) ?? 0;
    await waitFor(
      tester,
      () async => await position() > 1,
      what: 'the film played into its second second',
    );
    expect(
      await mpv.getProperty('input-default-bindings'),
      'yes',
      reason: 'mpv answers keys with its own bindings',
    );

    await pumpFor(tester, const Duration(seconds: 1));
    AnimatedOpacity chrome() => tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(PlayerChrome),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(chrome().opacity, 0, reason: 'the bar is down while the film runs');

    // `time-pos` can advance with frozen video; mpv counts render-call waits as
    // dropped frames. 0.1.19 froze at frame one; allow a few late llvmpipe
    // frames, not a stuck render thread.
    expect(
      int.parse(await mpv.getProperty('frame-drop-count')),
      lessThan(10),
      reason: 'mpv\'s video output was rendered the frames it had',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(
      tester,
      () async => await mpv.getProperty('pause') == 'yes',
      what: 'space paused the film',
    );
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      chrome().opacity,
      0,
      reason: 'and pausing did not bring the bar up over the picture',
    );

    final before = await position();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await waitFor(
      tester,
      () async => (await position()) - before > 3,
      what: 'the arrow seeked forward by mpv\'s five seconds',
    );
    expect(
      await mpv.getProperty('pause'),
      'yes',
      reason: 'a seek does not unpause',
    );

    // Held, not pressed: the repeat is mpv's, between `keydown` and `keyup`,
    // and Flutter's repeat events are dropped. One step means the key was never
    // held.
    final held = await position();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await pumpFor(tester, const Duration(milliseconds: 1500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await waitFor(
      tester,
      () async => held - (await position()) > 7,
      what: 'a held arrow repeated: more than one step back',
    );

    // A late `keyup` once let mpv repeat a single seek while Dart blocked.
    final tapped = await position();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await waitFor(
      tester,
      () async => (await position()) - tapped > 3,
      what: 'the tapped arrow seeked forward',
    );
    await pumpFor(tester, const Duration(seconds: 1));
    expect(
      await position(),
      closeTo(tapped + 5, 1),
      reason: 'one tap is one seek of five seconds, not two or three',
    );

    // The keyboard's repeat events go nowhere and mpv does not repeat pause, so
    // a held Space is one toggle.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await pumpFor(tester, const Duration(milliseconds: 700));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await pumpFor(tester, const Duration(milliseconds: 700));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(
      await mpv.getProperty('pause'),
      'no',
      reason: 'a held space toggled pause once, and the film runs',
    );

    // mpv owns picture clicks: left pauses through the host binding, right
    // pauses by default, and double click toggles fullscreen.
    final picture = tester.getCenter(find.byType(Video));
    await tester.tapAt(picture);
    await waitFor(
      tester,
      () async => await mpv.getProperty('pause') == 'yes',
      what: 'a click on the picture paused, through mpv',
    );
    await tester.tapAt(picture, buttons: kSecondaryMouseButton);
    await waitFor(
      tester,
      () async => await mpv.getProperty('pause') == 'no',
      what: 'a right click took the pause back, by mpv\'s own binding',
    );
    // Two within mpv's double click time, which is 300 ms.
    final fullscreen = await mpv.getProperty('fullscreen');
    await tester.tapAt(picture);
    await tester.tapAt(picture);
    await waitFor(
      tester,
      () async => await mpv.getProperty('fullscreen') != fullscreen,
      what: 'a double click toggled mpv\'s fullscreen',
    );
    await pumpFor(tester, const Duration(milliseconds: 500));
    expect(
      await mpv.getProperty('pause'),
      'no',
      reason: 'and the two clicks paused and unpaused, as on YouTube',
    );

    // mpv zooms around the cursor only when its target has the view-pixel
    // position.
    final box = tester.getRect(find.byType(Video));
    final width = int.parse(await mpv.getProperty('osd-width'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: box.center);
    await mouse.moveTo(box.center - Offset(box.width / 4, 0));
    await waitFor(tester, () async {
      final x =
          (jsonDecode(await mpv.getProperty('mouse-pos')) as Map)['x'] as int;
      return (x - width / 4).abs() < width / 20;
    }, what: 'mpv holds the pointer in its target\'s pixels');
    await mouse.removePointer();
  });

  testWidgets('the wheel is mpv\'s over the picture and not over a panel', (
    tester,
  ) async {
    // When this short list cannot scroll, its wheel events used to change mpv
    // volume.
    final server = await serveFilm();
    final api = fakeCore(
      downloads: [
        fakeDownload(id: 'bb-s1e1', itemId: 'tt0903747', season: 1, episode: 1),
        fakeDownload(id: 'bb-s1e2', itemId: 'tt0903747', season: 1, episode: 2),
      ],
      baseUrl: 'http://127.0.0.1:${server.port}',
    );
    await openSeries(tester, api: api);
    await tester.tap(find.text('Play S1 E1'));
    await pumpFor(tester, const Duration(seconds: 1));
    final mpv = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async => (double.tryParse(await mpv.getProperty('time-pos')) ?? 0) > 0,
      what: 'the episode played',
    );
    await mpv.setProperty('volume', '50');
    Future<double> volume() async =>
        double.parse(await mpv.getProperty('volume'));

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(120, 200)));
    await pumpFor(tester, const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Episodes'));
    await waitFor(
      tester,
      () async => find.byType(EpisodesPanel).evaluate().isNotEmpty,
      what: 'the episodes panel opened',
    );
    pointer.hover(tester.getCenter(find.text("2 · Cat's in the Bag...")));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.pump();

    // A wheel event over the panel must not reach mpv and cancel the later
    // picture event.
    await tester.tapAt(const Offset(120, 200));
    await waitFor(
      tester,
      () async => find.byType(EpisodesPanel).evaluate().isEmpty,
      what: 'the episodes panel closed',
    );
    pointer.hover(const Offset(120, 200));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
    await waitFor(
      tester,
      () async => await volume() < 50,
      what: 'the wheel over the picture lowered the volume by itself',
    );
  });

  testWidgets('the player source page switches copies', (tester) async {
    final started = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          started: started,
          downloads: [
            fakeDownload(id: 'copy1', ready: false),
            fakeDownload(
              id: 'copy2',
              ready: false,
              name: 'Night of the Living Dead 1968 2160p BluRay x265 DTS-HD',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PosterTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await waitFor(
      tester,
      () async => find.byType(PlayerScreen).evaluate().isNotEmpty,
      what: 'the first copy opened',
    );
    final firstCopy = tester
        .widget<PlayerScreen>(find.byType(PlayerScreen))
        .download;
    final nextCopy = firstCopy == 'copy1' ? 'copy2' : 'copy1';
    final nextLabel = nextCopy == 'copy2' ? '2160p · GROUP' : '1080p · GROUP';
    final nextName = nextCopy == 'copy2'
        ? 'Night of the Living Dead 1968 2160p BluRay x265 DTS-HD'
        : 'Night of the Living Dead 1968 1080p BluRay x264 AC3';
    await waitFor(
      tester,
      () async => find.byTooltip('Download').evaluate().isNotEmpty,
      what: 'the player knows its download',
    );
    await tester.tap(find.byTooltip('Settings'));
    await waitFor(
      tester,
      () async => find.text('Source').evaluate().isNotEmpty,
      what: 'the gear lists the source',
    );
    await tester.tap(find.text('Source'));
    await waitFor(
      tester,
      () async =>
          find.byType(MenuBack).evaluate().isNotEmpty &&
          find.textContaining('1080p · GROUP').evaluate().isNotEmpty &&
          find.textContaining('2160p · GROUP').evaluate().isNotEmpty,
      what: 'the source page listed both copies',
    );
    await tester.tap(find.textContaining(nextLabel));
    await waitFor(
      tester,
      () async =>
          tester.widget<PlayerScreen>(find.byType(PlayerScreen)).download ==
          nextCopy,
      what: 'the player reopened on the chosen copy',
    );
    expect((jsonDecode(started.last)['source'] as Map)['rawName'], nextName);
  });

  // mpv defaults can arrive before stored preferences; a late response must
  // still apply the stored values.
  for (final (answers, unreachable) in [('on time', 0), ('late', 2)]) {
    testWidgets(
      'A core that answers $answers gives the player the stored subtitle size',
      (tester) async {
        final patched = <String>[];
        await tester.pumpWidget(
          testApp(
            api: fakeCore(
              downloads: [fakeDownload()],
              preferences: {
                'subtitleLanguages': ['en'],
                'subtitleScale': 1.4,
                'subtitlePosition': 90,
              },
              preferencesUnreachable: unreachable,
              patched: patched,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Play'));
        await pumpFor(tester, const Duration(seconds: 1));
        await waitFor(
          tester,
          () async =>
              double.parse(
                await mpvOnScreen(tester).getProperty('sub-scale'),
              ) ==
              1.4,
          what: 'the stored subtitle size applied',
        );
        expect(
          double.parse(await mpvOnScreen(tester).getProperty('sub-pos')),
          90,
        );
        await pumpFor(tester, const Duration(seconds: 1));
        expect(patched, isEmpty, reason: 'nothing the player read was stored');
      },
    );
  }

  testWidgets('the stored subtitle colour, styling and arrow step reach mpv', (
    tester,
  ) async {
    // Read these settings back from mpv; their effects are not directly visible
    // in the test.
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          preferences: {
            'subtitleLanguages': ['en'],
            'subtitleColor': 'yellow',
            'subtitleKeepStyling': false,
            'seekStep': 10,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerKeysReady(tester);
    final host = await MpvHost.attach(mpvOnScreen(tester));
    addTearDown(host.dispose);
    await waitFor(
      tester,
      () async => (await host.get('sub-ass-override')) == 'force',
      what: 'our style over the file\'s',
    );
    expect(
      (await host.get('sub-color'))?.toUpperCase(),
      anyOf('#FFE14D', '#FFFFE14D'),
    );
    final bindings = MpvBinding.parse(await host.get('input-bindings') ?? '');
    expect(
      bindings.where(
        (b) =>
            b.section == ownSection && b.key == 'RIGHT' && b.cmd == 'seek 10',
      ),
      isNotEmpty,
      reason: 'the arrow is bound to the stored step in our section',
    );
  });

  testWidgets('Timeline previews off, no second mpv is made for the bar', (
    tester,
  ) async {
    final server = await serveFilm();
    final settings = temporarySettings();
    settings.timelinePreviews = false;
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await pumpFor(tester, const Duration(seconds: 1));
    final mpv = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async => (double.tryParse(await mpv.getProperty('time-pos')) ?? 0) > 0,
      what: 'the film played',
    );
    // The frames' only source is what the bar is handed; with it off the bar
    // is handed nothing, so nothing can start one.
    expect(
      find.byWidgetPredicate((w) => w is PlayerChrome && w.thumbnails != null),
      findsNothing,
    );
  });
}
