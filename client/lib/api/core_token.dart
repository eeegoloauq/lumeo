import 'dart:io';

import 'package:http/http.dart' as http;

import '../platform/dirs.dart';
import 'core_client.dart';

/// The secret the core writes to its data directory, which every request to
/// it has to carry. Only the user's own processes can read the file, and
/// they are the ones that may control the core.
class CoreToken {
  /// The token in the file at [path], read when first needed.
  CoreToken.file(String this.path);

  /// The token of the core on this machine.
  CoreToken.local([Map<String, String>? environment])
    : path = '${dataDir(environment)}/$fileName';

  /// No token: a core that asks for none, as the UI tests' fake does.
  CoreToken.none() : path = null;

  /// The file's name in the data directory; the core's `token.FileName`.
  static const fileName = 'api-token';

  final String? path;
  Future<String?>? _value;

  /// The token as last read, null when there is none to send.
  Future<String?> get value => _value ??= _read();

  /// The headers that carry the token, for what sends its own requests: mpv.
  Future<Map<String, String>> headers() async {
    final token = await value;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  /// Reads the file again after the core refused [sent], and says whether it
  /// now holds another token to try. A core started for the first time
  /// writes it only just before it listens, after the client may have looked.
  Future<bool> reload(String? sent) async {
    final fresh = await (_value = _read());
    return fresh != null && fresh != sent;
  }

  Future<String?> _read() async {
    final path = this.path;
    if (path == null) return null;
    try {
      final token = (await File(path).readAsString()).trim();
      return token.isEmpty ? null : token;
    } on FileSystemException {
      return null;
    }
  }
}

/// Puts the token on every request, and sends a request the core refused
/// once more when the token has changed since.
class AuthorizedClient extends http.BaseClient {
  AuthorizedClient(this._inner, this._token);

  final http.Client _inner;
  final CoreToken _token;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final sent = await _token.value;
    _authorize(request, sent);
    final response = await _inner.send(request);
    if (response.statusCode != HttpStatus.unauthorized ||
        request is! http.Request ||
        !await _token.reload(sent)) {
      return response;
    }
    await response.stream.drain<void>();
    final again = copyRequest(request);
    _authorize(again, await _token.value);
    return _inner.send(again);
  }

  static void _authorize(http.BaseRequest request, String? token) {
    if (token == null) {
      request.headers.remove('authorization');
    } else {
      request.headers['authorization'] = 'Bearer $token';
    }
  }

  @override
  void close() => _inner.close();
}
