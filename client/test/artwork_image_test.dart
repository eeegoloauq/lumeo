import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/widgets/artwork_image.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// A stand-in for the core's artwork route: answers each request with the
/// next status in [statuses], the image once they run out.
Future<(HttpServer, List<int>)> _serve(List<int> statuses) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = <int>[];
  server.listen((request) async {
    final status = seen.length < statuses.length ? statuses[seen.length] : 200;
    seen.add(status);
    request.response.statusCode = status;
    if (status == 200) request.response.add(_png);
    await request.response.close();
  });
  return (server, seen);
}

/// Resolves [url] outside the cache and reports whether an image arrived.
Future<bool> _load(String url) {
  final done = Completer<bool>();
  final provider = ArtworkImage(url);
  provider
      .loadImage(
        provider,
        PaintingBinding.instance.instantiateImageCodecWithSize,
      )
      .addListener(
        ImageStreamListener(
          (_, _) => done.complete(true),
          onError: (_, _) => done.complete(false),
        ),
      );
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding answers every HttpClient request 400 itself; these
  // tests need the loopback server.
  HttpOverrides.global = null;
  setUp(
    () => ArtworkImage.retryDelays = const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 10),
    ],
  );

  test('an image the core could not fetch is asked for again', () async {
    final (server, seen) = await _serve([502, 502]);
    addTearDown(server.close);
    expect(await _load('http://127.0.0.1:${server.port}/a'), isTrue);
    expect(seen, [502, 502, 200]);
  });

  test('a missing image is final', () async {
    final (server, seen) = await _serve([404]);
    addTearDown(server.close);
    expect(await _load('http://127.0.0.1:${server.port}/a'), isFalse);
    expect(seen, [404]);
  });

  test('the retries stop', () async {
    final (server, seen) = await _serve([502, 502, 502, 502]);
    addTearDown(server.close);
    expect(await _load('http://127.0.0.1:${server.port}/a'), isFalse);
    expect(seen, [502, 502, 502]);
  });
}
