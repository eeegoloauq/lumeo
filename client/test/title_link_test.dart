import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/api/title_link.dart';

void main() {
  test('a title link names the kind and the IMDb id', () {
    expect(titleOfLink('lumeo://title/movie/tt0063350'), (
      kind: 'movie',
      imdb: 'tt0063350',
    ));
    expect(titleOfLink('lumeo://title/movie/tt0063350/'), (
      kind: 'movie',
      imdb: 'tt0063350',
    ), reason: 'a browser may add the slash');
    expect(titleOfLink('lumeo://title/series/tt0052520'), (
      kind: 'series',
      imdb: 'tt0052520',
    ));
  });

  test('anything else is not a title link', () {
    for (final other in [
      '/home/me/Videos/film.mkv',
      'file:///home/me/Videos/film.mkv',
      'lumeo://title/channel/tt0063350',
      'lumeo://title/movie/0063350',
      'lumeo://title/movie/tt0063350/extra',
      'lumeo://other/movie/tt0063350',
      'https://eeegoloauq.github.io/lumeo/movie/?tt0063350',
    ]) {
      expect(titleOfLink(other), isNull, reason: other);
    }
  });

  test('a shared link carries the id first and the title in words', () {
    const film = MediaItem(
      id: 'abc',
      kind: 'movie',
      title: 'Night of the Living Dead',
      year: 1968,
      imdb: 'tt0063350',
    );
    expect(
      shareLink(film),
      '$sharePage/movie/?tt0063350-Night-of-the-Living-Dead-1968',
    );
    const series = MediaItem(
      id: 'def',
      kind: 'series',
      title: 'The Twilight Zone: 1959',
      imdb: 'tt0052520',
    );
    expect(
      shareLink(series),
      '$sharePage/series/?tt0052520-The-Twilight-Zone-1959',
    );
  });
}
