import 'models.dart';

/// A title as a link names it. Item ids are minted by each core; the IMDb id
/// is the same on every machine.
typedef TitleRef = ({String kind, String imdb});

/// Where shared links point: a page anyone can open, whose Open button hands
/// `lumeo://title/<kind>/<imdb>` to an installed Lumeo (`site/` in the repo).
const sharePage = 'https://eeegoloauq.github.io/lumeo';

final _imdb = RegExp(r'^tt[0-9]+$');

/// Whether [target] is a `lumeo:` link at all, valid or not. A link is never
/// taken for a file, whatever is in it.
bool isLink(String target) => Uri.tryParse(target)?.scheme == 'lumeo';

/// The title in a `lumeo://title/movie/tt0063350` link, or null for anything
/// else, a file path included.
TitleRef? titleOfLink(String link) {
  final uri = Uri.tryParse(link);
  if (uri == null || uri.scheme != 'lumeo' || uri.host != 'title') {
    return null;
  }
  // A browser may hand the link over with a slash added at the end.
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments case [final kind, final imdb]
      when (kind == 'movie' || kind == 'series') && _imdb.hasMatch(imdb)) {
    return (kind: kind, imdb: imdb);
  }
  return null;
}

/// The link to share a title by: the share page with the IMDb id, then the
/// title and year as words, which the page shows when it cannot reach the
/// catalogue and which say what the link is to whoever reads it.
String shareLink(MediaItem item) {
  final words = [
    ...item.title.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)),
    if (item.year > 0) '${item.year}',
  ].where((w) => w.isNotEmpty);
  final slug = Uri.encodeComponent([item.imdb, ...words].join('-'));
  return '$sharePage/${item.kind}/?$slug';
}
