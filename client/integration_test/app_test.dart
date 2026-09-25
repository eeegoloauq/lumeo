// The interface, driven the way a person drives it.
//
// Every check in this directory is a defect that actually shipped. They are
// written against the real widget tree on a real screen rather than against
// unit-testable helpers, because none of these were reachable from a unit
// test: a wordmark printed twice in the same place, a panel clipped by the bar
// it hung from, a shortcut nothing could reach, a keystroke stolen from a text
// field, and a text style that only misbehaves outside a Material.
//
// The checks live in one file per area, all started from this one: every
// entry file in integration_test/ is a build and a launch of its own.
//
// Run: client/tool/ui-test.sh

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:lumeo/platform/window.dart';

import 'downloads.dart';
import 'helpers.dart';
import 'library.dart';
import 'playback.dart';
import 'player.dart';
import 'search.dart';
import 'settings.dart';
import 'shell.dart';
import 'title.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The player is part of the tree these tests walk into, and it wants libmpv
  // set up before anything asks for a Player.
  MediaKit.ensureInitialized();

  setUp(() {
    windowCalls.clear();
    // The window is one object for the whole process, so a test that put it
    // into fullscreen would hand that on to the next one.
    AppWindow.instance.setFullscreen(false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('dev.lumeo/window'), (
          call,
        ) async {
          windowCalls.add(call);
          return call.method == 'state'
              ? <String, Object?>{'maximized': false, 'fullscreen': false}
              : null;
        });
  });

  tearDownAll(deleteTestFilms);

  shellTests();
  searchTests();
  downloadsTests();
  settingsTests();
  libraryTests();
  titleTests();
  playbackTests();
  playerTests();
}
