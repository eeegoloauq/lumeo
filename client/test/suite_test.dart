// The layout of the tests themselves, checked where it can be
// (docs/decisions/testing.md says what goes where and why).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final files = [
    for (final dir in ['test', 'integration_test'])
      ...Directory(dir)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
  ];

  final start = RegExp(r"\b(test|testWidgets|uiTest)\(\s*'((?:[^'\\]|\\.)*)'");

  /// Every test in [file], by name, with its source up to the next one.
  Map<String, String> testsIn(File file) {
    final source = file.readAsStringSync();
    final found = start.allMatches(source).toList();
    return {
      for (var i = 0; i < found.length; i++)
        found[i].group(2)!: source.substring(
          found[i].start,
          i + 1 < found.length ? found[i + 1].start : source.length,
        ),
    };
  }

  test('no two tests share a name', () {
    // A test copied to another layer instead of moved keeps its name.
    final seen = <String, String>{};
    final twice = <String>[];
    for (final file in files) {
      for (final name in testsIn(file).keys) {
        final before = seen[name];
        if (before != null) twice.add('"$name": $before and ${file.path}');
        seen[name] = file.path;
      }
    }
    expect(twice, isEmpty);
  });

  test('the app is only built through testApp', () {
    // LumeoApp without settings of its own reads and writes the desktop
    // user's client.json.
    final direct = [
      for (final file in files)
        if (!file.path.endsWith('ui/app.dart') &&
            !file.path.endsWith('suite_test.dart') &&
            file.readAsStringSync().contains('LumeoApp('))
          file.path,
    ];
    expect(direct, isEmpty);
  });

  test('every test on Weston needs mpv', () {
    // The rest run in test/ui/ under flutter test, in a fraction of the time.
    final mpv = RegExp(
      r'mpvOnScreen|playerKeysReady|playerOpened|PlayerScreen|serveFilm|'
      r'Player\(\)',
    );
    final without = [
      for (final file in files.where((f) => f.path.startsWith('integration')))
        for (final MapEntry(key: name, value: body) in testsIn(file).entries)
          if (!mpv.hasMatch(body)) '${file.path}: $name',
    ];
    expect(without, isEmpty);
  });
}
