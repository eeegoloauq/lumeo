import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/player/chrome.dart';
import 'package:lumeo/ui/theme.dart';
import 'package:lumeo/ui/widgets/loading.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';
import 'package:lumeo/ui/widgets/window_controls.dart';

void main() {
  _scrubberTests();

  test('clock has no leading zero on the first field', () {
    expect(clock(const Duration(minutes: 5, seconds: 3)), '5:03');
    expect(clock(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
  });

  testWidgets('an open menu does not latch the bar as hovered', (tester) async {
    // Flutter does not call MouseRegion.onExit for a region unmounted under
    // the pointer, and it says so in its own documentation. The menu used to
    // sit in one, feeding the flag that keeps the controls up; closing the
    // menu with Escape or by picking a line in it left the flag true and the
    // controls never faded again. The controls already stay up for as long as
    // a menu is open, so the menu has nothing to say about hover at all.
    final hovers = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerChrome(
            model: const ChromeModel(
              title: 'Nosferatu',
              download: null,
              position: Duration(minutes: 3),
              duration: Duration(minutes: 90),
              playing: true,
              volume: 100,
              muted: false,
              fullscreen: false,
              subtitlesOn: true,
              menu: PlayerMenu.settings,
            ),
            actions: ChromeActions(
              close: () {},
              togglePlay: () {},
              scrub: (_) {},
              seek: (_) {},
              setVolume: (_) {},
              toggleMute: () {},
              toggleFullscreen: () {},
              openMenu: (_) {},
              closeMenu: () {},
              hoverBar: hovers.add,
            ),
            menu: const SizedBox(width: 380, height: 200, key: Key('menu')),
          ),
        ),
      ),
    );
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    // On the picture to begin with: the corner is inside the top band, which
    // holds the chrome up like the bar does.
    await pointer.addPointer(
      location: tester.getCenter(find.byType(PlayerChrome)),
    );
    addTearDown(pointer.removePointer);
    await tester.pump();
    await pointer.moveTo(tester.getCenter(find.byKey(const Key('menu'))));
    await tester.pump();

    expect(
      hovers,
      isEmpty,
      reason: 'the menu is not what tells the bar the pointer is on it',
    );
  });

  testWidgets('a tap that misses inside the bar does not reach the picture', (
    tester,
  ) async {
    // The screen pauses on a tap under everything, and the bar is a row of
    // buttons with gaps between them: a click a few points off the volume, or
    // in the strip between the scrubber and the buttons, or on the title, went
    // through and paused the film. No player does that. The bands of chrome
    // are not the picture, and a miss inside one is a miss.
    //
    // The picture takes its tap as a layer under the chrome, as the screen
    // has it, rather than as a detector wrapped around everything: the
    // chrome's own scrim must let a tap through to it.
    var taps = 0;
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: lumeoTheme(),
        home: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                child: const ColoredBox(color: Colors.black),
              ),
              PlayerChrome(
                model: const ChromeModel(
                  title: 'Nosferatu',
                  download: null,
                  position: Duration(minutes: 3),
                  duration: Duration(minutes: 90),
                  playing: true,
                  volume: 100,
                  muted: false,
                  fullscreen: false,
                  subtitlesOn: false,
                  menu: PlayerMenu.none,
                ),
                actions: ChromeActions(
                  close: () {},
                  togglePlay: () {},
                  scrub: (_) {},
                  seek: seeks.add,
                  setVolume: (_) {},
                  toggleMute: () {},
                  toggleFullscreen: () {},
                  openMenu: (_) {},
                  closeMenu: () {},
                  hoverBar: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final screen = tester.getRect(find.byType(PlayerChrome));
    final scrubber = tester.getRect(find.byType(Scrubber));
    final buttons = tester.getRect(find.byType(VolumeControl));

    // Between the scrubber and the row of buttons.
    await tester.tapAt(
      Offset(screen.center.dx, (scrubber.bottom + buttons.top) / 2),
    );
    // The empty stretch of the bar, right of the volume.
    await tester.tapAt(Offset(buttons.right + 40, buttons.center.dy));
    // The margin beside the bar, and the strip under it.
    await tester.tapAt(Offset(screen.left + 8, buttons.center.dy));
    await tester.tapAt(Offset(screen.center.dx, screen.bottom - 6));
    // The title at the top.
    await tester.tapAt(tester.getCenter(find.text('Nosferatu')));
    await tester.pumpAndSettle();
    expect(taps, 0, reason: 'none of those is a tap on the picture');

    await tester.tapAt(screen.center);
    await tester.pumpAndSettle();
    expect(taps, 1, reason: 'the middle of the picture still is');

    // And the band eating its misses has not eaten the scrubber's hits.
    await tester.tapAt(scrubber.center);
    await tester.pumpAndSettle();
    expect(seeks, hasLength(1));
    expect(taps, 1);
  });

  testWidgets('the window buttons paint', (tester) async {
    // The same guard the player icons have: these are drawn rather than taken
    // from the icon font, and a painter that throws would otherwise only be
    // found by looking at the corner of a running window.
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WindowControls())),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('the window buttons ride the player\'s top band, and go in '
      'fullscreen', (tester) async {
    // The player is a layer over the whole window rather than a page under
    // the application's bar, and that bar is where these three live — so a
    // film was the one screen in the client with no way to minimise or close
    // the window at all. The band that carries the title carries them now,
    // against the window's edge rather than the picture's margin, and in
    // fullscreen they go for the reason they go from the bar.
    Widget chrome({required bool fullscreen}) => MaterialApp(
      theme: lumeoTheme(),
      home: Scaffold(
        body: PlayerChrome(
          model: ChromeModel(
            title: 'Nosferatu',
            download: null,
            position: const Duration(minutes: 3),
            duration: const Duration(minutes: 90),
            playing: true,
            volume: 100,
            muted: false,
            fullscreen: fullscreen,
            subtitlesOn: false,
            menu: PlayerMenu.none,
          ),
          actions: ChromeActions(
            close: () {},
            togglePlay: () {},
            scrub: (_) {},
            seek: (_) {},
            setVolume: (_) {},
            toggleMute: () {},
            toggleFullscreen: () {},
            openMenu: (_) {},
            closeMenu: () {},
            hoverBar: (_) {},
          ),
        ),
      ),
    );

    await tester.pumpWidget(chrome(fullscreen: false));
    expect(tester.getSize(find.byTooltip('Pause (Space)')), const Size(40, 40));
    expect(find.byIcon(Icons.closed_caption_outlined), findsOneWidget);
    expect(find.byIcon(Icons.playlist_play), findsNothing);
    expect(find.byType(WindowControls), findsOneWidget);
    final screen = tester.getRect(find.byType(PlayerChrome));
    final buttons = tester.getRect(find.byType(WindowControls));
    expect(
      buttons.bottom,
      lessThan(screen.center.dy),
      reason: 'in the top band, not over the picture',
    );
    expect(
      screen.right - buttons.right,
      lessThanOrEqualTo(24),
      reason: 'against the window\'s edge',
    );
    expect(
      tester.getRect(find.text('Nosferatu')).right,
      lessThanOrEqualTo(buttons.left),
      reason:
          'the title ends where they begin rather than running under '
          'them',
    );

    await tester.pumpWidget(chrome(fullscreen: true));
    expect(
      find.byType(WindowControls),
      findsNothing,
      reason: 'nothing to minimise to while the window is the screen',
    );
  });

  testWidgets('the spinner waits before it shows', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Loading())),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(Loading.delay);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a hovered poster names the title it is showing', (tester) async {
    const item = MediaItem(
      id: 'tt0063350',
      kind: 'movie',
      title: 'Night of the Living Dead',
      year: 1968,
      imdbRating: 7.8,
      poster: 'https://example.invalid/poster.jpg',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PosterTile(item: item, onOpen: () {}),
          ),
        ),
      ),
    );
    // The facts are always in the tree and fade in, so the test is about what
    // they say, not whether they exist: the title, the year and the rating,
    // which is the whole point of hovering a poster too small to read. The
    // card under a poster still loading carries the title too, so the search
    // stays inside the facts.
    Finder fact(String text) => find.descendant(
      of: find.byType(AnimatedOpacity),
      matching: find.text(text),
    );
    expect(fact('Night of the Living Dead'), findsOneWidget);
    expect(fact('1968'), findsOneWidget);
    expect(fact('7.8'), findsOneWidget);

    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.addPointer(location: Offset.zero);
    addTearDown(pointer.removePointer);
    await pointer.moveTo(tester.getCenter(find.byType(PosterTile)));
    await tester.pumpAndSettle();
    final facts = tester.widget<AnimatedOpacity>(
      find.ancestor(
        of: fact('Night of the Living Dead'),
        matching: find.byType(AnimatedOpacity),
      ),
    );
    expect(facts.opacity, 1);
  });

  testWidgets('the rating sits at the far edge, not next to the year', (
    tester,
  ) async {
    const item = MediaItem(
      id: 'a',
      kind: 'movie',
      title: 'Dune',
      year: 2021,
      imdbRating: 8.0,
      poster: 'https://example.invalid/poster.jpg',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: PosterTile(item: item, onOpen: _noop),
          ),
        ),
      ),
    );
    final year = tester.getTopLeft(find.text('2021')).dx;
    final rating = tester.getTopRight(find.text('8.0')).dx;
    final tile = tester.getRect(find.byType(PosterTile));
    // Each fact hard against its own edge of the card, within the padding.
    expect(year - tile.left, lessThan(16));
    expect(tile.right - rating, lessThan(16));
  });

  testWidgets('a poster has one bar, how much was watched', (tester) async {
    // A download bar stacked on the watch bar read as two timelines once
    // both were white.
    Future<void> show({required bool acquired}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PosterTile(
              item: const MediaItem(id: 'a', kind: 'series', title: 'Re:Zero'),
              onOpen: _noop,
              progress: const Progress(completed: 40, total: 100),
              acquired: acquired,
              watchFraction: 0.3,
            ),
          ),
        ),
      ),
    );
    await show(acquired: true);
    final bar = find.byType(LinearProgressIndicator);
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0.3);
    expect(find.byIcon(Icons.download), findsOneWidget, reason: 'on disk');

    await show(acquired: false);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0.4,
      reason: 'on its way',
    );
  });
}

void _noop() {}

/// The scrubber, which had no tests at all while it was a bar drawn by hand —
/// and which was the thing you could not hit, that seeked on every pixel of a
/// drag, and that swallowed the first click.
void _scrubberTests() {
  Widget host(
    void Function(Duration) onSeek, {
    Duration? duration,
    void Function(double)? onScrub,
    VoidCallback? onStart,
    VoidCallback? onEnd,
  }) => MaterialApp(
    theme: lumeoTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 600,
          child: Scrubber(
            position: const Duration(minutes: 10),
            duration: duration ?? const Duration(minutes: 100),
            acquired: 0.4,
            onScrub: onScrub ?? (_) {},
            onSeek: onSeek,
            onStart: onStart,
            onEnd: onEnd,
          ),
        ),
      ),
    ),
  );

  testWidgets('a single tap on the track seeks there', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(host(seeks.add));
    final track = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(track.center.dx, track.center.dy));
    await tester.pumpAndSettle();
    expect(seeks, hasLength(1), reason: 'one tap, one seek');
    expect(seeks.single.inMinutes, 50, reason: 'the middle of a hundred');
  });

  testWidgets('the time under the pointer is the time it seeks to', (
    tester,
  ) async {
    // They were not the same time. A Slider insets its track by half an
    // overlay at each end and maps a click inside that narrower rectangle,
    // while the bubble over the pointer was read off the full width: the two
    // drifted apart towards the ends of the bar — twenty seconds on a
    // half-hour episode — so a click aimed at the bubble landed somewhere
    // else, and a second click at the same place, already there, did nothing
    // anybody could see.
    final seeks = <Duration>[];
    await tester.pumpWidget(host(seeks.add));
    final track = tester.getRect(find.byType(Slider));
    // A quarter along, which is where the inset used to cost the most that is
    // still visible on screen.
    final at = Offset(track.left + track.width * 0.25, track.center.dy);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.pumpAndSettle();
    final bubble = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .toList();

    await tester.tapAt(at);
    await tester.pumpAndSettle();
    expect(seeks, hasLength(1));
    expect(seeks.single.inSeconds, 25 * 60);
    expect(
      bubble,
      contains(clock(seeks.single)),
      reason: 'the bubble said where the tap would land',
    );
  });

  testWidgets('the time sits centred over the pointer and stops at the ends '
      'of the bar', (tester) async {
    // It used to be aligned by the same fraction as the pointer, which puts
    // the bubble's middle under the pointer only in the middle of the bar.
    await tester.pumpWidget(host((_) {}));
    final bar = tester.getRect(find.byType(Scrubber));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    Future<Rect> hover(double fraction, String time) async {
      await tester.sendEventToBinding(
        pointer.hover(Offset(bar.left + bar.width * fraction, bar.center.dy)),
      );
      await tester.pumpAndSettle();
      return tester.getRect(find.text(time));
    }

    final quarter = await hover(0.25, '25:00');
    expect(quarter.center.dx, closeTo(bar.left + bar.width * 0.25, 0.5));
    expect((await hover(0.005, '0:30')).left, greaterThanOrEqualTo(bar.left));
    expect((await hover(0.995, '1:39:30')).right, lessThanOrEqualTo(bar.right));
  });

  testWidgets('a drag scrubs as it goes and seeks once, on release', (
    tester,
  ) async {
    // As mpv's own bar: every movement is a cheap keyframe seek, so the
    // picture follows the thumb, and letting go is the one exact seek.
    final seeks = <Duration>[];
    final scrubs = <double>[];
    final phases = <String>[];
    await tester.pumpWidget(
      host(
        seeks.add,
        onScrub: scrubs.add,
        onStart: () => phases.add('start'),
        onEnd: () => phases.add('end'),
      ),
    );
    final track = tester.getRect(find.byType(Slider));
    final gesture = await tester.startGesture(
      track.centerLeft + const Offset(30, 0),
    );
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
    }
    expect(scrubs, isNotEmpty, reason: 'the picture is asked to follow');
    expect(
      scrubs,
      orderedEquals(scrubs.toList()..sort()),
      reason: 'towards the hand, never back',
    );
    expect(seeks, isEmpty, reason: 'no exact seek mid-drag');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(seeks, hasLength(1), reason: 'and exactly one when it is let go');
    expect(phases, ['start', 'end']);
    expect(
      find.text(clock(seeks.single)),
      findsOneWidget,
      reason: 'the hover label follows the released thumb',
    );
  });

  testWidgets('a film of unknown length cannot be scrubbed', (tester) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(host(seeks.add, duration: Duration.zero));
    final track = tester.getRect(find.byType(Slider));
    await tester.tapAt(track.center);
    await tester.pumpAndSettle();
    expect(seeks, isEmpty);
  });
}
