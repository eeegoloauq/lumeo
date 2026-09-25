import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:lumeo/api/core_client.dart';

/// Refuses the connection [refusals] times, then answers with what it got.
class _Starting extends http.BaseClient {
  _Starting(this.refusals, {this.errorCode = 111});

  int refusals;
  final int errorCode;
  final bodies = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().bytesToString();
    bodies.add(body);
    if (refusals > 0) {
      refusals--;
      throw SocketException(
        'Connection refused',
        osError: OSError('Connection refused', errorCode),
      );
    }
    return http.StreamedResponse(Stream.value(body.codeUnits), 200);
  }
}

void main() {
  final url = Uri.parse('http://127.0.0.1:7666/api/v1/preferences');

  test(
    'a request refused while the core starts is sent again, body and all',
    () async {
      final inner = _Starting(3);
      final client = CoreClient(
        inner,
        patience: const Duration(seconds: 5),
        firstDelay: const Duration(milliseconds: 1),
      );
      final response = await client.patch(url, body: '{"accent":"white"}');
      expect(response.statusCode, 200);
      expect(response.body, '{"accent":"white"}');
      expect(inner.bodies, List.filled(4, '{"accent":"white"}'));
    },
  );

  test('a core that never listens is given up on after the patience', () async {
    final inner = _Starting(1 << 30);
    final client = CoreClient(
      inner,
      patience: const Duration(milliseconds: 50),
      firstDelay: const Duration(milliseconds: 1),
    );
    await expectLater(client.get(url), throwsA(isA<SocketException>()));
  });

  test('any other socket error is not waited out', () async {
    final inner = _Starting(1, errorCode: 113); // EHOSTUNREACH
    final client = CoreClient(
      inner,
      patience: const Duration(seconds: 5),
      firstDelay: const Duration(milliseconds: 1),
    );
    await expectLater(client.get(url), throwsA(isA<SocketException>()));
    expect(inner.bodies, hasLength(1));
  });
}
