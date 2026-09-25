import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/platform/folders.dart';
import 'package:lumeo/ui/player/screenshots.dart';

void main() {
  test(
    'a frame lands in the desktop\'s pictures folder, named after the film',
    () {
      // The defect this is written against: with neither property set, mpv puts
      // the frame in the working directory of the process, and an application
      // started from the desktop menu does not own that directory. Pressing `s`
      // answered "Error writing screenshot!" and there was nothing to look at.
      final props = screenshotProperties(
        title: 'Andor',
        pictures: '/home/me/Pictures',
      );
      expect(props['screenshot-dir'], '/home/me/Pictures/Lumeo');
      expect(props['screenshot-template'], 'Andor %P %#01n');
    },
  );

  test('a folder chosen in Settings wins over Pictures', () {
    expect(
      screenshotProperties(
        title: 'Andor',
        pictures: '/home/me/Pictures',
        chosen: '/home/me/Frames',
      )['screenshot-dir'],
      '/home/me/Frames',
    );
    expect(screenshotsFolder(pictures: ''), isEmpty);
  });

  test('a second press on the same frame has a name of its own', () {
    // mpv does not overwrite and does not invent a name unless the template
    // contains %n: on a paused film %P is the same string twice, so the
    // second press used to fail with "file already exists" — the same class
    // of refusal the rest of this was written to stop.
    expect(
      screenshotProperties(
        title: 'Andor',
        pictures: '/pics',
      )['screenshot-template'],
      contains('%#01n'),
    );
  });

  test('a title is written where a template and a path can both read it', () {
    expect(
      screenshotProperties(
        title: 'Face/Off',
        pictures: '/pics',
      )['screenshot-template'],
      startsWith('Face-Off '),
      reason: 'a slash would name a folder that does not exist',
    );
    expect(
      screenshotProperties(
        title: '50% of a Yellow Sun',
        pictures: '/pics',
      )['screenshot-template'],
      startsWith('50%% of a Yellow Sun '),
      reason: "%% is how mpv's template language writes a literal per cent",
    );
    expect(
      screenshotProperties(
        title: '  ',
        pictures: '/pics',
      )['screenshot-template'],
      startsWith('Lumeo '),
    );
  });

  test('no pictures folder leaves mpv the directory it already has', () {
    // Not a good outcome — an empty screenshot-dir is mpv's "the working
    // directory", which is the original defect and may well be unwritable —
    // but there is nothing truer to say from here, and setting the property
    // to an empty string would not say anything else.
    expect(
      screenshotProperties(title: 'Andor', pictures: ''),
      isNot(contains('screenshot-dir')),
    );
  });

  group('which folder the desktop means by Pictures', () {
    Future<ProcessResult> answering(String stdout) async =>
        ProcessResult(0, 0, stdout, '');

    test('whatever the account calls it', () async {
      expect(
        await picturesFolder(
          environment: {'HOME': '/home/me'},
          run: (_, _) => answering('/home/me/Bilder\n'),
        ),
        '/home/me/Bilder',
      );
    });

    test('the home directory is not an answer', () async {
      // xdg-user-dir falls back to the home directory when no Pictures folder
      // is configured, and frames do not go in the home directory.
      expect(
        await picturesFolder(
          environment: {'HOME': '/home/me'},
          run: (_, _) => answering('/home/me'),
        ),
        '/home/me/Pictures',
      );
    });

    test('a HOME with a trailing slash is the same home', () async {
      expect(
        await picturesFolder(
          environment: {'HOME': '/home/me/'},
          run: (_, _) => answering('/home/me'),
        ),
        '/home/me/Pictures',
      );
    });

    test(
      'without xdg-user-dirs the conventional path is still conventional',
      () async {
        expect(
          await picturesFolder(
            environment: {'HOME': '/home/me'},
            run: (_, _) =>
                Future.error(const ProcessException('xdg-user-dir', [])),
          ),
          '/home/me/Pictures',
        );
      },
    );

    test('nothing to answer with', () async {
      expect(
        await picturesFolder(
          environment: const {},
          run: (_, _) =>
              Future.error(const ProcessException('xdg-user-dir', [])),
        ),
        isEmpty,
      );
    });

    test('a command that never answers is given up on', () async {
      // The one that matters for the film: this used to be awaited between a
      // download being ready and mpv being handed it.
      expect(
        await picturesFolder(
          environment: {'HOME': '/home/me'},
          run: (_, _) => Completer<ProcessResult>().future,
        ),
        '/home/me/Pictures',
      );
    });
  });
}
