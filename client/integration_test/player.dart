// The player itself: the bar, the menus, the keys and what reaches mpv.
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
import 'package:lumeo/main.dart';
import 'package:lumeo/ui/player/chrome.dart';
import 'package:lumeo/ui/player/menus.dart';
import 'package:lumeo/ui/player/mpv_host.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:lumeo/ui/player/panels.dart';
import 'package:lumeo/ui/player/screenshots.dart';
import 'package:lumeo/ui/player/subtitle_style.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';

import 'fake_core.dart';

import 'helpers.dart';

void playerTests() {
  testWidgets('a film takes the screen, and gives it back', (tester) async {
    // Opening a film in a maximised window left the desktop's panel across the
    // top of the picture. Taking the screen is only acceptable because the
    // window goes back exactly as it was found — which is the half worth a
    // test, since nobody notices it until it is wrong.
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(downloads: [fakeDownload()])),
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
    // Esc undoes one thing at a time: fullscreen first, the film after.
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
    // The panel used to be placed at a fixed corner of the chrome with nothing
    // between it and the picture. Two things came of that: the click that
    // dismissed it carried on to the film and paused it — one gesture closing
    // a menu and stopping a film nobody asked to stop — and the corner was a
    // guess, held right because the panel happened to be the width it is.
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(downloads: [fakeDownload()])),
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
    expect(
      panel.right,
      closeTo(tester.getSize(find.byType(PlayerScreen)).width - 24, 1),
      reason: 'the panel is aligned 24 pixels from the right edge',
    );
    expect(panel.left, greaterThanOrEqualTo(0));

    // Whether the film is running by now depends on the machine; whether the
    // click changed it does not.
    bool stopped() => find.byTooltip('Play (Space)').evaluate().isNotEmpty;
    final was = stopped();
    // The middle of the picture: outside the panel, and over the tap that
    // pauses the film.
    await tester.tapAt(const Offset(120, 200));
    await pumpFor(tester, const Duration(seconds: 1));
    expect(find.text('Speed'), findsNothing, reason: 'the menu closed');
    expect(
      stopped(),
      was,
      reason: 'and the click that closed it did not reach the film',
    );

    // One click moves from one menu to another, not one to close and one
    // to open.
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
      LumeoApp(
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

  testWidgets('a subtitle background is drawn by mpv and kept', (tester) async {
    final patched = <String>[];
    await tester.pumpWidget(
      LumeoApp(
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
    // Nothing on the page is written here: what a key does is mpv's own
    // comment on its own binding, and the page is only as right as the read.
    // A pause line proves the read — Space, `p` and the right button are
    // mpv's, and our section adds the click and host actions.
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(downloads: [fakeDownload()])),
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

  for (final (what, command) in [
    ('a back message', ['script-message', 'lumeo', 'back']),
    ('mpv quitting', ['quit']),
  ]) {
    testWidgets('$what closes the player', (tester) async {
      await tester.pumpWidget(
        LumeoApp(api: fakeCore(downloads: [fakeDownload()])),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await playerKeysReady(tester);
      unawaited(mpvOnScreen(tester).command(command));
      await waitFor(
        tester,
        () async => find.byType(PlayerScreen).evaluate().isEmpty,
        what: 'the player closed',
      );
    });
  }

  testWidgets('every property mpv is given is one mpv knows', (tester) async {
    // mpv answers an unknown property by ignoring it, and media_kit does not
    // look at the answer either, so a misspelt option is set silently and is
    // wrong for the life of the release. Asked back one at a time, a name mpv
    // does not have comes back empty.
    final player = Player();
    addTearDown(player.dispose);
    final mpv = player.platform! as NativePlayer;
    for (final property in {
      ...playerProperties,
      // Set per film rather than once, and just as silently ignored when
      // misspelt.
      ...screenshotProperties(title: 'Andor', pictures: '/tmp'),
      // The branch for this mpv: whether it has sub-border-style is itself
      // asked of mpv.
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
    // mpv falls back to a software screenshot when the render context lacks
    // advanced control, and on mpv 0.41 that path cannot read an nvdec frame:
    // `s` wrote nothing on the test desktop. The dev box decodes in
    // software, where both paths save a file, so the log says which one ran.
    final server = await serveFilm();
    await tester.pumpWidget(
      LumeoApp(
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
      LumeoApp(
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
    // The whole thing, in the screen it belongs to: a real film served over
    // the same HTTP endpoint the core serves, played by the real libmpv, and
    // driven by the keyboard the way a viewer drives it. What is checked is
    // that the keys reach mpv and mpv answers them — the player used to keep
    // a table of its own and drop the rest — and that a key does not bring
    // the controls up over the picture.
    final server = await serveFilm();

    await tester.pumpWidget(
      LumeoApp(
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

    // The pointer is off the picture and the bar has had time to go.
    await pumpFor(tester, const Duration(seconds: 1));
    AnimatedOpacity chrome() => tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byType(PlayerChrome),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(chrome().opacity, 0, reason: 'the bar is down while the film runs');

    // And the frames were taken, not only the clock read: `time-pos` is
    // driven by the audio and climbs with the picture standing still. mpv's
    // video output counts a drop each time its 200 ms wait for the render
    // call runs out, which is what a render thread that never came back
    // looks like from mpv's side — 0.1.19 shipped that way, every film on
    // its first frame with the sound running, and this test was green. The
    // same counter takes frames that were merely late, so a loaded llvmpipe
    // is allowed a few; the stuck thread measured fifty in these three
    // seconds.
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

    // Held, not pressed: the repeat is mpv's own, between a `keydown` and a
    // `keyup`, which is what makes holding an arrow scrub. Flutter's repeat
    // events are dropped on the way, so if this jumps by one step the key
    // was pressed and never held.
    final held = await position();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await pumpFor(tester, const Duration(milliseconds: 1500));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await waitFor(
      tester,
      () async => held - (await position()) > 7,
      what: 'a held arrow repeated: more than one step back',
    );

    // And a tap is one step: a `keyup` that reached mpv late — behind a
    // blocking call that used to hold Dart for the length of the seek the
    // `keydown` started — was a key mpv still held and repeated. Every frame
    // of this film is a keyframe, so one seek of five seconds is five.
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

    // A held space bar is one pause, not thirty a second: mpv's own repeat
    // knows which of its bindings repeat, which is why the repeat is mpv's
    // and the keyboard's repeat events go nowhere. Two of them here, and an
    // odd number of toggles in all is what says they went nowhere.
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

    // The mouse is mpv's too. A click on the picture is `MBTN_LEFT` to mpv,
    // bound here to the pause because mpv's own left button is `ignore`; a
    // right click is mpv's default pause; and two clicks are mpv's double
    // click, which takes the pause back and goes fullscreen — the property,
    // which the window follows. The middle of the picture, away from the
    // chrome: a click on the bar is the bar's.
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

    // Zoom closes in on the cursor only if mpv knows where it is, in the
    // picture's own pixels: a quarter of the way into the letterboxed
    // picture is a quarter of the film's width.
    final box = tester.getRect(find.byType(Video));
    final width = int.parse(await mpv.getProperty('width'));
    final height = int.parse(await mpv.getProperty('height'));
    final shown = box.height * width / height;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: box.center);
    await mouse.moveTo(box.center - Offset(shown / 4, 0));
    await waitFor(tester, () async {
      final x =
          (jsonDecode(await mpv.getProperty('mouse-pos')) as Map)['x'] as int;
      return (x - width / 4).abs() < width / 20;
    }, what: 'mpv holds the pointer in video pixels');
    await mouse.removePointer();
  });

  testWidgets('the wheel is mpv\'s over the picture and not over a panel', (
    tester,
  ) async {
    // Two episodes fit the panel, so its list cannot scroll and Flutter lets
    // the wheel fall through to whatever is under it; that used to be mpv's
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

    // The bar has faded over a playing film; a mouse move brings it back.
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

    // Up over the panel, then down over the picture: had the first reached
    // mpv, the two would cancel out and the volume would stay at 50.
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
      LumeoApp(
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
}
