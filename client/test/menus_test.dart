import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/languages.dart';
import 'package:lumeo/api/models.dart' as api;
import 'package:lumeo/ui/player/menus.dart';
import 'package:lumeo/ui/player/tracks.dart';

void main() {
  final languages = Languages(const [
    api.NamedLanguage(code: 'en', name: 'English', aliases: ['eng']),
    api.NamedLanguage(code: 'ja', name: 'Japanese', aliases: ['jpn']),
    api.NamedLanguage(code: 'pl', name: 'Polish', aliases: ['pol']),
    api.NamedLanguage(code: 'th', name: 'Thai', aliases: ['tha']),
  ]);

  const audio = [
    MpvTrack(
      id: '1',
      type: 'audio',
      language: 'jpn',
      codec: 'aac',
      channels: 2,
      selected: true,
    ),
    MpvTrack(
      id: '2',
      type: 'audio',
      language: 'eng',
      title: 'Commentary',
      codec: 'eac3',
      channels: 6,
    ),
  ];
  const subtitles = [
    MpvTrack(id: '1', type: 'sub', language: 'jpn', title: 'Japanese'),
    MpvTrack(
      id: '2',
      type: 'sub',
      language: 'en-US',
      title: 'Full',
      selected: true,
    ),
    MpvTrack(
      id: '3',
      type: 'sub',
      language: 'eng',
      title: 'Signs & Songs',
      forced: true,
    ),
  ];
  const found = [
    api.Subtitle(
      id: 'a',
      language: 'en',
      languageName: 'English',
      url: '/api/v1/subtitles/a',
      name: 'Re.ZERO.S04E17.WEB',
    ),
    api.Subtitle(
      id: 'b',
      language: 'en',
      languageName: 'English',
      url: '/api/v1/subtitles/b',
      name: 'ReZero.S4E17.BluRay',
    ),
    api.Subtitle(
      id: 'c',
      language: 'pl',
      languageName: 'Polish',
      url: '/api/v1/subtitles/c',
      name: 'Re.ZERO.S04E17.PL',
      hashMatch: true,
      fps: 23.976,
    ),
    api.Subtitle(
      id: 'd',
      language: 'pl',
      languageName: 'Polish',
      url: '/api/v1/subtitles/d',
      name: 'ReZero.17.PL',
      fps: 25,
    ),
    api.Subtitle(
      id: 'e',
      language: 'th',
      languageName: 'Thai',
      url: '/api/v1/subtitles/e',
      name: '2026.ReZero.S4.E17',
    ),
  ];

  final picked = <String>[];
  Widget menu({List<MpvTrack> subs = subtitles}) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: TracksMenu(
          audio: audio,
          subtitles: subs,
          found: found,
          languages: languages,
          preferredSubtitles: const ['en', 'ja'],
          looking: false,
          error: null,
          delay: 0,
          scale: 1,
          position: 100,
          url: (path) => 'http://core$path',
          onAudio: (t) => picked.add('audio:${t.id}'),
          onSubtitle: (t) => picked.add('sub:${t?.id ?? 'off'}'),
          onFound: (s) => picked.add('found:${s.id}'),
          onRetry: () {},
          onDelay: (_) {},
          onScale: (value) => picked.add('scale:$value'),
          onPosition: (_) {},
          background: 'none',
          onBackground: (value) => picked.add('background:$value'),
        ),
      ),
    ),
  );

  testWidgets('one list of languages, named, the file first', (tester) async {
    // What the screen used to show: "EN-US" over "English", a strip of
    // language chips built from the database alone, and the file's tracks
    // under one heading with the database's under another — three lists for
    // one choice.
    await tester.pumpWidget(menu());
    expect(find.text('EN-US'), findsNothing);
    expect(
      find.text('English'),
      findsNWidgets(2),
      reason: 'both embedded subtitle tracks retain their language',
    );
    expect(find.text('English · Commentary'), findsOneWidget);
    expect(find.text('Full'), findsOneWidget);
    expect(find.text('Signs & Songs'), findsOneWidget);
    // Japanese is in the file too, so it is listed — after the English
    // tracks, because English is the viewer's first language.
    final english = tester.getTopLeft(find.text('Full'));
    final japanese = tester.getTopLeft(find.text('Japanese').last);
    expect(japanese.dy, greaterThan(english.dy));
    // A language the file already carries is not offered again from the
    // database as a row of its own; the copies are behind the count.
    expect(find.text('Re.ZERO.S04E17.WEB'), findsNothing);
    expect(find.text('2 more'), findsOneWidget);
    // One the file does not carry is a row, with its best copy under it and
    // the rest behind the count.
    expect(find.text('Polish'), findsOneWidget);
    expect(find.text('OpenSubtitles'), findsWidgets);
    expect(find.text('ReZero.17.PL'), findsNothing);
    expect(find.text('1 more'), findsOneWidget);
    expect(find.text('Thai'), findsOneWidget);
    // The soundtrack, with what a viewer compares two of them by.
    expect(find.text('2.0'), findsOneWidget);
    expect(find.text('5.1'), findsOneWidget);
  });

  testWidgets('the count opens the other copies, and the row still picks', (
    tester,
  ) async {
    await tester.pumpWidget(menu());
    await tester.tap(find.text('1 more'));
    await tester.pumpAndSettle();
    expect(find.text('ReZero.17.PL'), findsOneWidget);
    // The column scrolls once the copies are open.
    await tester.ensureVisible(find.text('ReZero.17.PL'));
    await tester.pumpAndSettle();
    Future<void> pick(String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(text));
      await tester.pump();
    }

    await pick('ReZero.17.PL');
    await pick('Polish');
    await pick('Signs & Songs');
    await pick('Off');
    await pick('English · Commentary');
    expect(picked, ['found:d', 'found:c', 'sub:3', 'sub:off', 'audio:2']);
  });

  testWidgets(
    'a database copy that is on is marked, not listed as the file\'s',
    (tester) async {
      await tester.pumpWidget(
        menu(
          subs: const [
            MpvTrack(id: '1', type: 'sub', language: 'jpn'),
            MpvTrack(
              id: '4',
              type: 'sub',
              language: 'pl',
              external: true,
              externalFilename: 'http://core/api/v1/subtitles/c',
              selected: true,
            ),
          ],
        ),
      );
      expect(find.text('Polish'), findsOneWidget);
      final row = tester.widget<Text>(find.text('Polish'));
      expect(
        row.style?.color,
        isNot(equals(tester.widget<Text>(find.text('Off')).style?.color)),
        reason: 'the loaded copy is the one lit',
      );
      // Rows are menu items, so the keyboard can reach them.
      expect(find.byType(MenuItemButton), findsWidgets);
    },
  );

  testWidgets(
    'a loaded copy of a language the file carries is not folded away',
    (tester) async {
      // The database's English copies sit behind the count on the file's own
      // English row. With one of them loaded — the file's track was a second
      // out — the menu used to open folded, with nothing in it marked as on.
      await tester.pumpWidget(
        menu(
          subs: const [
            MpvTrack(id: '2', type: 'sub', language: 'en-US', title: 'Full'),
            MpvTrack(
              id: '4',
              type: 'sub',
              language: 'en',
              external: true,
              externalFilename: 'http://core/api/v1/subtitles/b',
              selected: true,
            ),
          ],
        ),
      );
      expect(
        find.text('ReZero.S4E17.BluRay'),
        findsOneWidget,
        reason: 'the loaded copy is on screen without a click',
      );
      expect(
        find.text('Re.ZERO.S04E17.WEB'),
        findsOneWidget,
        reason: 'unfolded with the rest of its language',
      );
      expect(
        find.text('ReZero.17.PL'),
        findsNothing,
        reason: 'and only that language',
      );
    },
  );

  testWidgets('subtitle style opens from the tune icon', (tester) async {
    await tester.pumpWidget(menu());
    expect(find.text('Size'), findsNothing);
    await tester.tap(find.byTooltip('Subtitle style'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuBack, 'Subtitle style'), findsOneWidget);
    expect(find.text('Position'), findsOneWidget);
    expect(find.text('Timing'), findsOneWidget);
    expect(find.text('AUDIO'), findsNothing);
    await tester.tap(find.text('L'));
    expect(picked.last, 'scale:1.25');
    await tester.tap(find.text('Box'));
    expect(picked.last, 'background:box');
    await tester.tap(find.widgetWithText(MenuBack, 'Subtitle style'));
    await tester.pumpAndSettle();
    expect(find.text('AUDIO'), findsOneWidget);
  });

  testWidgets('gear Speed page sets 1.5× and returns to the list', (
    tester,
  ) async {
    var rate = 1.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => SettingsMenu(
                rate: rate,
                fit: 0,
                onRate: (value) => setState(() => rate = value),
                onFit: (_) {},
                onShortcuts: () {},
                onStats: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Speed'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(MenuBack, 'Speed'), findsOneWidget);
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(rate, 1.5);
    await tester.tap(find.widgetWithText(MenuBack, 'Speed'));
    await tester.pumpAndSettle();
    expect(find.text('1.5×'), findsOneWidget);
  });

  testWidgets('a search that found nothing more says so under both columns, '
      'with its own button', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: TracksMenu(
              audio: audio,
              subtitles: subtitles,
              found: const [],
              languages: languages,
              preferredSubtitles: const ['en'],
              looking: false,
              error: null,
              delay: 0,
              scale: 1,
              position: 100,
              url: (path) => path,
              onAudio: (_) {},
              onSubtitle: (_) {},
              onFound: (_) {},
              onRetry: () => retried++,
              onDelay: (_) {},
              onScale: (_) {},
              onPosition: (_) {},
              background: 'none',
              onBackground: (_) {},
            ),
          ),
        ),
      ),
    );
    final note = find.text('OpenSubtitles has nothing else for this file');
    expect(note, findsOneWidget);
    expect(
      find.byType(MenuRow).evaluate().map((e) => e.widget),
      isNot(
        contains(
          isA<MenuRow>().having(
            (r) => r.label,
            'label',
            contains('OpenSubtitles'),
          ),
        ),
      ),
    );
    expect(
      tester.getRect(note).left,
      lessThan(tester.getRect(find.text('AUDIO')).right),
      reason: 'it spans the panel, not the subtitle column',
    );
    await tester.tap(find.text('Search again'));
    expect(retried, 1);
  });

  group('download panel', () {
    const done = api.Download(
      id: 'e17',
      itemId: 'tt1',
      name: 'Re.Zero.S04E17.1080p',
      state: 'done',
      season: 4,
      episode: 17,
      progress: api.Progress(completed: 1500000000, total: 1500000000),
    );
    const next = api.Episode(season: 4, number: 18, title: 'The Oath');

    Future<void> show(WidgetTester tester, DownloadPanel panel) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Center(child: panel)),
          ),
        );

    testWidgets('a refused prefetch offers Download anyway and Storage', (
      tester,
    ) async {
      var asked = 0, storage = 0;
      await show(
        tester,
        DownloadPanel(
          download: done,
          next: next,
          nextFetch: NextFetch.noRoom,
          onDownloadNext: () => asked++,
          onStorage: () => storage++,
        ),
      );
      expect(find.text('This episode'), findsOneWidget);
      expect(find.text('On disk'), findsOneWidget);
      expect(find.text('Next · E18 The Oath'), findsOneWidget);
      expect(find.text('No room'), findsOneWidget);
      // A menu item runs its action on the frame after the tap.
      await tester.tap(find.text('Download anyway'));
      await tester.pump();
      await tester.tap(find.text('Storage settings'));
      await tester.pump();
      expect((asked, storage), (1, 1));
    });

    testWidgets('prefetch off offers Download now and no waiting', (
      tester,
    ) async {
      await show(
        tester,
        DownloadPanel(download: done, next: next, nextFetch: NextFetch.off),
      );
      expect(find.text('Download now'), findsOneWidget);
      expect(find.text('Waiting'), findsNothing);
    });

    testWidgets('a film arriving shows its numbers and no next section', (
      tester,
    ) async {
      await show(
        tester,
        const DownloadPanel(
          download: api.Download(
            id: 'f',
            itemId: 'tt2',
            name: 'Film.2160p',
            state: 'active',
            resolved: true,
            progress: api.Progress(
              completed: 1 << 30,
              total: 4 << 30,
              rate: 4 << 20,
              peers: 12,
              seeders: 7,
            ),
          ),
        ),
      );
      expect(find.text('This film'), findsOneWidget);
      expect(find.text('25 %'), findsOneWidget);
      expect(find.text('1.0 GB of 4.0 GB · about 13 min left'), findsOneWidget);
      expect(find.text('4.0 MB/s · 12 peers, 7 seeding'), findsOneWidget);
      expect(find.textContaining('Next'), findsNothing);
    });

    testWidgets('a magnet with peers and no metadata yet says it is asking', (
      tester,
    ) async {
      await show(
        tester,
        const DownloadPanel(
          download: api.Download(
            id: 'f',
            itemId: 'tt2',
            name: 'Film.2160p',
            state: 'active',
            progress: api.Progress(total: 4 << 30, peers: 3),
          ),
        ),
      );
      expect(find.text('Fetching metadata · 3 peers'), findsOneWidget);
    });
  });
}
