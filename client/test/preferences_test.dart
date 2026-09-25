import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/api/preferences_store.dart';
import 'package:lumeo/ui/player/subtitle_style.dart';

void main() {
  test('a core from before keepDays reads as thirty days', () {
    final legacy = Preferences.fromJson({
      'subtitleLanguages': ['en'],
      'keep': '30days',
    });
    expect(legacy.keep, 'days');
    expect(legacy.keepDays, 30);

    final days = Preferences.fromJson({
      'subtitleLanguages': ['en'],
      'keep': 'days',
      'keepDays': 12,
    });
    expect(days.keep, 'days');
    expect(days.keepDays, 12);
  });

  test('the new preferences are read, and missing ones have defaults', () {
    final read = Preferences.fromJson({
      'subtitleLanguages': ['en'],
      'subtitleColor': 'yellow',
      'subtitleKeepStyling': false,
      'nextNotice': 45,
      'seekStep': 10,
      'downloadDir': '/srv/films',
      'seed': false,
      'uploadLimit': 1048576,
      'downloadLimit': 5242880,
    });
    expect(read.subtitleColor, 'yellow');
    expect(read.subtitleKeepStyling, isFalse);
    expect(read.nextNotice, 45);
    expect(read.seekStep, 10);
    expect(read.downloadDir, '/srv/films');
    expect(read.seed, isFalse);
    expect(read.uploadLimit, 1048576);
    expect(read.downloadLimit, 5242880);

    final bare = Preferences.fromJson({'subtitleLanguages': <String>[]});
    expect(bare.subtitleColor, 'white');
    expect(bare.subtitleKeepStyling, isTrue);
    expect(bare.seekStep, 5);
    expect(bare.seed, isTrue);
    expect(bare.downloadDir, isEmpty);
  });

  test('about names the address and the log when the core says them', () {
    final about = CoreAbout.fromJson({
      'version': '0.1.61',
      'addr': '127.0.0.1:7666',
      'logPath': r'C:\Users\me\AppData\Local\Lumeo\State\core.log',
    });
    expect(about.addr, '127.0.0.1:7666');
    expect(about.logPath, endsWith('core.log'));
    expect(CoreAbout.fromJson(const {}).logPath, isEmpty);
  });

  test('subtitle colour and styling become mpv properties', () {
    expect(subtitleStyleProperties(colour: 'yellow', keepStyling: true), {
      'sub-color': '#FFE14D',
      'sub-ass-override': 'scale',
    });
    expect(subtitleStyleProperties(colour: 'cyan', keepStyling: false), {
      'sub-color': '#7FE0FF',
      'sub-ass-override': 'force',
    }, reason: 'ours win over the file\'s styling only when asked to');
    expect(
      subtitleStyleProperties(
        colour: 'nonsense',
        keepStyling: true,
      )['sub-color'],
      '#FFFFFF',
    );
  });

  test(
    'a reset asks the core and keeps the document it answers with',
    () async {
      final calls = <String>[];
      final api = LumeoApi(
        baseUrl: 'http://core.invalid',
        client: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          final accent = request.method == 'DELETE' ? 'white' : 'red';
          return http.Response(
            jsonEncode({
              'subtitleLanguages': ['en'],
              'accent': accent,
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);
      final store = PreferencesStore(api);
      addTearDown(store.dispose);
      await store.patch({'accent': 'red'});
      expect(store.current?.accent, 'red');

      await store.reset();
      expect(calls.last, 'DELETE /api/v1/preferences');
      expect(store.current?.accent, 'white');
      expect(store.error, isNull);
    },
  );

  test('a reset waits for a patch already on its way', () async {
    final calls = <String>[];
    final patchAnswered = Completer<void>();
    final api = LumeoApi(
      baseUrl: 'http://core.invalid',
      client: MockClient((request) async {
        calls.add(request.method);
        if (request.method == 'PATCH') await patchAnswered.future;
        final accent = request.method == 'DELETE' ? 'white' : 'red';
        return http.Response(
          jsonEncode({
            'subtitleLanguages': ['en'],
            'accent': accent,
          }),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final store = PreferencesStore(api);
    addTearDown(store.dispose);

    final patched = store.patch({'accent': 'red'});
    final reset = store.reset();
    await pumpEventQueue();
    expect(calls, ['PATCH'], reason: 'the reset is not sent past the patch');

    patchAnswered.complete();
    await Future.wait([patched, reset]);
    expect(calls, ['PATCH', 'DELETE']);
    expect(store.current?.accent, 'white');
  });
}
