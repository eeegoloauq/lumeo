// Settings, and what each of its rows reaches.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/main.dart';
import 'package:lumeo/platform/decoders.dart';
import 'package:lumeo/ui/player/bindings.dart';
import 'package:lumeo/ui/player/chrome.dart';
import 'package:lumeo/ui/player/mpv_host.dart';
import 'package:lumeo/ui/screens/app_shell.dart';
import 'package:lumeo/ui/screens/settings/settings_screen.dart';
import 'package:lumeo/ui/theme.dart';
import 'package:lumeo/ui/widgets/setting_row.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';

import 'fake_core.dart';
import 'helpers.dart';

void settingsTests() {
  /// Opens Settings from the bar and scrolls it to [section] with the list
  /// beside the page, the way a person gets there.
  Future<void> openSettingsAt(
    WidgetTester tester,
    SettingsSection? section,
  ) async {
    await tester.tap(
      find.descendant(of: find.byType(TopBar), matching: find.text('Settings')),
    );
    await tester.pumpAndSettle();
    if (section == null) return;
    await tester.tap(
      find.widgetWithText(
        TextButton,
        section.title(lookupAppLocalizations(const Locale('en'))),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// One section of the settings page, to look for a control inside it: the
  /// page has several switches and segmented strips at once.
  Finder settingsSection(SettingsSection section) =>
      find.byKey(ValueKey('settings:${section.name}'));

  /// The segmented strip a label is a segment of.
  SegmentedButton<T> strip<T>(WidgetTester tester, String label) =>
      tester.widget<SegmentedButton<T>>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(SegmentedButton<T>),
        ),
      );

  testWidgets('Settings is a place, and Escape comes back from it', (
    tester,
  ) async {
    await openHome(tester);
    await openSettingsAt(tester, SettingsSection.about);
    expect(find.text('Core'), findsOneWidget);
    expect(find.text('Picture'), findsOneWidget);
    expect(
      find.text('answering'),
      findsOneWidget,
      reason: 'the page asked the core whether it is there',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await homeShown(tester);
  });

  testWidgets('the downloads panel\'s Storage link opens Settings at '
      'Downloads', (tester) async {
    await openHome(tester);
    final shell = tester.state(find.byType(AppShell));
    (shell as dynamic).openSettings(section: SettingsSection.downloads);
    await tester.pumpAndSettle();
    final heading = find.descendant(
      of: settingsSection(SettingsSection.downloads),
      matching: find.text('Downloads'),
    );
    expect(
      tester.getTopLeft(heading.first).dy,
      lessThan(TopBar.height + SettingsScreen.readingLine),
      reason: 'scrolled to its section, not left at the top of the page',
    );
    // Pressed again over a page already open: it scrolls there again.
    await tester.drag(
      find
          .descendant(
            of: find.byType(SettingsScreen),
            matching: find.byType(SingleChildScrollView),
          )
          .first,
      const Offset(0, 800),
    );
    await tester.pumpAndSettle();
    (shell as dynamic).openSettings(section: SettingsSection.downloads);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(heading.first).dy,
      lessThan(TopBar.height + SettingsScreen.readingLine),
    );
  });

  testWidgets(
    'Settings shows the subtitle languages the core has, and adds one',
    (tester) async {
      final patched = <String>[];
      await tester.pumpWidget(
        LumeoApp(
          api: fakeCore(patched: patched),
          settings: await temporarySettings(),
        ),
      );
      await tester.pumpAndSettle();
      await openSettingsAt(tester, SettingsSection.subtitles);

      expect(find.widgetWithText(InputChip, 'English'), findsOneWidget);
      final picker = find.descendant(
        of: settingsSection(SettingsSection.subtitles),
        matching: find.text('Add a language'),
      );
      await reveal(tester, picker.last);
      await tester.tap(picker.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Russian').last);
      await tester.pumpAndSettle();

      expect(jsonDecode(patched.last), {
        'subtitleLanguages': ['en', 'ru'],
      });
      expect(find.widgetWithText(InputChip, 'Russian'), findsOneWidget);
    },
  );

  testWidgets('Removing a language sends the list without it', (tester) async {
    final patched = <String>[];
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          preferences: {
            'subtitleLanguages': ['en', 'ru'],
          },
          patched: patched,
        ),
        settings: await temporarySettings(),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.subtitles);

    tester
        .widget<InputChip>(find.widgetWithText(InputChip, 'Russian'))
        .onDeleted!();
    await tester.pumpAndSettle();

    expect(jsonDecode(patched.last), {
      'subtitleLanguages': ['en'],
    });
    expect(find.widgetWithText(InputChip, 'Russian'), findsNothing);
  });

  testWidgets(
    'A core that answers late still gives the player the stored subtitle size',
    (tester) async {
      final patched = <String>[];
      await tester.pumpWidget(
        LumeoApp(
          api: fakeCore(
            downloads: [fakeDownload()],
            preferences: {
              'subtitleLanguages': ['en'],
              'subtitleScale': 1.4,
              'subtitlePosition': 90,
            },
            // The app's read at start and the player's first one both fail.
            preferencesUnreachable: 2,
            patched: patched,
          ),
          settings: await temporarySettings(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Play'));
      await pumpFor(tester, const Duration(seconds: 1));
      await waitFor(
        tester,
        () async =>
            double.parse(await mpvOnScreen(tester).getProperty('sub-scale')) ==
            1.4,
        what: 'the stored subtitle size applied',
      );
      expect(
        double.parse(await mpvOnScreen(tester).getProperty('sub-pos')),
        90,
      );
      await pumpFor(tester, const Duration(seconds: 1));
      expect(patched, isEmpty, reason: 'nothing the player read was stored');
    },
  );

  testWidgets('the stored subtitle colour, styling and arrow step reach mpv', (
    tester,
  ) async {
    // Read back from mpv rather than seen on screen: the colour is drawn into
    // the picture, and the step is a binding mpv seeks with.
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          preferences: {
            'subtitleLanguages': ['en'],
            'subtitleColor': 'yellow',
            'subtitleKeepStyling': false,
            'seekStep': 10,
          },
        ),
        settings: await temporarySettings(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await playerKeysReady(tester);
    final host = await MpvHost.attach(mpvOnScreen(tester));
    addTearDown(host.dispose);
    await waitFor(
      tester,
      () async => (await host.get('sub-ass-override')) == 'force',
      what: 'our style over the file\'s',
    );
    expect(
      (await host.get('sub-color'))?.toUpperCase(),
      anyOf('#FFE14D', '#FFFFE14D'),
    );
    final bindings = MpvBinding.parse(await host.get('input-bindings') ?? '');
    expect(
      bindings.where(
        (b) =>
            b.section == ownSection && b.key == 'RIGHT' && b.cmd == 'seek 10',
      ),
      isNotEmpty,
      reason: 'the arrow is bound to the stored step in our section',
    );
  });

  testWidgets('Episode stills stores the selected treatment', (tester) async {
    final patched = <String>[];
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          preferences: {
            'subtitleLanguages': ['en'],
            'episodeArtwork': 'hide',
          },
          patched: patched,
        ),
        settings: await temporarySettings(),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, null);

    expect(strip<String>(tester, 'Show').selected, {'hide'});
    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();

    expect(jsonDecode(patched.last), {'episodeArtwork': 'show'});
    expect(strip<String>(tester, 'Show').selected, {'show'});
  });

  testWidgets('Appearance stores the Violet accent and applies it', (
    tester,
  ) async {
    final patched = <String>[];
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(patched: patched),
        settings: await temporarySettings(),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, null);

    await tester.tap(find.byTooltip('Violet'));
    await tester.pumpAndSettle();

    expect(jsonDecode(patched.last), {'accent': 'violet'});
    expect(
      Theme.of(tester.element(find.text('Accent'))).colorScheme.primary,
      Palette.accents['violet'],
    );
  });

  testWidgets('Text size is this machine\'s, and scales the text', (
    tester,
  ) async {
    final patched = <String>[];
    final settings = await temporarySettings();
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(patched: patched),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, null);

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(SettingRow, 'Text size'),
        matching: find.text('Large'),
      ),
    );
    await tester.pumpAndSettle();
    expect(settings.textScale, 'large');
    expect(patched, isEmpty, reason: 'not the core\'s');
    expect(
      MediaQuery.textScalerOf(tester.element(find.text('Accent'))).scale(10),
      greaterThan(10),
    );
  });

  testWidgets('A preference the core refuses is shown and not applied', (
    tester,
  ) async {
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(preferencesFail: true),
        settings: await temporarySettings(),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, null);
    await tester.tap(find.text('Blur'));
    await tester.pumpAndSettle();

    expect(find.text('What it said'), findsOneWidget);
    expect(find.text('preferences refused'), findsOneWidget);
    expect(strip<String>(tester, 'Show').selected, {'show'});
  });

  testWidgets('Reset puts the preferences back, after asking', (tester) async {
    final patched = <String>[];
    final settings = await temporarySettings();
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          preferences: {
            'subtitleLanguages': ['en'],
            'accent': 'red',
          },
          patched: patched,
        ),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    settings.timelinePreviews = false;
    await openSettingsAt(tester, SettingsSection.about);
    await reveal(tester, find.text('Reset…'));
    await tester.tap(find.text('Reset…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.pumpAndSettle();

    expect(patched.last, 'DELETE');
    expect(
      Theme.of(tester.element(find.text('Accent'))).colorScheme.primary,
      Palette.accents['white'],
    );
    expect(settings.timelinePreviews, isTrue);
  });

  testWidgets('Sources lists the addons and what each one serves', (
    tester,
  ) async {
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(), settings: await temporarySettings()),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.sources);

    final sources = settingsSection(SettingsSection.sources);
    Finder inSources(Finder f) => find.descendant(of: sources, matching: f);
    expect(inSources(find.text('Cinemeta')), findsOneWidget);
    expect(inSources(find.text('Catalog · Titles')), findsOneWidget);
    expect(inSources(find.text('Streams')), findsOneWidget);
    expect(inSources(find.text('Subtitles')), findsOneWidget);
    expect(inSources(find.byType(Switch)), findsNWidgets(3));
    expect(
      inSources(find.text('Streams from public trackers.')),
      findsOneWidget,
    );
    expect(inSources(find.text('Remove')), findsNWidgets(3));
  });

  testWidgets('Switching an addon off is sent to the core', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(addonCalls: calls),
        settings: await temporarySettings(),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.sources);

    final switches = find.descendant(
      of: settingsSection(SettingsSection.sources),
      matching: find.byType(Switch),
    );
    await reveal(tester, switches.at(1));
    await tester.tap(switches.at(1));
    await tester.pumpAndSettle();

    expect(calls.last, 'PATCH /api/v1/addons/torrentio {"enabled":false}');
    expect(tester.widget<Switch>(switches.at(1)).value, isFalse);
  });

  testWidgets(
    'An address is checked by the core: a refusal stays at the field, an '
    'addon joins the list',
    (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        LumeoApp(
          api: fakeCore(addonCalls: calls),
          settings: await temporarySettings(),
        ),
      );
      await tester.pumpAndSettle();
      await openSettingsAt(tester, SettingsSection.sources);

      final field = find.widgetWithText(TextField, 'Addon address');
      await reveal(tester, field);
      await tester.enterText(field, 'http://dead.invalid');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(
        find.text('no addon answered there: 404 Not Found'),
        findsOneWidget,
      );
      expect(find.text('Public Domain Movies'), findsNothing);

      // Enter handed the keyboard back; a typed address needs it again.
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'https://pd.invalid/manifest.json');
      final add = find.widgetWithText(OutlinedButton, 'Add');
      await reveal(tester, add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(
        calls.last,
        'POST /api/v1/addons {"url":"https://pd.invalid/manifest.json"}',
      );
      expect(find.text('Public Domain Movies'), findsOneWidget);
      expect(find.text('Catalog · Titles · Streams'), findsOneWidget);
      expect(find.text('no addon answered there: 404 Not Found'), findsNothing);
      expect(
        tester.widget<TextField>(field).controller!.text,
        isEmpty,
        reason: 'the address was taken',
      );
    },
  );

  testWidgets('Removing an addon takes it off the list', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(addonCalls: calls),
        settings: await temporarySettings(),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.sources);

    final sources = settingsSection(SettingsSection.sources);
    final remove = find.descendant(of: sources, matching: find.text('Remove'));
    await reveal(tester, remove.last);
    await tester.tap(remove.last);
    await tester.pumpAndSettle();

    expect(calls.last, 'DELETE /api/v1/addons/opensubtitles');
    expect(find.text('OpenSubtitles v3'), findsNothing);
    expect(
      find.descendant(of: sources, matching: find.byType(Switch)),
      findsNWidgets(2),
    );
  });

  testWidgets('Downloads lists titles and deletes one', (tester) async {
    await tester.pumpWidget(
      LumeoApp(api: fakeCore(), settings: await temporarySettings()),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.downloads);

    expect(find.text('The Expanse'), findsOneWidget);
    expect(find.text('2 episodes · downloading'), findsOneWidget);
    expect(find.text('Arrival'), findsOneWidget);
    expect(find.text('Film'), findsOneWidget);
    expect(find.text('Delete all'), findsOneWidget);

    // Escape closes a dialog, not the page under it: the shell takes the
    // keyboard back only when nothing is open over it.
    await reveal(tester, find.text('Delete all'));
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Arrival'), findsOneWidget, reason: 'still in Settings');

    final arrival = find.byKey(const ValueKey('storage:tt2543164'));
    await reveal(tester, arrival);
    await tester.tap(
      find.descendant(of: arrival, matching: find.text('Delete')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Arrival'), findsNothing);
    expect(find.text('The Expanse'), findsOneWidget);

    final cache = find.widgetWithText(SettingRow, 'Cached artwork');
    await reveal(tester, cache);
    expect(
      find.descendant(of: cache, matching: find.text('212 MB')),
      findsOneWidget,
    );
    await tester.tap(find.descendant(of: cache, matching: find.text('Clear')));
    await tester.pumpAndSettle();
    expect(
      find.text('Cached artwork'),
      findsNothing,
      reason: 'nothing left to clear',
    );
  });

  testWidgets('Downloads stores the keep policy, the disk limit, prefetch and '
      'seeding', (tester) async {
    final patched = <String>[];
    final settings = await temporarySettings();
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(patched: patched),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.downloads);
    final downloads = settingsSection(SettingsSection.downloads);

    await tester.tap(find.text('Right away'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'keep': 'watched'});
    expect(strip<String>(tester, 'Right away').selected, {'watched'});

    await tester.tap(find.text('After 30 days'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'keep': 'days', 'keepDays': 30});

    // Custom asks for the number of days, and then names it.
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Right away'),
          matching: find.byType(SegmentedButton<String>),
        ),
        matching: find.text('Custom'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '12');
    await tester.tap(find.text('Set'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'keep': 'days', 'keepDays': 12});
    expect(find.text('After 12 days'), findsOneWidget);

    await tester.tap(find.text('100 GB'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'diskLimit': 100 << 30});
    expect(strip<int>(tester, '100 GB').selected, {100 << 30});

    final prefetch = find.descendant(
      of: find.widgetWithText(SettingRow, 'Download next episode'),
      matching: find.byType(Switch),
    );
    await tester.tap(prefetch);
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'prefetch': false});
    expect(tester.widget<Switch>(prefetch).value, isFalse);

    final seeding = find.descendant(
      of: find.widgetWithText(SettingRow, 'Seeding'),
      matching: find.byType(Switch),
    );
    await reveal(tester, seeding);
    await tester.tap(seeding);
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'seed': false});

    final upload = find.descendant(
      of: find.widgetWithText(SettingRow, 'Upload limit'),
      matching: find.text('1 MB/s'),
    );
    await tester.tap(upload);
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'uploadLimit': 1 << 20});

    // This machine's, so it goes to client.json and not to the core.
    final finished = find.descendant(
      of: downloads,
      matching: find.text('7 days'),
    );
    await reveal(tester, finished);
    await tester.tap(finished);
    await tester.pumpAndSettle();
    expect(settings.keepFinished, '7d');
    expect(jsonDecode(patched.last), {'uploadLimit': 1 << 20});
  });

  testWidgets(
    'Downloads names the folders, and offers to open and change the videos '
    'one only on this machine',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('lumeo-downloads-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final patched = <String>[];
      await tester.pumpWidget(
        LumeoApp(
          api: fakeCore(
            baseUrl: 'http://127.0.0.1:1',
            aboutDir: directory.path,
            patched: patched,
          ),
          settings: await temporarySettings(),
        ),
      );
      await tester.pumpAndSettle();
      await openSettingsAt(tester, SettingsSection.downloads);

      final videos = find.byKey(const ValueKey('settings:videos'));
      expect(find.text(directory.path), findsOneWidget);
      expect(
        find.descendant(of: videos, matching: find.text('Open')),
        findsOneWidget,
      );

      // Change walks this machine's folders and sends the one picked.
      Directory('${directory.path}/Films').createSync();
      await reveal(tester, videos);
      await tester.tap(
        find.descendant(of: videos, matching: find.text('Change')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Films'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();
      expect(jsonDecode(patched.last), {
        'downloadDir': '${directory.path}/Films',
      });
      expect(find.text('${directory.path}/Films'), findsOneWidget);

      await tester.pumpWidget(
        LumeoApp(
          key: UniqueKey(),
          api: fakeCore(aboutDir: directory.path),
          settings: await temporarySettings(),
        ),
      );
      await tester.pumpAndSettle();
      await openSettingsAt(tester, SettingsSection.downloads);

      expect(find.text(directory.path), findsOneWidget);
      expect(
        find.descendant(of: videos, matching: find.text('Open')),
        findsNothing,
      );
      expect(
        find.descendant(of: videos, matching: find.text('Change')),
        findsNothing,
        reason: 'a folder on another machine is not ours to browse',
      );
    },
  );

  testWidgets('Timeline previews off, no second mpv is made for the bar', (
    tester,
  ) async {
    final server = await serveFilm();
    final settings = await temporarySettings();
    settings.timelinePreviews = false;
    await tester.pumpWidget(
      LumeoApp(
        api: fakeCore(
          downloads: [fakeDownload()],
          baseUrl: 'http://127.0.0.1:${server.port}',
        ),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play'));
    await pumpFor(tester, const Duration(seconds: 1));
    final mpv = mpvOnScreen(tester);
    await waitFor(
      tester,
      () async => (double.tryParse(await mpv.getProperty('time-pos')) ?? 0) > 0,
      what: 'the film played',
    );
    // The frames' only source is what the bar is handed; with it off the bar
    // is handed nothing, so nothing can start one.
    expect(
      find.byWidgetPredicate((w) => w is PlayerChrome && w.thumbnails != null),
      findsNothing,
    );
  });

  testWidgets('Settings prints the commands for a broken decoder, and copies '
      'them', (tester) async {
    // The advice used to be one install line inside the warning, and on a
    // machine that has not enabled RPM Fusion that line answers "no match":
    // the first person to follow it had to be handed the missing half by
    // somebody else. It is two commands now, in the order they have to run,
    // with a button that puts both on the clipboard — rather than a button
    // that would have to be root inside the application that opens files from
    // a swarm.
    DeviceDecoders.instance = DeviceDecoders(
      ask: () async =>
          '[{"codec":"h264","driver":"libopenh264","description":"OpenH264"}]',
      osRelease: () async => 'ID=fedora\n',
    );
    addTearDown(() => DeviceDecoders.instance = DeviceDecoders());

    final copied = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add(
          (call.arguments as Map<Object?, Object?>)['text']! as String,
        );
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await openHome(tester);
    await openSettingsAt(tester, SettingsSection.about);

    Finder command(String part) => find.byWidgetPredicate(
      (w) => w is SelectableText && (w.data ?? '').contains(part),
    );

    expect(
      find.textContaining('loses sync on a backward seek'),
      findsOneWidget,
      reason: 'the warning says what is wrong',
    );
    expect(
      command('rpmfusion-free-release'),
      findsOneWidget,
      reason: 'and the repository, without which the install alone fails',
    );
    expect(command('libavcodec-freeworld'), findsOneWidget);

    final copy = find.byTooltip('Copy');
    await tester.ensureVisible(copy);
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(copied.single, contains('rpmfusion-free-release'));
    expect(copied.single, contains('libavcodec-freeworld'));
    expect(
      find.byTooltip('Copied'),
      findsOneWidget,
      reason: 'a button that looks the same afterwards is pressed twice',
    );
  });
}
