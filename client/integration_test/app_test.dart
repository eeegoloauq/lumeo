// The player, driven the way a person drives it, on a real libmpv.
//
// Only what needs mpv is here; the rest of the app is tested under flutter
// test in test/ui/ (docs/decisions/testing.md). The checks live in one file
// per area, all started from this one: every entry file in integration_test/
// is a build and a launch of its own.
//
// Run: client/tool/ui-test.sh

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'helpers.dart';
import 'playback.dart';
import 'player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The player is part of the tree these tests walk into, and it wants libmpv
  // set up before anything asks for a Player.
  MediaKit.ensureInitialized();

  setUp(fakeWindow);
  tearDownAll(deleteTestFilms);

  // One group per area, so `tool/ui-test.sh --name '^player '` runs one. Each is
  // a CI job of its own: a new group goes into ci.yml's matrix too.
  group('playback', playbackTests);
  group('player', playerTests);
}
