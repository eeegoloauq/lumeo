import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/platform/local_settings.dart';

void main() {
  late Directory temporary;
  late String path;

  setUp(() {
    temporary = Directory.systemTemp.createTempSync('lumeo-settings-');
    path = '${temporary.path}/nested/client.json';
  });

  tearDown(() {
    temporary.deleteSync(recursive: true);
  });

  test('a missing file uses full volume', () async {
    final settings = await LocalSettings.load(path: path);

    expect(settings.volume, 100);
  });

  test('volume survives a flush and reload', () async {
    final settings = await LocalSettings.load(path: path);
    settings.volume = 40;

    await settings.flush();
    final reloaded = await LocalSettings.load(path: path);

    expect(reloaded.volume, 40);
  });

  test('a corrupt file uses full volume', () async {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('{');

    final settings = await LocalSettings.load(path: path);

    expect(settings.volume, 100);
  });

  test('volume is clamped to its supported range', () async {
    final settings = await LocalSettings.load(path: path);

    settings.volume = -20;
    expect(settings.volume, 0);
    settings.volume = 140;
    expect(settings.volume, 100);
    await settings.flush();
  });

  test('finished downloads go after the keep time or a Clear', () async {
    final settings = await LocalSettings.load(path: path);
    final now = DateTime.now().toUtc();
    expect(settings.keepFinished, '1d');
    expect(
      settings.showsFinished(now.subtract(const Duration(hours: 2))),
      isTrue,
    );
    expect(
      settings.showsFinished(now.subtract(const Duration(days: 2))),
      isFalse,
    );

    settings.keepFinished = 'cleared';
    expect(
      settings.showsFinished(now.subtract(const Duration(days: 30))),
      isTrue,
    );
    settings.clearFinishedDownloads();
    expect(
      settings.showsFinished(now.subtract(const Duration(seconds: 1))),
      isFalse,
    );

    await settings.flush();
    final reloaded = await LocalSettings.load(path: path);
    expect(reloaded.keepFinished, 'cleared');
    expect(reloaded.downloadsClearedAt, isNotNull);
  });

  test(
    'the order of My list survives a reload, and nonsense is refused',
    () async {
      final settings = await LocalSettings.load(path: path);
      expect(settings.listSort, 'added');
      settings.listSort = 'shuffled';
      expect(settings.listSort, 'added');
      settings.listSort = 'rating';

      await settings.flush();
      final reloaded = await LocalSettings.load(path: path);
      expect(reloaded.listSort, 'rating');
    },
  );

  test('a file from before release notes counts as an update', () async {
    await File(path).create(recursive: true);
    await File(path).writeAsString('{"volume": 40}');
    expect((await LocalSettings.load(path: path)).lastSeenVersion, '');
    await File(path).delete();
    expect((await LocalSettings.load(path: path)).lastSeenVersion, isNull);
  });

  test(
    'the settings page\'s own choices survive a reload, and reset',
    () async {
      final settings = await LocalSettings.load(path: path);
      expect(settings.textScale, 'default');
      expect(settings.textScaleFactor, 1);
      expect(settings.timelinePreviews, isTrue);
      expect(settings.screenshotsDir, isEmpty);

      settings.textScale = 'huge';
      expect(settings.textScale, 'default', reason: 'nonsense is refused');
      settings
        ..textScale = 'large'
        ..timelinePreviews = false
        ..screenshotsDir = '/home/me/Frames'
        ..keepFinished = '7d'
        ..lastSeenVersion = '0.1.66'
        ..dismissedUpdate = '0.1.70'
        ..volume = 40;

      await settings.flush();
      final reloaded = await LocalSettings.load(path: path);
      expect(reloaded.textScale, 'large');
      expect(reloaded.textScaleFactor, greaterThan(1));
      expect(reloaded.timelinePreviews, isFalse);
      expect(reloaded.screenshotsDir, '/home/me/Frames');
      expect(reloaded.lastSeenVersion, '0.1.66');
      expect(reloaded.dismissedUpdate, '0.1.70');

      reloaded.resetChoices();
      expect(reloaded.textScale, 'default');
      expect(reloaded.timelinePreviews, isTrue);
      expect(reloaded.screenshotsDir, isEmpty);
      expect(reloaded.keepFinished, '1d');
      expect(reloaded.volume, 40, reason: 'volume is not a choice on the page');
      expect(reloaded.lastSeenVersion, '0.1.66');
      await reloaded.flush();
    },
  );

  test(
    'the language is one that ships, and reset follows the desktop',
    () async {
      final settings = await LocalSettings.load(path: path);
      expect(
        settings.language,
        isEmpty,
        reason: 'none chosen follows the desktop',
      );
      settings.language = 'xx';
      expect(settings.language, isEmpty, reason: 'no translation, no choice');
      settings.language = 'ru';

      await settings.flush();
      final reloaded = await LocalSettings.load(path: path);
      expect(reloaded.language, 'ru');

      reloaded.resetChoices();
      expect(reloaded.language, isEmpty);
      await reloaded.flush();
    },
  );
}
