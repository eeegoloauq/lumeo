// Weston suite helpers for test films and mpv.
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
    // mpv requests ranges; this film fits in memory.
    final range = request.headers.value('range');
    // Reject unsupported ranges here so the test fails with an answer instead
    // of timing out.
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

/// Returns the twenty-megabyte film generated once for the whole run.
File? _film;

File testFilm() => _film ??= writeTestFilm();

File? _tracksFilm;

/// Generates a thirty-second dual-audio film with titled subtitles in ffmpeg.
/// The track test needs a real container.
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

/// Generates thirty seconds of moving uncompressed YUV without an encoder or
/// checked-in media.
File writeTestFilm() {
  const width = 160;
  const height = 120;
  // Thirty seconds leaves film after a mid-playback pause; eight seconds ran
  // out during pumping.
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
