import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/player/waiting.dart';
import 'package:lumeo/ui/widgets/loading.dart';

void main() {
  Widget waiting({Object? error, double? percent}) => MaterialApp(
    home: Scaffold(
      body: PlayerWaiting(
        title: 'S1 E2 · Episode',
        percent: percent,
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

  testWidgets('waiting presentation appears together after 300 ms', (
    tester,
  ) async {
    await tester.pumpWidget(waiting(percent: 0.5));
    expect(find.text('S1 E2 · Episode'), findsNothing);
    expect(find.text('50%'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pump(Loading.delay);
    expect(find.text('S1 E2 · Episode'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('finished progress stays hidden and failures show at once', (
    tester,
  ) async {
    await tester.pumpWidget(waiting(percent: 1, error: 'offline'));
    expect(find.text('S1 E2 · Episode'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    expect(find.text('The core stopped answering'), findsOneWidget);
  });
}
