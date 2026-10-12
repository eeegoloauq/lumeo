import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/ui/player/waiting.dart';

Download download(Map<String, dynamic> progress, {DateTime? waitingSince}) =>
    Download.fromJson({
      'id': 'd',
      'state': 'active',
      'resolved': true,
      'progress': progress,
      'waitingSince': ?waitingSince?.toIso8601String(),
    });

final arriving = download({
  'completed': 50,
  'total': 100,
  'peers': 12,
  'rate': 3 << 20,
});

void main() {
  Widget waiting({
    Object? error,
    Download? download,
    MediaSource? next,
    ValueChanged<MediaSource>? onNext,
  }) => MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: PlayerWaiting(
        title: 'S1 E2 · Episode',
        download: download,
        nextCopy: next,
        onNextCopy: onNext ?? (_) {},
        error: error,
        choiceError: null,
        choiceEmpty: false,
        overPicture: false,
        playbackError: null,
        decoderMissing: null,
        decoderInstallHint: null,
        onRetry: () {},
        onBack: () {},
        showBack: false,
      ),
    ),
  );

  testWidgets('waiting presentation appears together after the delay', (
    tester,
  ) async {
    await tester.pumpWidget(waiting(download: arriving));
    expect(find.text('S1 E2 · Episode'), findsNothing);
    expect(find.text('50% · 12 peers · 3.0 MB/s'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(PlayerWaiting.delay);
    expect(find.text('S1 E2 · Episode'), findsOneWidget);
    expect(find.text('50% · 12 peers · 3.0 MB/s'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('finished progress stays hidden and failures show at once', (
    tester,
  ) async {
    await tester.pumpWidget(waiting(download: arriving, error: 'offline'));
    expect(find.text('S1 E2 · Episode'), findsOneWidget);
    expect(find.textContaining('50%'), findsNothing);
    expect(find.text('The core stopped answering'), findsOneWidget);
  });

  testWidgets('a copy finding no peers says so and offers the next one', (
    tester,
  ) async {
    // The player said "0%" while the downloads panel said "Finding peers",
    // and offered nothing else to watch.
    final next = MediaSource.fromJson({
      'providerId': 'p',
      'rawName': 'Night of the Living Dead 1968 1080p YTS',
      'release': {'resolution': '1080p', 'group': 'YTS'},
      'size': 1610612736,
      'seeders': 100,
      'locator': {'scheme': 'torrent', 'infoHash': 'yts'},
    });
    MediaSource? picked;
    final since = DateTime.now().subtract(const Duration(seconds: 42));
    await tester.pumpWidget(
      waiting(
        download: download({}, waitingSince: since),
        next: next,
        onNext: (s) => picked = s,
      ),
    );
    await tester.pump(PlayerWaiting.delay);
    expect(find.textContaining('Finding peers · 0:4'), findsOneWidget);
    expect(find.text('1080p · YTS · 1.5 GB · 100 seeds'), findsOneWidget);
    await tester.tap(find.text('Try another copy'));
    expect(picked, same(next));
  });

  testWidgets('no other copy is offered before the wait runs long', (
    tester,
  ) async {
    await tester.pumpWidget(
      waiting(
        download: download({}, waitingSince: DateTime.now()),
        next: MediaSource.fromJson({
          'locator': {'scheme': 'torrent', 'infoHash': 'other'},
        }),
      ),
    );
    await tester.pump(PlayerWaiting.delay);
    expect(find.textContaining('Finding peers · 0:0'), findsOneWidget);
    expect(find.text('Try another copy'), findsNothing);
  });
}
