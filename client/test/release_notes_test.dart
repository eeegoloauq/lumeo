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
}
