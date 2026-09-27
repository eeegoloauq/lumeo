// Shared harness for whole-app widget tests over the fake core.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/platform/decoders.dart';
import 'package:lumeo/platform/folders.dart';
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

/// Runs an app test with Linux window behaviour, recorded window calls and a
/// player stand-in.
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
    picturesFolderAnswer = '/home/viewer/Pictures';
    addTearDown(() {
      picturesFolderAnswer = null;
      DeviceDecoders.instance = DeviceDecoders();
      MpvFacts.instance = MpvFacts();
      playerLayer = (screen) => screen;
    });
    await body(tester);
    // Unmounted and run out, so a test that ends on a spinner or a debounce
    // does not fail on the timer it left.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  },
  // Flutter tests default to Android; scrolling and shortcuts depend on Linux
  // platform behaviour.
  variant: TargetPlatformVariant.only(TargetPlatform.linux),
);

const _decodesEverything =
    '[{"codec":"h264","driver":"h264"},{"codec":"hevc","driver":"hevc"},'
    '{"codec":"av1","driver":"libdav1d"},{"codec":"vp9","driver":"vp9"},'
    '{"codec":"aac","driver":"aac"},{"codec":"ac3","driver":"ac3"},'
    '{"codec":"eac3","driver":"eac3"},{"codec":"dts","driver":"dca"},'
    '{"codec":"truehd","driver":"truehd"},{"codec":"flac","driver":"flac"},'
    '{"codec":"opus","driver":"opus"},{"codec":"mp3","driver":"mp3float"}]';

/// Stands in for the player and keeps the unopened screen for title and
/// download assertions.
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
  // The window object persists across tests; clear its fullscreen state.
  AppWindow.instance.setFullscreen(false);
  windowCalls.clear();
}

/// Scrolls [finder] to viewport centre and pumps layout.
/// ensureVisible alone leaves settings targets under the bar.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

/// Pumps until [question] succeeds; pump counts cover fake time and slower
/// Weston wall time.
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

/// Waits for [finder] after real I/O, which fake time cannot advance.
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

/// Pumps for [total] without settling; a player spinner can run until the
/// ten-minute timeout. On Weston a pump also waits for a frame, so the time is
/// the binding's clock rather than the pumps counted.
Future<void> pumpFor(WidgetTester tester, Duration total) async {
  final end = tester.binding.clock.fromNowBy(total);
  while (tester.binding.clock.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens search with Ctrl+F, independent of the magnifier's position.
Future<void> pressCtrlF(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// Finds a search row by title id; its text may also appear on a shelf behind
/// the panel.
Finder panelRow(String id) => find.byKey(ValueKey('result:$id'));

/// Types into the open panel and waits out the debounce and the answer.
Future<void> typeIntoSearch(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}

// A delayed spinner can make pumpAndSettle finish before the response arrives.
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

Map<String, dynamic> continueItem(String id, Map<String, dynamic> next) => {
  'item': Map<String, dynamic>.of(fakeItem(id))..remove('episodes'),
  'next': next,
  'updatedAt': next['updatedAt'],
};

Future<void> openSeries(
  WidgetTester tester, {
  Map<String, Map<String, dynamic>> progress = const {},
  Map<String, dynamic>? preferences,
  String stills = '',
  // A caller may supply a core with a real film-serving port.
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

/// Returns settings in a temporary file, avoiding the desktop client.json.
LocalSettings temporarySettings() {
  final directory = Directory.systemTemp.createTempSync('lumeo-ui-settings-');
  addTearDown(() => directory.deleteSync(recursive: true));
  return LocalSettings(path: '${directory.path}/client.json')..language = 'en';
}

/// Fails on visible fallback text styles, which expose widgets outside
/// Material.
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
