import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../../api/title_link.dart';
import '../../l10n/l10n.dart';
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
      style: roundButtonStyle(disabledForeground: Palette.text),
      icon: DownloadGlyph(
        fraction: fraction,
        done: done,
        size: 20,
        color: Palette.text,
      ),
    );
  }
}

/// The round icon buttons beside Play: download, My list, share.
ButtonStyle roundButtonStyle({Color disabledForeground = Palette.muted}) =>
    IconButton.styleFrom(
      fixedSize: const Size.square(DownloadButton.size),
      minimumSize: const Size.square(DownloadButton.size),
      padding: EdgeInsets.zero,
      backgroundColor: Palette.tint,
      disabledBackgroundColor: Palette.tint,
      foregroundColor: Palette.text,
      disabledForegroundColor: disabledForeground,
    );

/// Copies the link a title is shared by. The desktop has no share sheet to
/// hand it to; the person pastes it wherever they talk.
class ShareButton extends StatelessWidget {
  const ShareButton({super.key, required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const ValueKey('share-button'),
      tooltip: context.l10n.itemShare,
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: shareLink(item)));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(context.l10n.itemLinkCopied)));
      },
      style: roundButtonStyle(),
      icon: const Icon(Icons.ios_share, size: 18),
    );
  }
}
