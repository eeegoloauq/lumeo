import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/api/downloads_store.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/widgets/download_mark.dart';

Map<String, Object?> _download(String id) => {
  'id': id,
  'itemId': 'tt1',
  'name': 'Film',
  'state': 'active',
  'progress': {'total': 100},
};

void main() {
  test('a download started here is listed before the next poll', () async {
    // The first poll answers only when told to, so it is still in flight
    // when the download starts, and it answers without it.
    final firstPoll = Completer<void>();
    var polls = 0;
    final api = LumeoApi(
      baseUrl: 'http://127.0.0.1:7666',
      client: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(jsonEncode(_download('new')), 201);
        }
        if (request.url.path == '/api/v1/downloads') {
          if (polls++ == 0) await firstPoll.future;
          return http.Response(jsonEncode({'downloads': []}), 200);
        }
        return http.Response('{}', 404);
      }),
    );
    final store = DownloadsStore(api);
    addTearDown(store.dispose);

    await api.startDownload(
      itemId: 'tt1',
      source: MediaSource.fromJson(const {'name': 'Film'}),
    );
    expect(store.all.map((d) => d.id), ['new']);

    firstPoll.complete();
    await pumpEventQueue();
    expect(store.all.map((d) => d.id), [
      'new',
    ], reason: 'a poll asked before the start does not take it back off');
  });

  test('a download the core already had is updated where it is', () async {
    final api = LumeoApi(
      baseUrl: 'http://127.0.0.1:7666',
      client: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response(
            jsonEncode({..._download('old'), 'state': 'done'}),
            201,
          );
        }
        return http.Response(
          jsonEncode({
            'downloads': [_download('new'), _download('old')],
          }),
          200,
        );
      }),
    );
    final store = DownloadsStore(api);
    addTearDown(store.dispose);
    await store.refresh();

    await api.startDownload(
      itemId: 'tt1',
      source: MediaSource.fromJson(const {'name': 'Film'}),
    );
    expect(store.all.map((d) => '${d.id} ${d.state}'), [
      'new active',
      'old done',
    ]);
  });

  test(
    'pause and resume change the row at once, with the core\'s answer',
    () async {
      final bodies = <String>[];
      final api = LumeoApi(
        baseUrl: 'http://127.0.0.1:7666',
        client: MockClient((request) async {
          if (request.method == 'PATCH') {
            bodies.add('${request.url.path} ${request.body}');
            final paused = (jsonDecode(request.body) as Map)['paused'] as bool;
            return http.Response(
              jsonEncode({
                ..._download('d'),
                'state': paused ? 'paused' : 'active',
                'pausedByUser': paused,
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'downloads': [_download('d')],
            }),
            200,
          );
        }),
      );
      final store = DownloadsStore(api);
      addTearDown(store.dispose);
      await store.refresh();

      await store.pause(store.all.single);
      expect(bodies, ['/api/v1/downloads/d {"paused":true}']);
      expect(store.all.single.isPaused, isTrue);
      expect(store.all.single.pausedByUser, isTrue);

      await store.resume(store.all.single);
      expect(bodies.last, '/api/v1/downloads/d {"paused":false}');
      expect(store.all.single.isActive, isTrue);
    },
  );

  test('a pause the core refuses leaves the row as it was', () async {
    final api = LumeoApi(
      baseUrl: 'http://127.0.0.1:7666',
      client: MockClient((request) async {
        if (request.method == 'PATCH') {
          return http.Response('{"error":"done"}', 400);
        }
        return http.Response(
          jsonEncode({
            'downloads': [_download('d')],
          }),
          200,
        );
      }),
    );
    final store = DownloadsStore(api);
    addTearDown(store.dispose);
    await store.refresh();

    await store.pause(store.all.single);
    expect(store.all.single.isActive, isTrue);
  });

  test('a poster marks what is arriving, else what is on disk', () async {
    // Seen 2026-09-30: a ring nearly full sat on a series whose episode was
    // on disk, summed with a copy left paused half way.
    Map<String, Object?> row(String id, String state, int episode, int got) => {
      'id': id,
      'itemId': 'tt1',
      'season': 1,
      'episode': episode,
      'name': 'Show',
      'state': state,
      'progress': {'completed': got, 'total': 100},
    };
    var rows = [row('e1', 'done', 1, 100), row('e2', 'paused', 2, 50)];
    final api = LumeoApi(
      baseUrl: 'http://127.0.0.1:7666',
      client: MockClient(
        (request) async => http.Response(jsonEncode({'downloads': rows}), 200),
      ),
    );
    final store = DownloadsStore(api);
    addTearDown(store.dispose);
    await pumpEventQueue();

    expect(DownloadMark.of(store, 'tt1')?.fraction, isNull);
    expect(DownloadMark.of(store, 'tt1'), isNotNull, reason: 'on disk');
    expect(
      DownloadMark.of(store, 'tt1', episode: (season: 1, episode: 2)),
      isNull,
      reason: 'paused half way is not a state of the episode',
    );
    expect(DownloadMark.of(store, 'tt2'), isNull);

    rows = [row('e1', 'done', 1, 100), row('e2', 'active', 2, 50)];
    await store.refresh();
    expect(DownloadMark.of(store, 'tt1')?.fraction, 0.5);
    expect(
      DownloadMark.of(store, 'tt1', episode: (season: 1, episode: 1))?.fraction,
      isNull,
      reason: 'the episode a card plays is on disk',
    );
  });
}
