import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/platform/release_notes.dart';

void main() {
  test('release notes use the interface language or untagged items', () {
    const source = '''<component><releases>
      <release version="1.2.3"><description><ul>
        <li>Default  item</li><li xml:lang="ru">Русский пункт</li>
        <li xml:lang="ru">Ещё один</li>
      </ul></description></release>
      <release version="1.2.4"><description><ul><li>Next release</li></ul></description></release>
    </releases></component>''';
    expect(ReleaseNotes.parse(source, '1.2.3', 'ru'), [
      'Русский пункт',
      'Ещё один',
    ]);
    expect(ReleaseNotes.parse(source, '1.2.3', 'en'), ['Default item']);
    expect(ReleaseNotes.parse(source, '1.2.4', 'ru'), ['Next release']);
    expect(ReleaseNotes.parse(source, '1.2.5', 'en'), isEmpty);
  });

  test('skipped releases are told together, the newest first', () {
    const source = '''<component><releases>
      <release version="0.2.1"><description><ul><li>Newest</li></ul></description></release>
      <release version="0.2.0"><description><ul><li>Middle</li></ul></description></release>
      <release version="0.1.9"><description><ul><li>Seen</li></ul></description></release>
    </releases></component>''';
    expect(ReleaseNotes.between(source, '0.1.9', '0.2.1', 'en'), [
      'Newest',
      'Middle',
    ]);
    expect(ReleaseNotes.between(source, '0.1.9', '0.2.0', 'en'), ['Middle']);
    // Updated from a copy that kept no version: only this release is news.
    expect(ReleaseNotes.between(source, '', '0.2.1', 'en'), ['Newest']);
  });

  test('a beta reads as its release', () {
    const source = '''<component><releases>
      <release version="0.2.0"><description><ul><li>Coming</li></ul></description></release>
      <release version="0.1.9"><description><ul><li>Out</li></ul></description></release>
    </releases></component>''';
    expect(ReleaseNotes.parse(source, '0.2.0-beta.1', 'en'), ['Coming']);
    expect(
      ReleaseNotes.between(source, '0.2.0-beta.1', '0.2.0', 'en'),
      isEmpty,
    );
  });
}
