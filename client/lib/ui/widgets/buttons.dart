import 'package:flutter/material.dart';

import '../theme.dart';
import 'download_glyph.dart';

const _buttonHeight = 52.0;

/// The one action the whole product is built around. There is exactly one of
/// these on a screen, in the accent.
class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.label, required this.onPressed});

  final String label;

  /// Null when there is nothing to play.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.play_arrow, size: 22),
      label: Text(label, style: Typo.button),
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22),
        // Both buttons are pinned to one height: left to their contents, the
        // one with an icon comes out taller than the one without.
        fixedSize: const Size.fromHeight(_buttonHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Shape.control),
        ),
      ),
    );
  }
}

class QuietButton extends StatelessWidget {
  const QuietButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: Palette.text,
        side: const BorderSide(color: Palette.line),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        fixedSize: const Size.fromHeight(_buttonHeight),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Shape.control),
        ),
      ),
      child: Text(label, style: Typo.button),
    );
  }
}

/// Download as one icon, [DownloadGlyph]; what it means in words is the
/// tooltip.
class DownloadButton extends StatelessWidget {
  const DownloadButton({
    super.key,
    required this.tooltip,
    this.fraction,
    this.done = false,
    this.onPressed,
  });

  static const size = 36.0;

  final String tooltip;

  /// How far it has got while it runs; null when nothing is running.
  final double? fraction;
  final bool done;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final running = fraction != null;
    return IconButton(
      tooltip: tooltip,
      onPressed: done || running ? null : onPressed,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(size),
        minimumSize: const Size.square(size),
        padding: EdgeInsets.zero,
        backgroundColor: Palette.tint,
        disabledBackgroundColor: Palette.tint,
        foregroundColor: Palette.text,
        disabledForegroundColor: Palette.text,
      ),
      icon: DownloadGlyph(
        fraction: fraction,
        done: done,
        size: 20,
        color: Palette.text,
      ),
    );
  }
}
