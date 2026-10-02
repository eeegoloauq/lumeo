import 'package:flutter/material.dart';

/// The whole visual language in one place.
///
/// The ground is black, so posters ring against nothing. Under black a
/// shadow has nothing to darken, so lightness is the only way one thing sits
/// above another: the surfaces below are a ladder with real distance between
/// the rungs, each a little bluer than red so a raised surface stays cool.
///
/// Exactly one accent, the viewer's choice from [accents] and white unless
/// chosen, spent on what to press and how far along something is. Widgets
/// read it as the theme's `primary`. Every other colour belongs to the
/// artwork.
class Palette {
  /// The four rungs. Nothing else is a background.
  static const page = Color(0xFF000000);

  /// A row under the pointer, a field waiting to be typed in.
  static const surface = Color(0xFF0E0F12);

  /// The chosen row, a pill, a button that is not the accent.
  static const raised = Color(0xFF17181C);

  /// Above the page rather than in it: the search panel, the player's menus.
  static const floating = Color(0xFF1E1F24);

  /// A visible edge, for the two things still allowed one: a ghost button,
  /// and the outline of a control that has to say "you can type here".
  static const line = Color(0xFF26272E);

  /// Between rows of one list. White, so it reads the same on any rung, at
  /// half the weight of [line].
  static const divider = Color(0x14FFFFFF);

  /// The pointer is here. Also white, for the same reason.
  static const hover = Color(0x0DFFFFFF);

  /// A surface on artwork rather than the page, such as the tab pill over a
  /// hero frame: a tint of what is behind it, where a solid fill is a hole.
  static const tint = Color(0x24FFFFFF);

  /// The edge of a floating surface catching the light: white at seven per
  /// cent, so it reads as the surface being lit, not as a line drawn round it.
  /// All four sides, because a one-sided border cannot have a radius.
  static const rim = Color(0x12FFFFFF);

  static const text = Color(0xFFF3F5F9);
  static const dim = Color(0xFFC3CAD8);

  /// The quiet one: on black, a darker grey reads as extinguished.
  static const muted = Color(0xFF8B8F9C);

  /// The accents the core's `accent` preference names, in the order the
  /// settings offer them. Dark text reads on all six.
  static const accents = {
    'white': text,
    'amber': Color(0xFFF2B441),
    'red': Color(0xFFE5484D),
    'violet': Color(0xFF9B7BFF),
    'blue': Color(0xFF4C8DFF),
    'teal': Color(0xFF2FB7A6),
  };

  /// Up and down, for the one place a state is a state and not a sentence:
  /// the dot beside the core's address. Not accents; pulled back from neon so
  /// they do not outshine the artwork.
  static const up = Color(0xFF46B978);
  static const down = Color(0xFFE0554C);

  /// Something that will not work here, as opposed to something to press.
  static const warn = Color(0xFFE0755B);

  /// The ground with an alpha, for darkening a frame we do not control.
  static Color ground(double opacity) => page.withValues(alpha: opacity);
}

/// Two radii, and the one exception: something in the page, and something
/// floating over it. No other number at a call site.
class Shape {
  /// Buttons, rows, chips, anything pressed or lying on the page.
  static const control = 6.0;

  /// Panels that appear above the page: search answers, menus, dialogs.
  /// Larger, because on black a rounded edge says "on top of".
  static const floating = 14.0;

  /// Artwork keeps its own, almost square: a poster is a printed object and
  /// its corners are not ours to round.
  static const art = 2.0;

  static const controlRadius = Radius.circular(control);
  static const floatingRadius = Radius.circular(floating);
}

/// The persistent marks that say how far watching has gone.
class WatchStatus {
  static const barHeight = 3.0;

  /// White, as the player's timeline is, whatever the accent.
  static const bar = Palette.text;
  static const track = Color(0x4DF3F5F9);
  static const badgeInset = 8.0;
  static const badgePadding = 4.0;
  static const badgeIconSize = 14.0;
}

/// Plex Sans speaks, titles and figures included: its digits are all one
/// width, so a changing number does not jitter. Plex Mono is only for strings
/// a person might copy into a terminal: paths, addresses, commands, codecs.
class Typo {
  static const wordmark = 'Unbounded';
  static const sans = 'IBMPlexSans';
  static const mono = 'IBMPlexMono';

  /// Over artwork: the shadow keeps text legible on a frame we do not
  /// control.
  static const _overArt = [
    Shadow(color: Color(0xCC000000), blurRadius: 18, offset: Offset(0, 2)),
  ];

  static const heroTitle = TextStyle(
    fontFamily: sans,
    fontSize: 52,
    height: 1.05,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.2,
    color: Colors.white,
    shadows: _overArt,
  );

  // Metadata sits on a frame whose contrast changes under it, so it gets more
  // size than the hierarchy strictly needs.
  static const heroMeta = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    height: 1.3,
    letterSpacing: 0.1,
    fontWeight: FontWeight.w500,
    color: Palette.dim,
    shadows: _overArt,
  );

  static const heroBody = TextStyle(
    fontFamily: sans,
    fontSize: 16,
    height: 1.45,
    color: Palette.text,
    shadows: _overArt,
  );

  static const cardTitle = TextStyle(
    fontFamily: sans,
    fontSize: 14,
    height: 1.25,
    fontWeight: FontWeight.w600,
    color: Palette.text,
  );

  /// Shelf labels sit above the artwork and should not compete with it.
  static const shelfLabel = TextStyle(
    fontFamily: sans,
    fontSize: 18,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: Palette.text,
  );

  static const data = TextStyle(
    fontFamily: sans,
    fontSize: 13,
    height: 1.3,
    color: Palette.muted,
  );

  static const dataStrong = TextStyle(
    fontFamily: sans,
    fontSize: 13,
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: Palette.text,
  );

  static const code = TextStyle(
    fontFamily: mono,
    fontSize: 12,
    height: 1.3,
    color: Palette.muted,
  );

  static const body = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    height: 1.5,
    color: Palette.muted,
  );

  static const button = TextStyle(
    fontFamily: sans,
    fontSize: 15,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
  );
}

/// How long things take, and the shape of the movement, defined once so two
/// panels never open at different speeds.
class Motion {
  /// A panel arriving or leaving, such as the search answers unrolling:
  /// Material's token for a movement of this size.
  static const panel = Durations.medium1;

  /// The bar's ground fading in as the page moves under it.
  static const wash = Duration(milliseconds: 180);

  /// Quick to leave, slow to arrive: Material's emphasized deceleration.
  static const ease = Easing.emphasizedDecelerate;
}

const _clickable = ButtonStyle(mouseCursor: WidgetStateMouseCursor.clickable);

ThemeData lumeoTheme([String accent = 'white']) {
  final lamp = Palette.accents[accent] ?? Palette.text;
  // Material's components pick their backgrounds from these roles, so they
  // land on the right rung without being told.
  final scheme = ColorScheme.dark(
    surface: Palette.page,
    surfaceContainerLowest: Palette.page,
    surfaceContainerLow: Palette.surface,
    surfaceContainer: Palette.raised,
    surfaceContainerHigh: Palette.floating,
    surfaceContainerHighest: Palette.floating,
    primary: lamp,
    onPrimary: Palette.page,
    secondary: lamp,
    onSurface: Palette.text,
    outline: Palette.line,
    outlineVariant: Palette.divider,
    shadow: Palette.page,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Palette.page,
    fontFamily: Typo.sans,
    splashFactory: NoSplash.splashFactory,
    // Material gives desktop buttons the plain arrow. Here posters, the
    // wordmark and the shelf arrows take a pointer, so every button does too.
    filledButtonTheme: const FilledButtonThemeData(style: _clickable),
    outlinedButtonTheme: const OutlinedButtonThemeData(style: _clickable),
    textButtonTheme: const TextButtonThemeData(style: _clickable),
    iconButtonTheme: const IconButtonThemeData(style: _clickable),
    // Not the accent: on the settings page amber means what is playing.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Palette.text
            : Palette.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Palette.dim
            : Palette.raised,
      ),
      trackOutlineColor: const WidgetStatePropertyAll(Palette.line),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        maximumSize: const WidgetStatePropertyAll(Size(double.infinity, 36)),
        visualDensity: VisualDensity.compact,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Palette.raised
              : Palette.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Palette.text
              : Palette.dim,
        ),
        side: const WidgetStatePropertyAll(BorderSide(color: Palette.line)),
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Shape.controlRadius),
          ),
        ),
      ),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        isCollapsed: true,
        filled: true,
        fillColor: Palette.surface,
        contentPadding: EdgeInsets.symmetric(horizontal: 12),
        constraints: BoxConstraints(maxHeight: 36),
        suffixIconConstraints: BoxConstraints(maxWidth: 36, maxHeight: 36),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Shape.controlRadius),
          borderSide: BorderSide(color: Palette.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Shape.controlRadius),
          borderSide: BorderSide(color: Palette.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Shape.controlRadius),
          borderSide: BorderSide(color: Palette.dim),
        ),
      ),
      textStyle: Typo.dataStrong,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: lamp.withValues(alpha: 0.2),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: const WidgetStatePropertyAll(Palette.line),
      // Thin at rest, wide under the pointer: a 6 px thumb is easy to miss,
      // and a press beside it pages the list instead of grabbing it.
      thickness: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.dragged)
            ? 10
            : 6,
      ),
      radius: const Radius.circular(5),
    ),
  );
}
