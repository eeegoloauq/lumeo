import 'models.dart';

/// What the core calls a language, against what a file calls it.
///
/// A container writes ISO 639-2 on its tracks ("jpn", "ger" or "deu",
/// depending on which of the two standards the muxer knew), a Matroska muxer
/// may add a BCP 47 tag beside it ("en-US"), and a preference is ISO 639-1
/// with an optional region ("en", "pt-BR"). mpv already joins those when it
/// picks a track — `slang=en` takes "eng" and "en-US" alike, checked against
/// the library this client is built on — so choosing is left to it. What
/// mpv does not have is a name for a code: its track list carries the tag as
/// written, and the menu printed "EN-US" where it should have said English.
/// This table is for that, and for listing the file's tracks in the order
/// of the viewer's languages. It is the core's — the same one it normalises
/// provider codes with — fetched once with the list the settings page
/// offers.
class Languages {
  Languages(this.list)
    : _byCode = {for (final l in list) l.code.toLowerCase(): l},
      _byAlias = {
        for (final l in list)
          for (final alias in l.aliases) alias.toLowerCase(): l,
      };

  static final none = Languages(const []);

  final List<NamedLanguage> list;
  final Map<String, NamedLanguage> _byCode;
  final Map<String, NamedLanguage> _byAlias;

  /// The preference code for whatever a track calls its language: "eng" and
  /// "en-US" both come back as "en". A tag nothing here knows comes back as
  /// it was, lower-cased, rather than dropped: a track we cannot name is
  /// still a track somebody may want.
  String canonical(String tag) {
    final lower = tag.trim().toLowerCase();
    if (lower.isEmpty) return '';
    final exact = _byCode[lower] ?? _byAlias[lower];
    if (exact != null) return exact.code;
    // A regional variant of a language: the base is looked up on its own,
    // and the region kept for the one case where the core names it.
    final dash = lower.indexOf('-');
    if (dash > 0) {
      final base = canonical(lower.substring(0, dash));
      final region = lower.substring(dash + 1).toUpperCase();
      final named = _byCode['$base-$region'.toLowerCase()];
      return named?.code ?? base;
    }
    return lower;
  }

  /// What to print for a tag, and "" when nothing here has a name for it —
  /// the caller shows what it has rather than an invented name.
  String name(String tag) {
    final code = canonical(tag);
    return _byCode[code.toLowerCase()]?.name ?? '';
  }

  /// Where a track's language sits in a list of preferred codes: 0 for the
  /// first, and -1 when it is not there. A regional variant satisfies a
  /// preference for its base ("pt-BR" when "pt" was asked for), the same rule
  /// the core ranks database subtitles by.
  int rank(String tag, List<String> preferred) {
    final code = canonical(tag);
    if (code.isEmpty) return -1;
    final exact = preferred.indexOf(code);
    if (exact >= 0) return exact;
    final dash = code.indexOf('-');
    return dash > 0 ? preferred.indexOf(code.substring(0, dash)) : -1;
  }
}
