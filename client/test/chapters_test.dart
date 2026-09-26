import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/ui/player/bindings.dart';
import 'package:lumeo/ui/player/chapters.dart';
import 'package:lumeo/ui/player/chrome.dart';
import 'package:lumeo/ui/player/menus.dart';
import 'package:lumeo/ui/theme.dart';

void main() {
  const chapters = [
    MpvChapter(time: Duration.zero, title: 'Cold open'),
    MpvChapter(time: Duration(minutes: 25)),
    MpvChapter(time: Duration(minutes: 90), title: 'Ending'),
  ];

  test('the chapter list is read as mpv prints it', () {
    const json = '[{"title":"Opening","time":85.5},{"time":1400}]';
    final parsed = MpvChapter.parse(json);
    expect(parsed.map((c) => c.title).toList(), ['Opening', '']);
    expect(parsed[0].time, const Duration(milliseconds: 85500));
    expect(parsed[1].time, const Duration(seconds: 1400));
    expect(MpvChapter.parse(''), isEmpty);
    expect(MpvChapter.parse('{'), isEmpty);
  });

  test('a chapter without a name is numbered; a time falls in the last one '
      'started', () {
    expect(
      chapterLabel(chapters, 0, lookupAppLocalizations(const Locale('en'))),
      'Cold open',
    );
    expect(
      chapterLabel(chapters, 1, lookupAppLocalizations(const Locale('en'))),
      'Chapter 2',
    );
    expect(chapterAt(chapters, const Duration(minutes: 24)), 0);
    expect(chapterAt(chapters, const Duration(minutes: 25)), 1);
    expect(chapterAt(chapters, const Duration(minutes: 95)), 2);
    expect(
      chapterAt(const [MpvChapter(time: Duration(minutes: 1))], Duration.zero),
      isNull,
    );
  });

  testWidgets('the bubble over the bar names the chapter under the pointer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: lumeoTheme(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: Scrubber(
                position: Duration.zero,
                duration: const Duration(minutes: 100),
                chapters: chapters,
                acquired: 1,
                onScrub: (_) {},
                onSeek: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    final track = tester.getRect(find.byType(Slider));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.hover(Offset(track.left + track.width * 0.5, track.center.dy)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Chapter 2'), findsOneWidget);
    expect(find.text('50:00'), findsOneWidget);
  });

  testWidgets('the settings menu lists the chapters, the current one marked, '
      'and none when there are none', (tester) async {
    final picked = <int>[];
    Widget menu(List<MpvChapter> chapters) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SettingsMenu(
            rate: 1,
            fit: 0,
            chapters: chapters,
            chapter: 1,
            onRate: (_) {},
            onFit: (_) {},
            onChapter: picked.add,
            onShortcuts: () {},
            onStats: () {},
          ),
        ),
      ),
    );
    await tester.pumpWidget(menu(const []));
    expect(find.text('Chapters'), findsNothing);

    await tester.pumpWidget(menu(chapters));
    await tester.tap(find.text('Chapters'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuBack, 'Chapters'), findsOneWidget);
    expect(find.text('Cold open'), findsOneWidget);
    expect(find.text('1:30:00'), findsOneWidget);
    Color? colour(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    expect(
      colour('Chapter 2'),
      isNot(equals(colour('Cold open'))),
      reason: 'the one being played is lit',
    );
    await tester.tap(find.text('Ending'));
    await tester.pump();
    expect(picked, [2]);
  });

  testWidgets('the shortcut page opens at its top however far the chapters '
      'were scrolled', (tester) async {
    // The two pages are one scroll view in one place, and Flutter keeps the
    // offset of a scroll view it can reuse: a shortcut page opened after a
    // long chapter list had been scrolled opened with its back row out of
    // sight, until the pages were keyed apart.
    final many = [
      for (var i = 0; i < 40; i++)
        MpvChapter(
          time: Duration(minutes: i),
          title: 'Chapter $i',
        ),
    ];
    var asked = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SettingsMenu(
              rate: 1,
              fit: 0,
              chapters: many,
              shortcuts: [
                for (var i = 0; i < 60; i++)
                  Shortcut(keys: ['F$i'], what: 'Line $i'),
              ],
              onRate: (_) {},
              onFit: (_) {},
              onShortcuts: () => asked++,
              onStats: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Chapters'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuBack, 'Chapters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keyboard shortcuts'));
    await tester.pumpAndSettle();
    expect(asked, 1);
    final panel = tester.getRect(find.byType(MenuPanel));
    final back = tester.getRect(
      find.widgetWithText(MenuBack, 'Keyboard shortcuts'),
    );
    expect(back.top, greaterThanOrEqualTo(panel.top));
    expect(back.bottom, lessThanOrEqualTo(panel.bottom));
    expect(find.text('Line 0'), findsOneWidget);

    await tester.tap(find.widgetWithText(MenuBack, 'Keyboard shortcuts'));
    await tester.pumpAndSettle();
    expect(find.text('Speed'), findsOneWidget);
  });
}
