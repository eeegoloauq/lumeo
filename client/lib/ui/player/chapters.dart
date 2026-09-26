import 'dart:convert';

import '../../l10n/l10n.dart';

class MpvChapter {
  const MpvChapter({required this.time, this.title = ''});

  final Duration time;
  final String title;

  /// An unparseable list leaves the chapter bar empty.
  static List<MpvChapter> parse(String json) {
    if (json.trim().isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map && entry['time'] is num)
          MpvChapter(
            time: Duration(
              milliseconds: ((entry['time'] as num) * 1000).round(),
            ),
            title: entry['title'] is String ? entry['title'] as String : '',
          ),
    ];
  }
}

String chapterLabel(
  List<MpvChapter> chapters,
  int index,
  AppLocalizations l10n,
) {
  final title = chapters[index].title;
  return title.isNotEmpty ? title : l10n.playerChapter(index + 1);
}

int? chapterAt(List<MpvChapter> chapters, Duration at) {
  final i = chapters.lastIndexWhere((c) => c.time <= at);
  return i < 0 ? null : i;
}

/// "Intro" can name a cold open; use it only without a stronger opening name.
const _openingNames = ['OP', 'Opening', 'NCOP'];
const _endingNames = ['ED', 'Ending', 'Credits', 'Preview', 'NCED'];

/// Word boundaries avoid matching titles such as "Operation Mindcrime".
final _opening = _named(_openingNames);
final _intro = _named(['Intro']);
final _ending = _named(_endingNames);

RegExp _named(List<String> names) =>
    RegExp(r'\b(?:' + names.join('|') + r')\b', caseSensitive: false);

/// Never infer an opening from time alone; a cold start must not be skipped.
int? openingChapter(List<MpvChapter> chapters) =>
    _firstNamed(chapters, _opening) ?? _firstNamed(chapters, _intro);

/// Ignore opening and first chapters; use the start of the final ending run.
/// Consecutive ending and preview chapters form one skip interval.
int? endingChapter(List<MpvChapter> chapters) {
  final opening = openingChapter(chapters);
  final floor = opening == null ? 1 : opening + 1;
  var start = -1;
  for (var i = chapters.length - 1; i >= floor; i--) {
    final title = chapters[i].title;
    if (_ending.hasMatch(title) &&
        !_opening.hasMatch(title) &&
        !_intro.hasMatch(title)) {
      start = i;
    } else if (start >= 0) {
      break;
    }
  }
  return start < 0 ? null : start;
}

int? _firstNamed(List<MpvChapter> chapters, RegExp names) {
  final i = chapters.indexWhere((c) => names.hasMatch(c.title));
  return i < 0 ? null : i;
}
