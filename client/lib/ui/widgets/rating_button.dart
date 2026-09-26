import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';
import '../theme.dart';
import 'buttons.dart';

/// The viewer's own score of something, 1 to 10, and the way to give one.
///
/// Ten numbers in a row rather than five stars: the scale is the one IMDb and
/// Trakt keep, so a score given here means the same thing there, and a row of
/// numbers says which one is being pressed where half a star has to be aimed
/// at. The row fills up to the number under the pointer or the keyboard, the
/// way a row of stars does, so the choice is seen before it is made.
class RatingButton extends StatefulWidget {
  const RatingButton({
    super.key,
    required this.score,
    required this.onRate,
    required this.onClear,
    this.label,
  });

  /// 0 when nothing was scored.
  final int score;
  final ValueChanged<int> onRate;
  final VoidCallback onClear;

  /// What the button says before anything is scored; the star alone when
  /// null, where the row it sits in already says what it is about.
  final String? label;

  /// The height of the button, the same as the other round buttons beside
  /// Play.
  static const size = DownloadButton.size;

  @override
  State<RatingButton> createState() => _RatingButtonState();
}

class _RatingButtonState extends State<RatingButton> {
  final _menu = MenuController();

  void _pick(int score) {
    _menu.close();
    if (score != widget.score) widget.onRate(score);
  }

  void _clear() {
    _menu.close();
    widget.onClear();
  }

  @override
  Widget build(BuildContext context) {
    final rated = widget.score > 0;
    return MenuAnchor(
      controller: _menu,
      consumeOutsideTap: true,
      alignmentOffset: const Offset(0, 8),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(
          Palette.floating.withValues(alpha: 0.97),
        ),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        side: const WidgetStatePropertyAll(BorderSide(color: Palette.rim)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Shape.floating),
          ),
        ),
      ),
      menuChildren: [
        _Scale(score: widget.score, onPick: _pick, onClear: _clear),
      ],
      builder: (context, menu, _) {
        void toggle() => menu.isOpen ? menu.close() : menu.open();
        final style = TextButton.styleFrom(
          backgroundColor: Palette.tint,
          foregroundColor: Palette.text,
          overlayColor: Palette.hover,
          minimumSize: const Size.square(RatingButton.size),
          fixedSize: !rated && widget.label == null
              ? const Size.square(RatingButton.size)
              : const Size.fromHeight(RatingButton.size),
          padding: EdgeInsets.symmetric(
            horizontal: rated || widget.label != null ? 12 : 0,
          ),
          shape: const StadiumBorder(),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: Typo.cardTitle.copyWith(fontSize: 13),
        );
        return Tooltip(
          message: rated
              ? context.l10n.libraryRatingChange
              : context.l10n.libraryRate,
          child: TextButton(
            key: const ValueKey('rating-button'),
            onPressed: toggle,
            style: style,
            child: rated
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.star, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        NumberFormat.decimalPattern(context.l10n.localeName)
                            .format(widget.score),
                      ),
                    ],
                  )
                : widget.label == null
                ? Icon(
                    Icons.star_border,
                    size: 20,
                    semanticLabel: context.l10n.libraryRate,
                  )
                : Text(widget.label!),
          ),
        );
      },
    );
  }
}

class _StepIntent extends Intent {
  const _StepIntent(this.by);
  final int by;
}

/// The row of ten, and the way to take a score back.
class _Scale extends StatefulWidget {
  const _Scale({
    required this.score,
    required this.onPick,
    required this.onClear,
  });

  final int score;
  final ValueChanged<int> onPick;
  final VoidCallback onClear;

  @override
  State<_Scale> createState() => _ScaleState();
}

class _ScaleState extends State<_Scale> {
  late final _nodes = [
    for (var i = 1; i <= 10; i++) FocusNode(debugLabel: 'score $i'),
  ];

  /// The number under the pointer or the keyboard, which the row fills to.
  int _lit = 0;

  @override
  void initState() {
    super.initState();
    // The keyboard opens on the score there is, or on the middle of the
    // scale, so the arrows have somewhere to start from.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nodes[(widget.score > 0 ? widget.score : 5) - 1].requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// Left and right walk the row, and the row fills to where they are. The
  /// menu's own arrows are for a column of items and would close it on Left,
  /// so the row answers them first.
  void _step(int by) {
    final at = _nodes.indexWhere((n) => n.hasFocus);
    final next = ((at < 0 ? 4 : at) + by).clamp(0, 9);
    _nodes[next].requestFocus();
    setState(() => _lit = next + 1);
  }

  @override
  Widget build(BuildContext context) {
    final filled = _lit > 0 ? _lit : widget.score;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(context.l10n.libraryYourRating, style: Typo.cardTitle),
              const SizedBox(width: 12),
              Text(
                filled > 0 ? context.l10n.libraryRatingOfTen(filled) : '',
                style: Typo.dataStrong.copyWith(color: Palette.muted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
              SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
            },
            child: Actions(
              actions: {
                _StepIntent: CallbackAction<_StepIntent>(
                  onInvoke: (intent) {
                    _step(intent.by);
                    return null;
                  },
                ),
              },
              child: MouseRegion(
                onExit: (_) => setState(() => _lit = 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var n = 1; n <= 10; n++) ...[
                      if (n > 1) const SizedBox(width: 4),
                      _Score(
                        value: n,
                        filled: n <= filled,
                        focusNode: _nodes[n - 1],
                        // Entering a number lights the row to it; only
                        // leaving the row, not the gap between two numbers,
                        // puts it back. Focus alone does not: the keyboard
                        // starts on a number when the row opens, and a row
                        // lit before anything was chosen reads as a score.
                        onHover: (on) {
                          if (on) setState(() => _lit = n);
                        },
                        onPressed: () => widget.onPick(n),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (widget.score > 0) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: widget.onClear,
              style: TextButton.styleFrom(
                foregroundColor: Palette.dim,
                overlayColor: Palette.hover,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Shape.controlRadius),
                ),
                textStyle: Typo.cardTitle.copyWith(fontSize: 13),
              ),
              child: Text(context.l10n.libraryRemoveRating),
            ),
          ],
        ],
      ),
    );
  }
}

/// One number of the scale.
class _Score extends StatelessWidget {
  const _Score({
    required this.value,
    required this.filled,
    required this.focusNode,
    required this.onHover,
    required this.onPressed,
  });

  static const size = 32.0;

  final int value;
  final bool filled;
  final FocusNode focusNode;
  final ValueChanged<bool> onHover;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      focusNode: focusNode,
      onPressed: onPressed,
      onHover: onHover,
      // Every state spelled out: Material's own focus and hover tints wash
      // a filled number out until it looks switched off.
      style: ButtonStyle(
        // Filled in the text colour rather than the accent: a score is the
        // viewer's opinion, not what will play.
        backgroundColor: WidgetStatePropertyAll(
          filled ? Palette.text : Palette.raised,
        ),
        foregroundColor: WidgetStatePropertyAll(
          filled ? Palette.page : Palette.dim,
        ),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        // The keyboard's ring is the accent, as it is everywhere: it has to
        // be findable on a row where half the numbers are lit.
        side: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.focused) &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional
              ? BorderSide(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignOutside,
                )
              : BorderSide.none,
        ),
        fixedSize: const WidgetStatePropertyAll(Size.square(size)),
        minimumSize: const WidgetStatePropertyAll(Size.square(size)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Shape.controlRadius),
          ),
        ),
        textStyle: WidgetStatePropertyAll(
          Typo.cardTitle.copyWith(fontSize: 13),
        ),
        mouseCursor: WidgetStateMouseCursor.clickable,
      ),
      child: Text(
        NumberFormat.decimalPattern(context.l10n.localeName).format(value),
        semanticsLabel: context.l10n.libraryRatingOfTen(value),
      ),
    );
  }
}
