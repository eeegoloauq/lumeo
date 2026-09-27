// What the UI suite on Weston adds to the widget tests' helpers: the test
// films, the way they are served, and mpv behind the screen.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/player/player_screen.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../test/ui/app.dart';

export '../test/ui/app.dart';
export '../test/ui/fake_core.dart';

/// Deletes the films the run generated; called once, after the last test.
void deleteTestFilms() {
  _film?.deleteSync();
  _film = null;
  _tracksFilm?.parent.deleteSync(recursive: true);
  _tracksFilm = null;
}

Future<void> playerKeysReady(WidgetTester tester) => waitFor(
  tester,
  () async =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlayerScreen>() !=
      null,
  what: 'mpv bindings installed and the player has focus',
);

Future<void> playerOpened(WidgetTester tester) => waitFor(
  tester,
  () async => find.byType(PlayerScreen).evaluate().isNotEmpty,
  what: 'the player opened',
);

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
