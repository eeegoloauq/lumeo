// The whole app over the fake core, as a widget test: what the UI tests share.
//
// Everything that does not need mpv runs here, under `flutter test`, in well
// under a second a test. What needs a real player is in integration_test/,
// which runs on Weston with libmpv (tool/ui-test.sh).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/platform/decoders.dart';
import 'package:lumeo/platform/local_settings.dart';
import 'package:lumeo/platform/window.dart';
import 'package:lumeo/ui/player/mpv_facts.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:lumeo/ui/screens/app_shell.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';

import 'fake_core.dart';

/// The app over [api], with settings of the test's own: never the desktop
/// user's client.json, which a test that changes a setting would overwrite.
LumeoApp testApp({
  Key? key,
  LumeoApi? api,
  LocalSettings? settings,
  String? open,
}) => LumeoApp(
  key: key,
  api: api ?? fakeCore(),
  settings: settings ?? temporarySettings(),
  open: open,
);

/// A test of the whole app on a desktop: Linux, the window's default size, a
/// window channel that records instead of acting, a machine that decodes
/// everything, and a stand-in where the player would open.
void uiTest(String description, WidgetTesterCallback body) => testWidgets(
  description,
  (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    fakeWindow();
    DeviceDecoders.instance = DeviceDecoders(
      ask: () async => _decodesEverything,
      osRelease: () async => null,
    );
    MpvFacts.instance = MpvFacts(
      ask: () async => (bindings: '[]', version: 'mpv 0.41.0'),
    );
    playerLayer = PlayerStandIn.new;
    addTearDown(() {
      DeviceDecoders.instance = DeviceDecoders();
      MpvFacts.instance = MpvFacts();
      playerLayer = (screen) => screen;
    });
    await body(tester);
    // Unmounted and run out, so a test that ends on a spinner or a debounce
    // does not fail on the timer it left: time here is fake and costs nothing.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  },
  // flutter test is Android by default, and scroll views, scrollbars and
  // keyboard shortcuts all follow the platform.
  variant: TargetPlatformVariant.only(TargetPlatform.linux),
);

const _decodesEverything =
    '[{"codec":"h264","driver":"h264"},{"codec":"hevc","driver":"hevc"},'
    '{"codec":"av1","driver":"libdav1d"},{"codec":"vp9","driver":"vp9"},'
    '{"codec":"aac","driver":"aac"},{"codec":"ac3","driver":"ac3"},'
    '{"codec":"eac3","driver":"eac3"},{"codec":"dts","driver":"dca"},'
    '{"codec":"truehd","driver":"truehd"},{"codec":"flac","driver":"flac"},'
    '{"codec":"opus","driver":"opus"},{"codec":"mp3","driver":"mp3float"}]';

/// What the shell shows where a film would play: the screen it was handed,
/// never built, so a test can ask which download and title it was for.
class PlayerStandIn extends StatelessWidget {
  const PlayerStandIn(this.screen, {super.key});

  final PlayerScreen screen;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// The download the stand-in was opened on, or null when no film is open.
String? playing(WidgetTester tester) {
  final open = find.byType(PlayerStandIn);
  return open.evaluate().isEmpty
      ? null
      : tester.widget<PlayerStandIn>(open).screen.download;
}

/// What the client asked the window to do, instead of asking the window.
final windowCalls = <MethodCall>[];

/// Answers the window channel and records each call in [windowCalls].
void fakeWindow() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('dev.lumeo/window'), (
        call,
      ) async {
        windowCalls.add(call);
        return call.method == 'state'
            ? <String, Object?>{'maximized': false, 'fullscreen': false}
            : null;
      });
  // The window is one object for the whole process, so a test that put it
  // into fullscreen would hand that on to the next one.
  AppWindow.instance.setFullscreen(false);
  windowCalls.clear();
}

/// Scrolls [finder] to the middle of its viewport and lets the layout catch
/// up. `tester.ensureVisible` puts the target at the very top, which on the
/// settings page is under the bar, and it does not pump, so a tap right after
/// it is aimed at where the widget was.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

/// Pumps until [question] answers yes, or gives up saying what it wanted.
///
/// The time is counted in pumps: fake in a widget test, and at least as long
/// in real time on Weston, where mpv opening a file and a software decoder
/// run on the wall clock and a fixed wait fails on a busy machine instead of
/// on a defect.
Future<void> waitFor(
  WidgetTester tester,
  Future<bool> Function() question, {
  required String what,
  Duration timeout = const Duration(seconds: 40),
}) async {
  const step = Duration(milliseconds: 100);
  for (var spent = Duration.zero; spent < timeout; spent += step) {
    if (await question()) return;
    await tester.pump(step);
  }
  fail('never: $what');
}

/// Pumps until [finder] shows up when what brings it is real I/O — a folder
/// listing, a picture over a socket — which fake time does not wait for.
Future<void> waitForIo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  fail('never: $finder');
}

/// Pumps for a while without insisting the screen ever stops moving.
///
/// pumpAndSettle cannot be used once the player is up: the spinner that
/// says a film is still arriving turns forever, and settling on it means waiting
/// out the ten minute timeout.
Future<void> pumpFor(WidgetTester tester, Duration total) async {
  for (
    var spent = Duration.zero;
    spent < total;
    spent += const Duration(milliseconds: 100)
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Ctrl+F, which is the only way into search that does not depend on where
/// the bar has put the magnifier.
Future<void> pressCtrlF(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// A row of the search panel, by the id of the title it stands for. Not
/// `find.text`: the same title is printed on the poster of a shelf behind
/// the panel, on every tile whose artwork has not arrived.
Finder panelRow(String id) => find.byKey(ValueKey('result:$id'));

/// Types into the open panel and waits out the debounce and the answer.
Future<void> typeIntoSearch(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

// Not pumpAndSettle alone: the spinner is held back for a moment, and a
// screen with nothing moving yet counts as settled.
Future<void> homeShown(WidgetTester tester) async {
  await waitFor(
    tester,
    () async => find.text('Popular films').evaluate().isNotEmpty,
    what: 'the home shelves',
  );
  await tester.pumpAndSettle();
}

Future<void> openHome(
  WidgetTester tester, {
  List<Map<String, dynamic>> downloads = const [],
}) async {
  await tester.pumpWidget(testApp(api: fakeCore(downloads: downloads)));
  await homeShown(tester);
}

Map<String, dynamic> watchEntry({
  required int episode,
  required double position,
  required double duration,
  required bool watched,
  required String updatedAt,
}) => {
  'season': 1,
  'episode': episode,
  'position': position,
  'duration': duration,
  'watched': watched,
  'updatedAt': updatedAt,
};

Future<void> openSeries(
  WidgetTester tester, {
  Map<String, List<Map<String, dynamic>>> progress = const {},
  Map<String, dynamic>? preferences,
  String stills = '',
  // For a test that needs a core of its own — one serving a film from a
  // real port, say. The navigation to the title is the same either way.
  LumeoApi? api,
}) async {
  await tester.pumpWidget(
    testApp(
      key: UniqueKey(),
      api:
          api ??
          fakeCore(
            progress: progress,
            preferences: preferences,
            stills: stills,
          ),
    ),
  );
  await tester.pumpAndSettle();
  await pressCtrlF(tester);
  await tester.enterText(find.byType(TextField), 'breaking bad');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
  await tester.tap(
    find.byWidgetPredicate((w) => w is PosterTile && w.item.id == 'tt0903747'),
  );
  await tester.pumpAndSettle();
}

/// Opens the Library from the bar, on My list.
Future<void> openLibrary(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: find.byType(TopBar), matching: find.text('Library')),
  );
  await tester.pumpAndSettle();
}

/// Settings in a file of the test's own, so a test never reads or writes the
/// desktop user's. Not loaded: there is nothing in a new file to load.
LocalSettings temporarySettings() {
  final directory = Directory.systemTemp.createTempSync('lumeo-ui-settings-');
  addTearDown(() => directory.deleteSync(recursive: true));
  return LocalSettings(path: '${directory.path}/client.json')..language = 'en';
}

/// Fails if anything visible is painted in MaterialApp's fallback text style.
///
/// One assertion for a whole class of mistake: any subtree that ends up
/// outside a Material — an overlay, a route of our own, a raw Text in a
/// painter — shows up here rather than in a screenshot somebody happens to
/// look at.
void expectNoFallbackStyle(WidgetTester tester) {
  const yellow = Color(0xFFFFFF00);
  final offenders = <String>[];
  void walk(RenderObject object) {
    if (object is RenderParagraph) {
      final style = object.text.style;
      if (style?.decorationColor == yellow ||
          (style?.fontFamily == 'monospace' && style?.fontSize == 48)) {
        offenders.add(object.text.toPlainText());
      }
    }
    object.visitChildren(walk);
  }

  for (final view in tester.binding.renderViews) {
    walk(view);
  }
  expect(
    offenders,
    isEmpty,
    reason: 'text without a Material ancestor: $offenders',
  );
}

/// Four orange pixels, which is all the artwork a wait needs to be tested on.
const pngFourByFour =
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGM4UaEBRwzEcQBTUhaB'
    'GaoOzwAAAABJRU5ErkJggg==';
