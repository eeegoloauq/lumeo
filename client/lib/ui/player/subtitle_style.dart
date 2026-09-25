import 'dart:ui' show Color;

/// The colours the `subtitleColor` preference names, in the order the
/// settings offer them: white, a broadcast yellow, a softer cream for long
/// sittings, and a cyan that stays apart from warm pictures.
const subtitleColours = <String, Color>{
  'white': Color(0xFFFFFFFF),
  'yellow': Color(0xFFFFE14D),
  'cream': Color(0xFFF5E6C4),
  'cyan': Color(0xFF7FE0FF),
};

/// The mpv properties behind the subtitle colour and whether a styled track
/// keeps its own look.
///
/// mpv's `sub-color` and the rest of our style reach plain text only while
/// `sub-ass-override` is `scale`, its default: an ASS track draws its signs
/// and karaoke in its own colours. `force` makes ours win over the file's.
Map<String, String> subtitleStyleProperties({
  required String colour,
  required bool keepStyling,
}) {
  final argb = (subtitleColours[colour] ?? subtitleColours['white']!)
      .toARGB32();
  final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
  return {
    'sub-color': '#${rgb.toUpperCase()}',
    'sub-ass-override': keepStyling ? 'scale' : 'force',
  };
}
