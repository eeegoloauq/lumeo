import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Artwork the core serves from its cache, asked for again when the core
/// could not fetch it.
///
/// The core answers 5xx when the provider's CDN did not answer in time. On a
/// throttled line that is often a node blocked by address, which the system
/// resolver keeps handing out for the name's 30 s TTL, so the retries reach
/// past one TTL. The load stays pending meanwhile: the placeholder holds and
/// every widget showing the URL fills in together. A 4xx is an answer, the
/// image does not exist, and is final.
@immutable
class ArtworkImage extends ImageProvider<ArtworkImage> {
  const ArtworkImage(this.url);

  final String url;

  /// The pause before each retry.
  @visibleForTesting
  static List<Duration> retryDelays = const [
    Duration(seconds: 2),
    Duration(seconds: 6),
    Duration(seconds: 20),
  ];

  static final HttpClient _client = HttpClient();

  @override
  Future<ArtworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    ArtworkImage key,
    ImageDecoderCallback decode,
  ) {
    final completer = MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1,
      debugLabel: url,
    );
    // A failed image leaves the cache, so a page opened later asks again.
    completer.addEphemeralErrorListener(
      (_, _) => scheduleMicrotask(
        () => PaintingBinding.instance.imageCache.evict(key),
      ),
    );
    return completer;
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(await _fetchWithRetries()));

  Future<Uint8List> _fetchWithRetries() async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _fetch();
      } on NetworkImageLoadException catch (e) {
        if (e.statusCode < 500 || attempt == retryDelays.length) rethrow;
      } on IOException {
        if (attempt == retryDelays.length) rethrow;
      }
      await Future<void>.delayed(retryDelays[attempt]);
    }
  }

  Future<Uint8List> _fetch() async {
    final uri = Uri.parse(url);
    final response = await (await _client.getUrl(uri)).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: uri,
      );
    }
    return consolidateHttpClientResponseBytes(response);
  }

  @override
  bool operator ==(Object other) => other is ArtworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => 'ArtworkImage("$url")';
}
