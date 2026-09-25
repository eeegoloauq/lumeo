// What the UI tests share: the waits, the test films and the way into each screen.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/platform/local_settings.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:lumeo/ui/widgets/poster_tile.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';

import 'fake_core.dart';

/// Scrolls [finder] to the middle of its viewport and lets the layout catch
/// up. `tester.ensureVisible` puts the target at the very top, which on the
/// settings page is under the bar, and it does not pump, so a tap right after
/// it is aimed at where the widget was.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
}

/// What the client asked the window to do, instead of asking the window.
final windowCalls = <MethodCall>[];

/// Deletes the films the run generated; called once, after the last test.
void deleteTestFilms() {
  _film?.deleteSync();
  _film = null;
  _tracksFilm?.parent.deleteSync(recursive: true);
  _tracksFilm = null;
}

/// Pumps until a question about the player answers yes, or gives up
/// saying what it wanted.
///
/// Everything about the player runs in real time — mpv opening a file, a
/// software decoder on a virtual screen — and a test that waits a fixed
/// number of seconds for all of that fails on a busy machine instead of on
/// a defect.
Future<void> waitFor(
  WidgetTester tester,
  Future<bool> Function() question, {
  required String what,
  Duration timeout = const Duration(seconds: 40),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await question()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('never: $what');
}

Future<void> playerKeysReady(WidgetTester tester) => waitFor(
  tester,
  () async =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlayerScreen>() !=
      null,
  what: 'mpv bindings installed and the player has focus',
);

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

/// The test film, served the way the core serves it: one endpoint, any
/// path, range requests answered. Two tests play it.
Future<HttpServer> serveFilm([File? film]) async {
  final bytes = (film ?? testFilm()).readAsBytesSync();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  addTearDown(() => server.close(force: true));
  server.listen((request) async {
    // mpv opens a stream by asking for a range, the same as it does of the
    // core. The film is small enough to answer out of memory.
    final range = request.headers.value('range');
    // Only the form mpv actually sends. A suffix range would once have
    // thrown inside this callback, where nothing is listening, and the test
    // would have failed as a timeout rather than as an answer.
    final start = range == null
        ? null
        : RegExp(r'bytes=(\d+)-').firstMatch(range)?.group(1);
    final from = start == null ? 0 : int.parse(start);
    // A view rather than a copy: the film is twenty megabytes and mpv asks
    // for it more than once.
    final body = Uint8List.sublistView(bytes, from);
    request.response.headers.set('accept-ranges', 'bytes');
    if (start != null) {
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        'content-range',
        'bytes $from-${bytes.length - 1}/${bytes.length}',
      );
    }
    request.response.contentLength = body.length;
    request.response.add(body);
    await request.response.close();
  });
  return server;
}

/// mpv itself, through the widget that draws it: the screen's own state is
/// private, and the properties are the facts anyway.
NativePlayer mpvOnScreen(WidgetTester tester) =>
    tester.widget<Video>(find.byType(Video)).controller.player.platform!
        as NativePlayer;

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
  await tester.pumpWidget(LumeoApp(api: fakeCore(downloads: downloads)));
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
    LumeoApp(
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

Future<LocalSettings> temporarySettings() async {
  final directory = Directory.systemTemp.createTempSync('lumeo-ui-settings-');
  addTearDown(() => directory.deleteSync(recursive: true));
  return LocalSettings.load(path: '${directory.path}/client.json');
}

/// The generated film, made once for the whole run.
///
/// Twenty megabytes of it, and two tests want it: written per test, it was
/// written twice and deleted twice for no reason.
File? _film;

File testFilm() => _film ??= writeTestFilm();

File? _tracksFilm;

/// The same thirty seconds with the tracks of a dual-audio release: an English
/// dub flagged default, a Japanese original, and two English subtitles told
/// apart only by their titles. Tracks need a real container, so this one is
/// made by ffmpeg, from its own test sources.
File tracksFilm() => _tracksFilm ??= () {
  final dir = Directory.systemTemp.createTempSync('lumeo-tracks-');
  File('${dir.path}/full.srt')
      .writeAsStringSync('1\n00:00:00,000 --> 00:00:30,000\nFull\n');
  File('${dir.path}/honorifics.srt')
      .writeAsStringSync('1\n00:00:00,000 --> 00:00:30,000\nHonorifics\n');
  final film = File('${dir.path}/tracks.mkv');
  final result = Process.runSync('ffmpeg', [
    '-v',
    'error',
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=160x120:rate=25:duration=30',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=440:duration=30',
    '-f',
    'lavfi',
    '-i',
    'sine=frequency=660:duration=30',
    '-i',
    '${dir.path}/full.srt',
    '-i',
    '${dir.path}/honorifics.srt',
    for (final input in ['0', '1', '2', '3', '4']) ...['-map', input],
    '-c:v',
    'mpeg4',
    '-c:a',
    'flac',
    '-c:s',
    'srt',
    '-metadata:s:a:0',
    'language=eng',
    '-metadata:s:a:0',
    'title=English Dub',
    '-disposition:a:0',
    'default',
    '-metadata:s:a:1',
    'language=jpn',
    '-metadata:s:a:1',
    'title=Japanese',
    '-disposition:a:1',
    '0',
    '-metadata:s:s:0',
    'language=eng',
    '-metadata:s:s:0',
    'title=English Full',
    '-disposition:s:0',
    'default',
    '-metadata:s:s:1',
    'language=eng',
    '-metadata:s:s:1',
    'title=English Honorifics',
    '-disposition:s:1',
    '0',
    film.path,
  ]);
  if (result.exitCode != 0) throw StateError('ffmpeg: ${result.stderr}');
  return film;
}();

/// Thirty seconds of moving picture, written out where the test can play it.
///
/// Uncompressed YUV in the plainest container there is, because the point is
/// a film that exists rather than a codec: a few kilobytes of Dart produce it,
/// nothing has to be installed to encode it, and no video file has to be kept
/// in the repository to be played back once a year.
File writeTestFilm() {
  const width = 160;
  const height = 120;
  // Long enough that a test can pause in the middle of it and still have
  // film to come back to: pumping a widget tree is slower than the wall
  // clock, and eight seconds of picture ran out during the pause.
  const frames = 750; // thirty seconds at 25 fps
  const chroma = width * height ~/ 4;
  final file = File(
    '${Directory.systemTemp.path}/lumeo-trace-${DateTime.now().microsecondsSinceEpoch}.y4m',
  );
  final out = file.openSync(mode: FileMode.write);
  out.writeStringSync('YUV4MPEG2 W$width H$height F25:1 Ip A1:1 C420\n');
  final luma = Uint8List(width * height);
  for (var frame = 0; frame < frames; frame++) {
    out.writeStringSync('FRAME\n');
    // A moving gradient rather than a flat field: a decoder handed the same
    // picture two hundred times is not decoding anything.
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        luma[y * width + x] = (x + y + frame) % 256;
      }
    }
    out.writeFromSync(luma);
    out.writeFromSync(
      Uint8List(chroma)..fillRange(0, chroma, (128 + frame) % 256),
    );
    out.writeFromSync(
      Uint8List(chroma)..fillRange(0, chroma, (128 - frame) % 256),
    );
  }
  out.closeSync();
  return file;
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
