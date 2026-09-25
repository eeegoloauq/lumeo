import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/widgets/search_box.dart';

// The panel under the search field has six lines and the catalogue answers
// with two lists, one per kind. Which six, and in what order, is the whole
// difference between "matrix" showing The Matrix and showing a 1993 series
// nobody was looking for — both of which this has done.

MediaItem film(String title, {int year = 2000}) =>
    MediaItem(id: title, kind: 'movie', title: title, year: year);

MediaItem series(String title, {int year = 2000}) =>
    MediaItem(id: title, kind: 'series', title: title, year: year);

List<String> titles(List<MediaItem> items) => [for (final i in items) i.title];

void main() {
  test('the name that is the word comes first, whichever kind it is', () {
    final ranked = rankSearchResults(
      'matrix',
      films: [film('The Matrix'), film('The Matrix Reloaded')],
      series: [series('Matrix'), series('Threat Matrix')],
      limit: 4,
    );
    expect(titles(ranked), [
      'The Matrix',
      'Matrix',
      'The Matrix Reloaded',
      'Threat Matrix',
    ]);
  });

  test('the two kinds are not taken in turns', () {
    // They were: the lists were merged by the place each provider gave a
    // title, so the panel read film, series, film, series whatever the word
    // was, and a word whose real answers were all of one kind showed half of
    // them. Here everything but one line is a film, and the line that is not
    // is the one the word actually names.
    final ranked = rankSearchResults(
      'breaking bad',
      films: [film('Breaking Bad Movie'), film('Breaking In'), film('Bad')],
      series: [series('Breaking Bad')],
    );
    expect(titles(ranked), [
      'Breaking Bad',
      'Breaking Bad Movie',
      'Breaking In',
      'Bad',
    ]);
  });

  test('the article a catalogue files a title under is not the title', () {
    // "The Matrix" is what somebody typing "matrix" means, and being filed
    // under T is no reason to rank it under everything filed under M.
    final ranked = rankSearchResults(
      'matrix',
      films: [film('The Matrix')],
      series: [series('Matrix Rising')],
    );
    expect(titles(ranked).first, 'The Matrix');
  });

  test('a title the word is buried inside goes last', () {
    // A title where the query is not the start of any word is a "contains it
    // somewhere" answer: it goes under everything the query actually names,
    // whatever the provider thinks of it. A word the query merely begins —
    // "dune" for "Dunes" — is a name, and keeps the provider's place.
    final ranked = rankSearchResults(
      'dune',
      films: [film('Verdunes'), film('Dune'), film('Children of Dunes')],
      series: const [],
      limit: 3,
    );
    expect(titles(ranked), ['Dune', 'Children of Dunes', 'Verdunes']);
  });

  test('with no limit the whole mixed list keeps that order', () {
    // The page behind "All results" ranks with the same function and no
    // ceiling. It used to concatenate the two kinds instead, which sent a
    // series that was the exact title to the bottom of the grid.
    final ranked = rankSearchResults(
      'fargo',
      films: [film('Fargo', year: 1996), film('Wild Seed'), film('Fargo Kid')],
      series: [series('Fargo', year: 2014), series('Tales of Wells Fargo')],
    );
    // Both titles that are the word, then the one that begins with it, then
    // the one that carries it as a word, and last the film the word does not
    // name at all — however highly the provider rated it.
    expect(titles(ranked), [
      'Fargo',
      'Fargo',
      'Fargo Kid',
      'Tales of Wells Fargo',
      'Wild Seed',
    ]);
    expect(ranked.first.year, 1996, reason: 'the film the provider put first');
    expect(ranked[1].kind, 'series');
  });

  test('the panel never shows more than it has room for', () {
    final ranked = rankSearchResults(
      'a',
      films: [for (var i = 0; i < 20; i++) film('A film $i')],
      series: [for (var i = 0; i < 20; i++) series('A series $i')],
      limit: 6,
    );
    expect(ranked, hasLength(6));
  });

  test('one empty list is not an empty answer', () {
    final ranked = rankSearchResults(
      'breaking bad',
      films: const [],
      series: [series('Breaking Bad')],
    );
    expect(titles(ranked), ['Breaking Bad']);
  });
}
