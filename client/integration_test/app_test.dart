// Runs the real libmpv suite from one entry point.

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

  // One group per area, so `tool/ui-test.sh --name '^player '` runs one. Each
  // is a CI job of its own: a new group goes into ci.yml's matrix too.
  group('playback', playbackTests);
  group('player', playerTests);
}
