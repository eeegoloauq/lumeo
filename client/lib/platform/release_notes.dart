import 'package:flutter/services.dart';
import 'package:xml/xml.dart';

const appVersion = String.fromEnvironment(
  'LUMEO_VERSION',
  defaultValue: '0.1.0',
);

/// The AppStream file travels in both the bundle and the package metadata.
class ReleaseNotes {
  static Future<List<String>> load(String version, String language) async =>
      parse(
        await rootBundle.loadString('assets/dev.lumeo.lumeo.metainfo.xml'),
        version,
        language,
      );

  static List<String> parse(String source, String version, String language) {
    final document = XmlDocument.parse(source);
    for (final release in document.findAllElements('release')) {
      if (release.getAttribute('version') != version) continue;
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
    return const [];
  }
}
