import 'dart:convert';

import '../../api/models.dart';

/// mpv exposes selected, external, and forced tracks that media_kit omits.
class MpvTrack {
  const MpvTrack({
    required this.id,
    required this.type,
    this.title = '',
    this.language = '',
    this.codec = '',
    this.channels = 0,
    this.selected = false,
    this.isDefault = false,
    this.forced = false,
    this.external = false,
    this.externalFilename = '',
  });

  final String id;

  final String type;
  final String title;
  final String language;
  final String codec;

  final int channels;
  final bool selected;
  final bool isDefault;
  final bool forced;
  final bool external;

  /// The external track URL identifies a selected database subtitle.
  final String externalFilename;

  /// An unparseable list leaves the track menu empty.
  static List<MpvTrack> parse(String json) {
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
        if (entry is Map && entry['id'] != null && entry['type'] is String)
          MpvTrack(
            id: '${entry['id']}',
            type: entry['type'] as String,
            title: _string(entry['title']),
            language: _string(entry['lang']),
            codec: _string(entry['codec']),
            channels: entry['demux-channel-count'] is int
                ? entry['demux-channel-count'] as int
                : 0,
            selected: entry['selected'] == true,
            isDefault: entry['default'] == true,
            forced: entry['forced'] == true,
            external: entry['external'] == true,
            externalFilename: _string(entry['external-filename']),
          ),
    ];
  }

  static String _string(Object? value) => value is String ? value : '';
}

/// Match changes by value: mpv reports properties out of order and may
/// coalesce changes made by this screen.
class TrackChanges {
  final _last = <String, String>{};
  final _mpvChoosing = <String>{};
  final _own = <String, String>{};

  void own(String property, String value) => _own[property] = value;

  bool byViewer(String property, String value) {
    if (value == 'auto') {
      _mpvChoosing.add(property);
      return false;
    }
    final previous = _last[property];
    _last[property] = value;
    if (_mpvChoosing.remove(property)) return false;
    return _own.remove(property) != value && value != previous;
  }
}

/// Match title as well as language when a file has several tracks in one language.
MpvTrack? trackToSelect(
  List<MpvTrack> tracks,
  String type,
  TrackChoice? picked,
) {
  if (picked == null || picked.off || picked.title.isEmpty) return null;
  final track = tracks
      .where(
        (t) =>
            t.type == type &&
            !t.external &&
            t.language == picked.language &&
            t.title == picked.title,
      )
      .firstOrNull;
  return track == null || track.selected ? null : track;
}

/// Return null until the track list catches up with the selected id.
TrackChoice? trackToRemember(List<MpvTrack> tracks, String type, String id) {
  if (type == 'sub' && id == 'no') return const TrackChoice(off: true);
  final track = tracks.where((t) => t.type == type && t.id == id).firstOrNull;
  return track == null
      ? null
      : TrackChoice(language: track.language, title: track.title);
}
