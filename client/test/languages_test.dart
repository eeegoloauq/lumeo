import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/languages.dart';
import 'package:lumeo/api/models.dart';

void main() {
  final languages = Languages(const [
    NamedLanguage(code: 'en', name: 'English', aliases: ['eng']),
    NamedLanguage(code: 'de', name: 'German', aliases: ['deu', 'ger']),
    NamedLanguage(code: 'pt', name: 'Portuguese', aliases: ['por']),
    NamedLanguage(code: 'pt-BR', name: 'Portuguese (BR)', aliases: ['pob']),
    NamedLanguage(code: 'ja', name: 'Japanese', aliases: ['jpn']),
  ]);

  test('a track tag is named whatever standard the muxer wrote it in', () {
    // The screen said "EN-US" and "AR-SA" over a list of tracks, because
    // nothing in the client knew that those are English and Arabic.
    expect(languages.name('en-US'), 'English');
    expect(languages.name('eng'), 'English');
    expect(languages.name('ger'), 'German');
    expect(languages.name('deu'), 'German');
    expect(languages.name('pob'), 'Portuguese (BR)');
    expect(languages.name('pt-br'), 'Portuguese (BR)');
    expect(languages.name('und'), '');
    expect(languages.name(''), '');
  });

  test('a preference for a language matches its regional variant', () {
    // The settings page said "en" and the file said "en-US", and the
    // preference never applied.
    const preferred = ['ja', 'en'];
    expect(languages.rank('en-US', preferred), 1);
    expect(languages.rank('jpn', preferred), 0);
    expect(languages.rank('ger', preferred), -1);
    expect(languages.rank('', preferred), -1);
    // The exact variant first when it is asked for by name.
    expect(languages.rank('pob', ['pt-BR', 'pt']), 0);
    expect(languages.rank('por', ['pt-BR', 'pt']), 1);
  });

  test('an empty table keeps the codes rather than losing the tracks', () {
    expect(Languages.none.canonical('eng'), 'eng');
    expect(Languages.none.name('eng'), '');
    expect(Languages.none.rank('en', ['en']), 0);
    expect(Languages.none.rank('en-US', ['en']), 0);
  });
}
