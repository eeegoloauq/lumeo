import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Sends a request again while the core refuses the connection, for as long
/// as a request is allowed to take.
///
/// The app starts its core with the window, and a core started while the one
/// before it is still finishing its downloads waits for that before it
/// listens: for a few seconds the address refuses what the first screens ask.
/// A refused connection means the request never reached the core, so sending
/// it again is safe whatever its method.
class CoreClient extends http.BaseClient {
  CoreClient(this._inner, {required this.patience, this.firstDelay = _delay});

  static const _delay = Duration(milliseconds: 100);
  static const _longestDelay = Duration(seconds: 1);

  final http.Client _inner;
  final Duration patience;
  final Duration firstDelay;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final deadline = DateTime.now().add(patience);
    var delay = firstDelay;
    for (var attempt = request; ; attempt = copyRequest(request)) {
      try {
        return await _inner.send(attempt);
      } on SocketException catch (error) {
        if (request is! http.Request ||
            !refused(error) ||
            DateTime.now().add(delay).isAfter(deadline)) {
          rethrow;
        }
      }
      await Future<void>.delayed(delay);
      delay = delay * 2 > _longestDelay ? _longestDelay : delay * 2;
    }
  }

  /// ECONNREFUSED as Linux, macOS and Windows number it.
  static bool refused(SocketException error) =>
      const {111, 61, 10061}.contains(error.osError?.errorCode);

  @override
  void close() => _inner.close();
}

/// A request can be sent once; this is the same one to send again. Every
/// request the API makes is an [http.Request], whose body is at hand.
http.Request copyRequest(http.Request request) {
  return http.Request(request.method, request.url)
    ..headers.addAll(request.headers)
    ..followRedirects = request.followRedirects
    ..maxRedirects = request.maxRedirects
    ..persistentConnection = request.persistentConnection
    ..bodyBytes = request.bodyBytes;
}
