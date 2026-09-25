import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumeo/api/client.dart';
import 'package:lumeo/api/downloads_store.dart';
import 'package:lumeo/api/preferences_store.dart';
import 'package:lumeo/platform/decoders.dart';
import 'package:lumeo/platform/local_settings.dart';
import 'package:lumeo/ui/player/mpv_facts.dart';
import 'package:lumeo/ui/screens/settings/settings_screen.dart';
import 'package:lumeo/ui/theme.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';

/// A core with a preferences document and nothing downloaded, which is all
/// the page needs to be laid out; the UI suite drives the rest against the
/// fuller fake.
LumeoApi _core(List<String> calls) {
  final defaults = <String, Object?>{
    'subtitleLanguages': ['en'],
    'accent': 'white',
    'seekStep': 5,
    'nextNotice': 30,
    'nextCountdown': 5,
    'keep': 'watched',
    'keepDays': 30,
  };
  var preferences = Map<String, Object?>.of(defaults);
  http.Response json(Object body) => http.Response(jsonEncode(body), 200);
  return LumeoApi(
    baseUrl: 'http://127.0.0.1:1',
    client: MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/v1/preferences') {
        switch (request.method) {
          case 'PATCH':
            calls.add('PATCH ${request.body}');
            preferences = {
              ...preferences,
              ...jsonDecode(request.body) as Map<String, Object?>,
            };
          case 'DELETE':
            calls.add('DELETE');
            preferences = Map.of(defaults);
        }
        return json(preferences);
      }
      return switch (path) {
        '/healthz' => json({'status': 'ok', 'providers': 1}),
        '/api/v1/preferences/languages' => json({'languages': []}),
        '/api/v1/about' => json({
          'version': '0.1.61',
          'addr': '127.0.0.1:7666',
          'downloadDir': '/nowhere/Videos/Lumeo',
        }),
        '/api/v1/storage' => json({
          'dir': '/nowhere/Videos/Lumeo',
          'used': 0,
          'titles': [],
        }),
        '/api/v1/addons' => json({'addons': []}),
        '/api/v1/downloads' => json({'downloads': []}),
        _ => http.Response('{"error":"not here"}', 404),
      };
    }),
  );
}

const _bindings =
    '['
    '{"section":"default","key":"SPACE","cmd":"cycle pause",'
    '"comment":"toggle pause/playback mode"},'
    '{"section":"default","key":"RIGHT","cmd":"seek  5",'
    '"comment":"seek 5 seconds forward"},'
    '{"section":"default","key":"LEFT","cmd":"seek -5",'
    '"comment":"seek 5 seconds backward"},'
    '{"section":"default","key":"i","cmd":"script-binding stats/display"}'
    ']';

void main() {
  late Directory temporary;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('lumeo-settings-page-');
    MpvFacts.instance = MpvFacts(
      ask: () async => (bindings: _bindings, version: 'mpv 0.41.0'),
    );
    DeviceDecoders.instance = DeviceDecoders(
      ask: () async => '[{"codec":"h264","driver":"h264"}]',
      osRelease: () async => null,
    );
  });

  tearDown(() {
    MpvFacts.instance = MpvFacts();
    DeviceDecoders.instance = DeviceDecoders();
    temporary.deleteSync(recursive: true);
  });

  /// The page as the shell shows it, on a desktop-sized window.
  Future<({List<String> calls, Future<void> Function() done})> open(
    WidgetTester tester, {
    SettingsSection? section,
  }) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final calls = <String>[];
    final api = _core(calls);
    final downloads = DownloadsStore(api);
    final preferences = PreferencesStore(api);
    final settings = LocalSettings(path: '${temporary.path}/client.json');
    await preferences.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: lumeoTheme(),
        home: Scaffold(
          body: SettingsScreen(
            api: api,
            downloads: downloads,
            preferences: preferences,
            settings: settings,
            section: section,
            pictures: () async => '/nowhere/Pictures',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (
      calls: calls,
      // The scrollbar fades out on a timer of its own after a scroll.
      done: () async {
        await tester.pump(const Duration(seconds: 2));
        downloads.dispose();
        preferences.dispose();
      },
    );
  }

  Finder heading(SettingsSection section) => find.descendant(
    of: find.byKey(ValueKey('settings:${section.name}')),
    matching: find.text(section.title),
  );

  bool lit(WidgetTester tester, SettingsSection section) => find
      .ancestor(
        of: find.widgetWithText(TextButton, section.title),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.selected == true,
        ),
      )
      .evaluate()
      .isNotEmpty;

  testWidgets('the list scrolls to a section and lights it', (tester) async {
    final page = await open(tester);
    expect(
      find.widgetWithText(TextButton, 'General'),
      findsNothing,
      reason: 'a section with nothing that works in it is not offered',
    );
    expect(lit(tester, SettingsSection.appearance), isTrue);

    await tester.tap(find.widgetWithText(TextButton, 'Downloads'));
    await tester.pumpAndSettle();
    expect(lit(tester, SettingsSection.downloads), isTrue);
    expect(lit(tester, SettingsSection.appearance), isFalse);
    expect(
      tester.getTopLeft(heading(SettingsSection.downloads).first).dy,
      closeTo(TopBar.height + 56, 2),
      reason: 'the heading stands at the top of the view',
    );
    await page.done();
  });

  testWidgets('the scrollable reaches the window edge', (tester) async {
    final page = await open(tester);
    final scroll = find.byType(SingleChildScrollView);
    expect(tester.getSize(scroll).width, 1440);
    await page.done();
  });

  testWidgets('scrolling lights the section being read', (tester) async {
    final page = await open(tester);
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    // The last heading above the reading line, wherever the fling stopped.
    final reading = SettingsScreen.shown.lastWhere(
      (section) =>
          tester.getTopLeft(heading(section).first).dy <=
          TopBar.height + SettingsScreen.readingLine,
      orElse: () => SettingsScreen.shown.first,
    );
    expect(reading, isNot(SettingsSection.appearance), reason: 'it moved');
    expect(lit(tester, reading), isTrue);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -20000),
    );
    await tester.pumpAndSettle();
    expect(
      lit(tester, SettingsSection.about),
      isTrue,
      reason: 'at the bottom the last section is the one being read',
    );
    await page.done();
  });

  testWidgets('opened for a section, the page starts there', (tester) async {
    final page = await open(tester, section: SettingsSection.downloads);
    expect(lit(tester, SettingsSection.downloads), isTrue);
    expect(
      tester.getTopLeft(heading(SettingsSection.downloads).first).dy,
      closeTo(TopBar.height + 56, 2),
    );
    await page.done();
  });

  testWidgets('the arrow step is sent to the core and shown in Shortcuts', (
    tester,
  ) async {
    final page = await open(tester, section: SettingsSection.playback);
    expect(find.text('Seek 5 seconds forward'), findsOneWidget);
    await tester.tap(find.text('10 s'));
    await tester.pumpAndSettle();
    expect(page.calls.last, 'PATCH {"seekStep":10}');
    expect(
      find.text('Seek 10 seconds forward'),
      findsOneWidget,
      reason: 'the list is mpv\'s bindings with ours, at the stored step',
    );
    expect(find.text('Seek 10 seconds backward'), findsOneWidget);
    expect(
      find.textContaining('stats'),
      findsNothing,
      reason: 'only the everyday keys until All player keys',
    );
    await page.done();
  });

  testWidgets('Show next episode steps and sends only the last press', (
    tester,
  ) async {
    final page = await open(tester, section: SettingsSection.playback);
    expect(find.text('30 s'), findsOneWidget);
    await tester.tap(find.byTooltip('Later'));
    await tester.pump();
    await tester.tap(find.byTooltip('Later'));
    await tester.pump();
    expect(find.text('40 s'), findsOneWidget, reason: 'shown at once');
    expect(page.calls, isEmpty);
    await tester.pumpAndSettle(const Duration(milliseconds: 500));
    expect(page.calls, ['PATCH {"nextNotice":40}']);
    expect(find.text('40 s'), findsOneWidget);
    await page.done();
  });

  testWidgets('Reset asks first, then puts everything back', (tester) async {
    final page = await open(tester, section: SettingsSection.about);
    expect(find.text('mpv 0.41.0'), findsOneWidget);
    expect(find.text('127.0.0.1:7666'), findsOneWidget);
    await tester.ensureVisible(find.text('Reset…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(page.calls, isEmpty);

    await tester.tap(find.text('Reset…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();
    expect(page.calls, ['DELETE']);
    await page.done();
  });
}
