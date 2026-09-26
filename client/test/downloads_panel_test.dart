import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/api/downloads_store.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/api/preferences_store.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/platform/local_settings.dart';
import 'package:lumeo/ui/theme.dart';
import 'package:lumeo/ui/widgets/downloads_indicator.dart';

// The panel as a widget, against a core in memory. The UI suite drives it in
// the real application; this is what can be checked without one: every state
// laid out without overflowing, and every button reaching the core.

const _gb = 1024 * 1024 * 1024;

/// The desktop the client runs on: a phone would scroll the panel's list
/// with the window's own controller.
final _linux = TargetPlatformVariant.only(TargetPlatform.linux);

Map<String, Object?> _download(
  String id, {
  String state = 'active',
  int season = 0,
  int episode = 0,
  String? waitingSince,
  bool pausedByUser = false,
  String? error,
  int? eta,
  int rate = 0,
}) => {
  'id': id,
  'itemId': 'tt1',
  'name': 'Release $id',
  'state': state,
  'ready': true,
  'resolved': true,
  if (season > 0) 'season': season,
  if (episode > 0) 'episode': episode,
  'waitingSince': ?waitingSince,
  if (pausedByUser) 'pausedByUser': true,
  'error': ?error,
  'updatedAt': DateTime.now().toUtc().toIso8601String(),
  'progress': {
    'completed': _gb,
    'total': 2 * _gb,
    'rate': rate,
    'eta': ?eta,
    'peers': waitingSince == null ? 5 : 0,
  },
};

void main() {
  late List<Map<String, Object?>> downloads;
  late List<String> calls;
  late LumeoApi api;

  setUp(() {
    calls = [];
    downloads = [];
    api = LumeoApi(
      baseUrl: 'http://127.0.0.1:7666',
      client: MockClient((request) async {
        final path = request.url.path;
        if (request.method != 'GET') {
          calls.add('${request.method} $path ${request.body}'.trim());
        }
        if (request.method == 'PATCH' &&
            path.startsWith('/api/v1/downloads/')) {
          final d = downloads.firstWhere((d) => d['id'] == path.split('/')[4]);
          final paused = (jsonDecode(request.body) as Map)['paused'] as bool;
          d['state'] = paused ? 'paused' : 'active';
          d['pausedByUser'] = paused;
          return http.Response(jsonEncode(d), 200);
        }
        return switch (path) {
          '/api/v1/downloads' => http.Response(
            jsonEncode({'downloads': downloads}),
            200,
          ),
          '/api/v1/storage' => http.Response(
            jsonEncode({
              'dir': '/d',
              'used': 43 * _gb,
              'disk': {'total': 500 * _gb, 'free': 90 * _gb},
              'titles': const [],
            }),
            200,
          ),
          '/api/v1/progress/tt1' => http.Response(
            jsonEncode({
              'entries': [
                {'season': 2, 'episode': 3, 'watched': true},
              ],
            }),
            200,
          ),
          _ => http.Response('{"error":"no"}', 404),
        };
      }),
    );
  });

  Future<DownloadsStore> open(
    WidgetTester tester, {
    void Function(Download)? onPlay,
    void Function(Download)? onStop,
    VoidCallback? onStorage,
  }) async {
    final store = DownloadsStore(api);
    final preferences = PreferencesStore(api);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lumeoTheme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: DownloadsIndicator(
              api: api,
              store: store,
              settings: LocalSettings(path: '/nonexistent/client.json'),
              preferences: preferences,
              onStop: onStop ?? (_) {},
              onOpen: (_) {},
              onPlay: onPlay ?? (_) {},
              onStorage: onStorage ?? () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('downloads')));
    await tester.pumpAndSettle();
    return store;
  }

  /// Takes the panel down and stops the store's poll, which would otherwise
  /// be a timer left pending at the end of the test.
  Future<void> close(WidgetTester tester, DownloadsStore store) async {
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  }

  testWidgets('every state has its section, line and button', (tester) async {
    final since = DateTime.now()
        .toUtc()
        .subtract(const Duration(minutes: 4, seconds: 10))
        .toIso8601String();
    downloads = [
      _download('e3', state: 'done', season: 2, episode: 3),
      _download('e4', state: 'done', season: 2, episode: 4),
      _download('e5', season: 2, episode: 5, rate: 4 * 1024 * 1024, eta: 180),
      _download('e6', season: 2, episode: 6, rate: 1024 * 1024, eta: 720),
      _download('stalled', waitingSince: since),
      _download('paused', state: 'paused', pausedByUser: true),
      _download('failed', state: 'failed', error: 'no space left on device'),
      // Paused by the core, not by anybody: not listed.
      _download('quiet', state: 'paused'),
    ];
    final played = <String>[];
    final store = await open(tester, onPlay: (d) => played.add(d.id));

    expect(find.text('READY TO WATCH'), findsOneWidget);
    expect(find.text('ARRIVING'), findsOneWidget);
    expect(find.text('WAITING'), findsOneWidget);
    expect(find.text('S2 E3–E4'), findsOneWidget);
    expect(find.text('E4 next · 4.0 GB'), findsOneWidget);
    expect(find.text('S2 E5–E6'), findsOneWidget);
    expect(find.text('5.0 MB/s · 12 min left'), findsOneWidget);
    expect(find.text('about 12 min'), findsOneWidget);
    expect(find.text('Finding peers · 4 min'), findsOneWidget);
    expect(find.text('Paused'), findsOneWidget);
    expect(find.text('no space left on device'), findsOneWidget);
    expect(find.byKey(const ValueKey('download:quiet')), findsNothing);
    expect(find.text('43.0 GB · 90.0 GB free'), findsOneWidget);

    await tester.tap(find.byTooltip('Play S2 E4'));
    await tester.pumpAndSettle();
    expect(played, ['e4'], reason: 'E3 was watched');
    await close(tester, store);
  }, variant: _linux);

  testWidgets('pause, resume and retry reach the core', (tester) async {
    downloads = [
      _download('a', rate: 1024, eta: 60),
      _download('f', state: 'failed', error: 'tracker said no'),
    ];
    final store = await open(tester);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(calls, ['PATCH /api/v1/downloads/a {"paused":true}']);
    expect(find.text('Paused'), findsOneWidget, reason: 'at once');
    expect(find.text('ARRIVING'), findsNothing);

    await tester.tap(find.byTooltip('Resume'));
    await tester.pumpAndSettle();
    expect(calls.last, 'PATCH /api/v1/downloads/a {"paused":false}');
    expect(find.text('ARRIVING'), findsOneWidget);

    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(calls.last, 'PATCH /api/v1/downloads/f {"paused":false}');
    await close(tester, store);
  }, variant: _linux);

  testWidgets('a waiting season stops as a whole, or one episode at a time', (
    tester,
  ) async {
    final since = DateTime.now().toUtc().toIso8601String();
    downloads = [
      for (final e in [7, 8])
        _download('e$e', season: 2, episode: e, waitingSince: since),
    ];
    final stopped = <String>[];
    final store = await open(tester, onStop: (d) => stopped.add(d.id));

    await tester.tap(find.text('S2 E7–E8'));
    await tester.pumpAndSettle();
    expect(find.text('E7'), findsOneWidget, reason: 'opened into episodes');
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('download:e8')),
        matching: find.byTooltip('Stop and discard'),
      ),
    );
    expect(stopped, ['e8']);
    await tester.tap(find.byTooltip('Stop and discard E7–E8'));
    expect(stopped, ['e8', 'e7', 'e8']);
    await close(tester, store);
  }, variant: _linux);

  testWidgets('Storage › is the way to the settings', (tester) async {
    downloads = [_download('a', state: 'done')];
    var storage = 0;
    final store = await open(tester, onStorage: () => storage++);
    await tester.tap(find.text('Storage ›'));
    await tester.pumpAndSettle();
    expect(storage, 1);
    expect(find.text('READY TO WATCH'), findsNothing, reason: 'panel closed');
    await close(tester, store);
  }, variant: _linux);
}
