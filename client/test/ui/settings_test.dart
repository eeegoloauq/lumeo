// Settings, and what each of its rows reaches.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/l10n/app_localizations.dart';
import 'package:lumeo/platform/decoders.dart';
import 'package:lumeo/platform/local_settings.dart';
import 'package:lumeo/ui/screens/settings/settings_screen.dart';
import 'package:lumeo/ui/theme.dart';
import 'package:lumeo/ui/widgets/artwork_image.dart';
import 'package:lumeo/ui/widgets/setting_row.dart';
import 'package:lumeo/ui/widgets/top_bar.dart';

import 'fake_core.dart';
import 'app.dart';

void main() {
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

  uiTest('the subtitle sample is drawn over the last title watched', (
    tester,
  ) async {
    // Nothing serves it: what is under test is which picture is asked for.
    final retries = ArtworkImage.retryDelays;
    ArtworkImage.retryDelays = const [];
    addTearDown(() => ArtworkImage.retryDelays = retries);
    const picture = 'http://127.0.0.1:1/backdrop.jpg';
    final watched = continueItem('tt0063350', {
      'season': 0,
      'episode': 0,
      'position': 900.0,
      'duration': 5700.0,
      'watched': false,
      'updatedAt': '2026-09-20T12:00:00Z',
    });
    (watched['item'] as Map<String, dynamic>)['background'] = picture;
    await tester.pumpWidget(
      testApp(api: fakeCore(continueWatching: [watched])),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.audioSubtitles);
    expect(
      find.descendant(
        of: settingsSection(SettingsSection.audioSubtitles),
        matching: find.byWidgetPredicate(
          (w) => w is Image && w.image == const ArtworkImage(picture),
        ),
      ),
      findsOneWidget,
    );
  });

  uiTest('Settings is a place, and Escape comes back from it', (tester) async {
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

  uiTest('Settings shows the subtitle languages the core has, and adds one', (
    tester,
  ) async {
    final patched = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(patched: patched)));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.audioSubtitles);

    expect(find.widgetWithText(InputChip, 'English'), findsOneWidget);
    final picker = find.ancestor(
      of: find.descendant(
        of: settingsSection(SettingsSection.audioSubtitles),
        matching: find.text('Add a language'),
      ),
      matching: find.byType(TextField),
    );
    await reveal(tester, picker.last);
    await tester.tap(picker.last);
    await tester.pumpAndSettle();
    await tester.enterText(picker.last, 'Rus');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Russian').last);
    await tester.pumpAndSettle();

    expect(jsonDecode(patched.last), {
      'subtitleLanguages': ['en', 'ru'],
    });
    expect(find.widgetWithText(InputChip, 'Russian'), findsOneWidget);
  });

  uiTest('Removing a language sends the list without it', (tester) async {
    final patched = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          preferences: {
            'subtitleLanguages': ['en', 'ru'],
          },
          patched: patched,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.audioSubtitles);

    tester
        .widget<InputChip>(find.widgetWithText(InputChip, 'Russian'))
        .onDeleted!();
    await tester.pumpAndSettle();

    expect(jsonDecode(patched.last), {
      'subtitleLanguages': ['en'],
    });
    expect(find.widgetWithText(InputChip, 'Russian'), findsNothing);
  });

  uiTest('Episode stills stores the selected treatment', (tester) async {
    final patched = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(
          preferences: {
            'subtitleLanguages': ['en'],
            'episodeArtwork': 'hide',
          },
          patched: patched,
        ),
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

  uiTest('Appearance stores the Violet accent and applies it', (tester) async {
    final patched = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(patched: patched)));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, null);

    await tester.tap(find.byTooltip('Violet'));
    await tester.pumpAndSettle();

    expect(jsonDecode(patched.last), {'accent': 'violet'});
    expect(
      Theme.of(tester.element(find.text('Accent colour'))).colorScheme.primary,
      Palette.accents['violet'],
    );
  });

  uiTest('Text size is this machine\'s, and scales the text', (tester) async {
    final patched = <String>[];
    final settings = temporarySettings();
    await tester.pumpWidget(
      testApp(
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
      MediaQuery.textScalerOf(tester.element(find.text('Accent colour')))
          .scale(10),
      greaterThan(10),
    );
  });

  uiTest('A preference the core refuses is shown and not applied', (
    tester,
  ) async {
    await tester.pumpWidget(testApp(api: fakeCore(preferencesFail: true)));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, null);
    await tester.tap(find.text('Blur'));
    await tester.pumpAndSettle();

    expect(find.text('What it said'), findsOneWidget);
    expect(find.text('preferences refused'), findsOneWidget);
    expect(strip<String>(tester, 'Show').selected, {'show'});
  });

  uiTest('Reset puts the preferences back, after asking', (tester) async {
    final patched = <String>[];
    final settings = temporarySettings();
    await tester.pumpWidget(
      testApp(
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
      Theme.of(tester.element(find.text('Accent colour'))).colorScheme.primary,
      Palette.accents['white'],
    );
    expect(settings.timelinePreviews, isTrue);
  });

  uiTest('the background settings reach the runner, words and all', (
    tester,
  ) async {
    final settings = temporarySettings();
    await tester.pumpWidget(testApp(settings: settings));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.general);
    Map<Object?, Object?> sent() =>
        windowCalls
                .lastWhere((c) => c.method == 'configureBackground')
                .arguments
            as Map;
    expect(sent()['enabled'], isFalse);

    await tester.tap(
      find.descendant(
        of: find.widgetWithText(SettingRow, 'Start with the system'),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(sent(), {
      'enabled': true,
      'autostart': true,
      'open': 'Open Lumeo',
      'quit': 'Quit',
      'running': 'Lumeo is running in the background',
      'runningBody':
          'Downloads go on. Open it again from the applications menu.',
    });
    expect(settings.background, isTrue);
  });

  uiTest('Sources lists the addons and what each one serves', (tester) async {
    await tester.pumpWidget(testApp());
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

  uiTest('Switching an addon off is sent to the core', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(addonCalls: calls)));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.sources);

    final switches = find.descendant(
      of: settingsSection(SettingsSection.sources),
      matching: find.byType(Switch),
    );
    await reveal(tester, switches.at(2));
    await tester.tap(switches.at(2));
    await tester.pumpAndSettle();

    expect(calls.last, 'PATCH /api/v1/addons/torrentio {"enabled":false}');
    expect(tester.widget<Switch>(switches.at(2)).value, isFalse);
  });

  uiTest('An address is checked by the core: a refusal stays at the field, an '
      'addon joins the list', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(addonCalls: calls)));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.sources);

    final field = find.widgetWithText(TextField, 'Addon address');
    await reveal(tester, field);
    await tester.enterText(field, 'http://dead.invalid');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('no addon answered there: 404 Not Found'), findsOneWidget);
    expect(find.text('Public Domain Movies'), findsNothing);

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
  });

  uiTest('Removing an addon takes it off the list', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(addonCalls: calls)));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.sources);

    final sources = settingsSection(SettingsSection.sources);
    final remove = find.descendant(of: sources, matching: find.text('Remove'));
    await reveal(tester, remove.last);
    await tester.tap(remove.last);
    await tester.pumpAndSettle();

    expect(calls.last, 'DELETE /api/v1/addons/torrentio');
    expect(find.text('Torrentio'), findsNothing);
    expect(
      find.descendant(of: sources, matching: find.byType(Switch)),
      findsNWidgets(2),
    );
  });

  uiTest('Downloads lists titles and deletes one', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.downloads);

    expect(find.text('The Expanse'), findsOneWidget);
    expect(find.text('2 episodes · downloading'), findsOneWidget);
    expect(find.text('Arrival'), findsOneWidget);
    expect(find.text('Film'), findsOneWidget);
    expect(find.text('Delete all'), findsOneWidget);

    // Escape must close the dialog without navigating the page below it.
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

  /// Opens Settings at Downloads over a core that records what it is sent.
  Future<List<String>> openDownloads(
    WidgetTester tester, {
    LocalSettings? settings,
  }) async {
    final patched = <String>[];
    await tester.pumpWidget(
      testApp(
        api: fakeCore(patched: patched),
        settings: settings,
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.downloads);
    return patched;
  }

  Finder switchOf(String row) => find.descendant(
    of: find.widgetWithText(SettingRow, row),
    matching: find.byType(Switch),
  );

  uiTest('Downloads sends the keep policy, a custom one in days', (
    tester,
  ) async {
    final patched = await openDownloads(tester);
    await tester.tap(find.text('Right away'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'keep': 'watched'});
    expect(strip<String>(tester, 'Right away').selected, {'watched'});

    await tester.tap(find.text('After 30 days'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'keep': 'days', 'keepDays': 30});

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
  });

  uiTest('Downloads sends the disk limit', (tester) async {
    final patched = await openDownloads(tester);
    await tester.tap(find.text('100 GB'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'diskLimit': 100 << 30});
    expect(strip<int>(tester, '100 GB').selected, {100 << 30});
  });

  uiTest('Downloads sends prefetch switched off', (tester) async {
    final patched = await openDownloads(tester);
    await tester.tap(switchOf('Download next episode'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'prefetch': false});
    expect(
      tester.widget<Switch>(switchOf('Download next episode')).value,
      isFalse,
    );
  });

  uiTest('About sends betas on, and the update check off hides them', (
    tester,
  ) async {
    final patched = <String>[];
    await tester.pumpWidget(testApp(api: fakeCore(patched: patched)));
    await tester.pumpAndSettle();
    await openSettingsAt(tester, SettingsSection.about);
    await reveal(tester, switchOf('Offer betas'));
    await tester.tap(switchOf('Offer betas'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'betaUpdates': true});

    await tester.tap(switchOf('Check for updates'));
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'checkUpdates': false});
    expect(find.text('Offer betas'), findsNothing);
  });

  uiTest('Downloads sends the upload limit', (tester) async {
    final patched = await openDownloads(tester);
    final upload = find.descendant(
      of: find.widgetWithText(SettingRow, 'Upload limit'),
      matching: find.text('1 MB/s'),
    );
    await reveal(tester, upload);
    await tester.tap(upload);
    await tester.pumpAndSettle();
    expect(jsonDecode(patched.last), {'uploadLimit': 1 << 20});
  });

  uiTest('How long finished downloads stay in the panel is this machine\'s', (
    tester,
  ) async {
    final settings = temporarySettings();
    final patched = await openDownloads(tester, settings: settings);
    final finished = find.descendant(
      of: settingsSection(SettingsSection.downloads),
      matching: find.text('7 days'),
    );
    await reveal(tester, finished);
    await tester.tap(finished);
    await tester.pumpAndSettle();
    expect(settings.keepFinished, '7d');
    expect(patched, isEmpty);
  });
  uiTest(
    'Downloads names the folders, and offers to open and change the videos '
    'one only on this machine',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('lumeo-downloads-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final patched = <String>[];
      await tester.pumpWidget(
        testApp(
          api: fakeCore(
            baseUrl: 'http://127.0.0.1:1',
            aboutDir: directory.path,
            patched: patched,
          ),
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

      Directory('${directory.path}/Films').createSync();
      await reveal(tester, videos);
      await tester.tap(
        find.descendant(of: videos, matching: find.text('Change')),
      );
      await waitForIo(tester, find.text('Films'));
      await tester.tap(find.text('Films'));
      await waitForIo(tester, find.text('${directory.path}/Films'));
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();
      expect(jsonDecode(patched.last), {
        'downloadDir': '${directory.path}/Films',
      });
      expect(find.text('${directory.path}/Films'), findsOneWidget);

      await tester.pumpWidget(
        testApp(
          key: UniqueKey(),
          api: fakeCore(aboutDir: directory.path),
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

  uiTest('Settings prints the commands for a broken decoder, and copies '
      'them', (tester) async {
    // RPM Fusion must be enabled before Fedora can install the missing codecs.
    // The clipboard button gives both commands because the app cannot run as
    // root.
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
