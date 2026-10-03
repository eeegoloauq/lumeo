import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

const appVersion = String.fromEnvironment(
  'LUMEO_VERSION',
  defaultValue: '0.1.0',
);

/// The AppStream file travels in both the bundle and the package metadata.
///
/// A beta has its own `<release version="X.Y.Z~beta.N" type="development">`
/// with what it changed since the beta before; the release's entry sums them
/// up when it is out. The app writes a beta as X.Y.Z-beta.N, the tag's form.
class ReleaseNotes {
  static Future<String> bundled() =>
      rootBundle.loadString('assets/dev.lumeo.lumeo.metainfo.xml');

  /// One release's items.
  static List<String> parse(String source, String version, String language) =>
      between(source, '', version, language);

  /// The items of every release after [after] up to [through], newest first:
  /// what somebody who skipped releases has not been told. Betas count only
  /// on the way to a beta: a release's own entry already sums its betas up.
  /// An [after] that is not a version (a copy from before notes were kept)
  /// gives [through] alone.
  static List<String> between(
    String source,
    String after,
    String through,
    String language,
  ) {
    final last = _version(through);
    if (last == null) return const [];
    final first = _version(after);
    return [
      for (final release in XmlDocument.parse(
        source,
      ).findAllElements('release'))
        if (_version(release.getAttribute('version') ?? '') case final v?
            when (_isBeta(last) || !_isBeta(v)) &&
                _compare(v, last) <= 0 &&
                (first == null
                    ? _compare(v, last) == 0
                    : _compare(v, first) > 0))
          ..._items(release, language),
    ];
  }

  /// Whether [seen] is a beta of [version]: its betas told the viewer what
  /// the release sums up.
  static bool toldInBetas(String seen, String version) {
    final (a, b) = (_version(seen), _version(version));
    return a != null &&
        b != null &&
        _isBeta(a) &&
        !_isBeta(b) &&
        _compare(a.sublist(0, 3), b.sublist(0, 3)) == 0;
  }

  static List<String> _items(XmlElement release, String language) {
    final items = release.findAllElements('li').toList();
    final translated = items
        .where((item) => item.getAttribute('xml:lang') == language)
        .toList();
    return [
      for (final item
          in translated.isEmpty
              ? items.where((item) => item.getAttribute('xml:lang') == null)
              : translated)
        item.innerText.replaceAll(RegExp(r'\s+'), ' ').trim(),
    ];
  }

  // A release ranks above all its betas.
  static const _release = 1 << 30;

  /// "0.1.79", "0.1.79-beta.3" or "0.1.79~beta.3" as four numbers.
  static List<int>? _version(String text) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:[-~]beta\.(\d+))?$')
        .firstMatch(text);
    if (match == null) return null;
    return [
      for (var i = 1; i <= 3; i++) int.parse(match[i]!),
      if (match[4] case final beta?) int.parse(beta) else _release,
    ];
  }

  static bool _isBeta(List<int> version) => version[3] != _release;

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }
}
