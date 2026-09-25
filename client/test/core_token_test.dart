import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/api/core_token.dart';
import 'package:lumeo/platform/dirs.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('lumeo-token');
    file = File('${dir.path}/${CoreToken.fileName}');
  });
  tearDown(() => dir.delete(recursive: true));

  /// A core that wants [expected()] and records what each request carried.
  MockClient core(String? Function() expected, List<String?> seen) =>
      MockClient((request) async {
        final got = request.headers['authorization'];
        seen.add(got);
        final want = expected();
        return want == null || got == 'Bearer $want'
            ? http.Response('{"status":"ok","providers":0}', 200)
            : http.Response('{"error":"missing or wrong api token"}', 401);
      });

  test('every request carries the token from the file', () async {
    await file.writeAsString('abc\n');
    final seen = <String?>[];
    final api = LumeoApi(
      baseUrl: 'http://127.0.0.1:7666',
      client: core(() => 'abc', seen),
      token: CoreToken.file(file.path),
    );
    await api.health();
    await api.health();
    expect(seen, ['Bearer abc', 'Bearer abc']);
    expect(await api.token.headers(), {'Authorization': 'Bearer abc'});
  });

  test(
    'a core that wrote its token after the client looked is asked again',
    () async {
      final seen = <String?>[];
      final api = LumeoApi(
        baseUrl: 'http://127.0.0.1:7666',
        client: core(() => file.existsSync() ? 'new' : 'none yet', seen),
        token: CoreToken.file(file.path),
      );
      expect(await api.token.value, isNull);
      await file.writeAsString('new\n');
      await api.health();
      expect(seen, [null, 'Bearer new']);
    },
  );

  test('a refused token that has not changed is an error, sent once', () async {
    await file.writeAsString('stale\n');
    final seen = <String?>[];
    final api = LumeoApi(
      baseUrl: 'http://127.0.0.1:7666',
      client: core(() => 'other', seen),
      token: CoreToken.file(file.path),
    );
    await expectLater(
      api.health(),
      throwsA(isA<LumeoApiException>().having((e) => e.status, 'status', 401)),
    );
    expect(seen, ['Bearer stale']);
  });

  test('a core named by hand is not sent the local token', () {
    expect(LumeoApi(baseUrl: 'http://192.0.2.1:7666').token.path, isNull);
    expect(LumeoApi(baseUrl: 'http://127.0.0.1:7666').token.path, isNull);
    expect(LumeoApi().token.path, endsWith('/${CoreToken.fileName}'));
  });

  test('the data directory is the one the core picks', () {
    expect(dataDir({'LUMEO_DATA': '/srv/lumeo'}), '/srv/lumeo');
    if (!Platform.isWindows) {
      expect(dataDir({'XDG_DATA_HOME': '/x'}), '/x/lumeo');
      expect(dataDir({'HOME': '/home/u'}), '/home/u/.local/share/lumeo');
    }
  });

  test('ids are one path segment and paths resolve against the address', () {
    final api = LumeoApi(baseUrl: 'http://127.0.0.1:7666');
    expect(
      api.streamUrl('a/b'),
      'http://127.0.0.1:7666/api/v1/downloads/a%2Fb/stream',
    );
    expect(
      api.url('/api/v1/subtitles/x.srt'),
      'http://127.0.0.1:7666/api/v1/subtitles/x.srt',
    );
    expect(api.baseUrl, 'http://127.0.0.1:7666');
  });
}
