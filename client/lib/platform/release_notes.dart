import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

const appVersion = String.fromEnvironment(
  'LUMEO_VERSION',
  defaultValue: '0.1.0',
);

/// The AppStream file travels in both the bundle and the package metadata.
class ReleaseNotes {
  static Future<String> bundled() =>
      rootBundle.loadString('assets/dev.lumeo.lumeo.metainfo.xml');

  /// One release's items.
  static List<String> parse(String source, String version, String language) =>
      between(source, '', version, language);

  /// The items of every release after [after] up to [through], newest first:
  /// what somebody who skipped releases has not been told. An [after] that is
  /// not a version (a copy from before notes were kept) gives [through] alone.
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
            when _compare(v, last) <= 0 &&
                (first == null
                    ? _compare(v, last) == 0
                    : _compare(v, first) > 0))
          ..._items(release, language),
    ];
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

  /// A beta (0.1.79-beta.1) reads as its release: its notes are that one's.
  static List<int>? _version(String text) {
    final parts = text.split('-').first.split('.').map(int.tryParse).toList();
    if (parts.length != 3 || parts.contains(null)) return null;
    return parts.cast<int>();
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }
}
