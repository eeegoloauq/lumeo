// The slowest tests of a run, to catch one that waits for something real.
//
//   flutter test --reporter json | dart run tool/slow_tests.dart [count]
//
// The first test of each file also pays for compiling what it opens, so a
// few seconds there is warm-up; a later test that takes a second or more is
// waiting out a timer or real I/O.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  final count = args.isEmpty ? 15 : int.parse(args.first);
  final files = <int, String>{};
  final started = <int, ({int at, String name, int suite})>{};
  final took = <({int ms, String file, String name})>[];
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('{')) continue;
    final event = jsonDecode(line) as Map<String, dynamic>;
    switch (event['type']) {
      case 'suite':
        final suite = event['suite'] as Map<String, dynamic>;
        files[suite['id'] as int] = suite['path'] as String;
      case 'testStart':
        final test = event['test'] as Map<String, dynamic>;
        started[test['id'] as int] = (
          at: event['time'] as int,
          name: test['name'] as String,
          suite: test['suiteID'] as int,
        );
      case 'testDone' when event['hidden'] != true:
        final test = started[event['testID'] as int]!;
        took.add((
          ms: (event['time'] as int) - test.at,
          file: files[test.suite]!.split('/client/').last,
          name: test.name,
        ));
    }
  }
  took.sort((a, b) => b.ms.compareTo(a.ms));
  for (final t in took.take(count)) {
    stdout.writeln('${'${t.ms}'.padLeft(6)} ms  ${t.file}  ${t.name}');
  }
}
