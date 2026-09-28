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

/// Plain text in mpv's 720-line scale: a line 1/15 of the picture high, 1/20
/// of it above the bottom edge, where a styled track of a streaming release
/// puts its dialogue too, so the two read alike. The bar covers the line while
/// it is up rather than pushing it around.
const subtitleFontSize = 48;
const subtitleMargin = 36;

/// The width of the outline for each `subtitleBackground`: a thick one alone,
/// a thin one under a drop shadow (a thick one would hide the shadow), and
/// for the box its padding, as mpv draws it.
double subtitleBorder(String background) => background == 'shadow' ? 1.5 : 4;

/// The drop shadow moves the outlined line down and right by this much,
/// opaque and unblurred; the box is this translucent black.
const subtitleShadow = 3;
const subtitleBoxColour = 0xC0000000;

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
