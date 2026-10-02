import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'download_mark.dart';
import 'shelf.dart';

/// One title in a shelf. No caption underneath, so a row reads as a shelf;
/// the name, year, rating and how much is on disk appear on hover.
class PosterTile extends StatefulWidget {
  const PosterTile({
    super.key,
    required this.item,
    required this.onOpen,
    this.mark,
    this.watchFraction,
    this.captioned = false,
    this.caption,
    this.score = 0,
    this.width = ShelfMetrics.posterWidth,
  });

  final MediaItem item;
  final VoidCallback onOpen;

  /// On disk or arriving, in the corner; see [DownloadMark.of].
  final DownloadMark? mark;
  final double? watchFraction;

  /// The name and year printed under the artwork: off on a shelf, on for a
  /// results page, where posters are unfamiliar or missing.
  final bool captioned;

  /// The line under the name when [captioned], in place of the year: on My
  /// list what matters is how far the viewer is, not when the film came out.
  final String? caption;

  /// The viewer's own score, 1 to 10, after the caption. The star says it is
  /// theirs (the catalogue's rating is a bare number); an icon, because the
  /// type's subset has no star.
  final int score;

  final double width;

  @override
  State<PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<PosterTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final lifted = _hovered || _focused;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onOpen();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onOpen,
          child: Semantics(
            button: true,
            label: item.title,
            // The tile is the poster's width, caption included, so a click beside the
            // picture does not land on nothing.
            child: SizedBox(
              width: widget.width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AspectRatio(
                    aspectRatio: ShelfMetrics.posterAspect,
                    child: AnimatedScale(
                      scale: lifted ? ShelfMetrics.hoverScale : 1,
                      duration: const Duration(milliseconds: 140),
                      curve: Curves.easeOut,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _focused
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                            width: 2,
                          ),
                          boxShadow: lifted
                              ? const [
                                  BoxShadow(
                                    color: Color(0xB3000000),
                                    blurRadius: 22,
                                    offset: Offset(0, 8),
                                  ),
                                ]
                              : null,
                        ),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            PosterArtwork(
                              item: item,
                              width: widget.width,
                              named: !widget.captioned,
                            ),
                            // Fades: a hard cut on every pointer crossing flickers.
                            IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: lifted ? 1 : 0,
                                duration: const Duration(milliseconds: 140),
                                curve: Curves.easeOut,
                                child: _HoverFacts(
                                  item: item,
                                  captioned: widget.captioned,
                                ),
                              ),
                            ),
                            if (widget.mark != null)
                              Positioned(
                                top: WatchStatus.badgeInset,
                                right: WatchStatus.badgeInset,
                                child: widget.mark!,
                              ),
                            if (widget.watchFraction != null)
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: LinearProgressIndicator(
                                  value: widget.watchFraction!.clamp(0, 1),
                                  minHeight: WatchStatus.barHeight,
                                  color: WatchStatus.bar,
                                  backgroundColor: WatchStatus.track,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Excluded from semantics: the tile already announces itself by name.
                  if (widget.captioned)
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.only(
                          top: ShelfMetrics.captionGap,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Typo.cardTitle.copyWith(fontSize: 13),
                            ),
                            if ((widget.caption ?? item.years) case final line
                                when line.isNotEmpty || widget.score > 0)
                              Text.rich(
                                TextSpan(
                                  text: line,
                                  children: [
                                    if (widget.score > 0) ...[
                                      TextSpan(text: line.isEmpty ? '' : ' · '),
                                      const WidgetSpan(
                                        alignment: PlaceholderAlignment.middle,
                                        child: Padding(
                                          padding: EdgeInsets.only(right: 3),
                                          child: Icon(
                                            Icons.star,
                                            size: 12,
                                            color: Palette.muted,
                                          ),
                                        ),
                                      ),
                                      TextSpan(
                                        text: NumberFormat.decimalPattern(
                                          context.l10n.localeName,
                                        ).format(widget.score),
                                      ),
                                    ],
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Typo.data,
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Type over artwork we do not control needs its own contrast.
const _overArt = [
  Shadow(color: Color(0xE6000000), blurRadius: 10, offset: Offset(0, 1)),
];

/// What the hovered card says: the title first, since a poster's lettering
/// is a texture at this size, then the year and rating at opposite edges.
/// Not an expansion: a card that grows shoves its neighbours aside.
class _HoverFacts extends StatelessWidget {
  const _HoverFacts({required this.item, this.captioned = false});

  final MediaItem item;

  /// Whether the name and the year are already printed under the tile. When
  /// they are, this says only what they do not: the rating.
  final bool captioned;

  @override
  Widget build(BuildContext context) {
    final rating = item.imdbRating > 0
        ? NumberFormat('0.0', context.l10n.localeName).format(item.imdbRating)
        : '';
    return DecoratedBox(
      // Dark at the foot so type has a ground, gone by half way up.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Palette.ground(0.95),
            Palette.ground(0.80),
            Palette.ground(0),
          ],
          stops: const [0, 0.28, 0.62],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Unless a card with no artwork already prints the name.
            if (item.poster.isNotEmpty && !captioned)
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Typo.cardTitle.copyWith(shadows: _overArt),
              ),
            if ((item.years.isNotEmpty && !captioned) || rating.isNotEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  if (!captioned)
                    Text(
                      item.years,
                      style: Typo.data.copyWith(
                        color: Palette.dim,
                        shadows: _overArt,
                      ),
                    ),
                  const Spacer(),
                  if (rating.isNotEmpty)
                    Text(
                      rating,
                      style: Typo.dataStrong.copyWith(shadows: _overArt),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Artwork that never leaves a hole in the shelf: until it arrives, and if
/// it never does, the tile is a card with the title on it. Public so the
/// search panel loads posters the same way, with [cacheWidth].
class PosterArtwork extends StatelessWidget {
  const PosterArtwork({
    super.key,
    required this.item,
    required this.width,
    this.named = true,
  });

  /// Whether the card that stands in for missing artwork carries the title;
  /// false where the title is already printed under the tile.
  final bool named;

  final MediaItem item;
  final double width;

  @override
  Widget build(BuildContext context) {
    if (item.poster.isEmpty) {
      return _Blank(title: named ? item.title : '', width: width);
    }
    final blank = _Blank(title: named ? item.title : '', width: width);
    return Image(
      // Posters arrive around 660px wide and are shown at 160; decoded at full
      // size, a page of shelves holds hundreds of megabytes.
      image: ResizeImage.resizeIfNeeded(
        (width * MediaQuery.devicePixelRatioOf(context) * 1.1).round(),
        null,
        ArtworkImage(item.poster),
      ),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // Under the image rather than instead of it: with gaplessPlayback a new
      // cacheWidth keeps drawing the old poster while frame is null again.
      frameBuilder: (_, child, frame, _) => frame == null
          ? Stack(fit: StackFit.expand, children: [blank, child])
          : child,
      errorBuilder: (_, _, _) => blank,
    );
  }
}

/// A tile with no artwork behind it, looking like a card rather than a hole:
/// a lighter ground, an edge, and the title.
class _Blank extends StatelessWidget {
  const _Blank({required this.title, required this.width});

  final String title;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Palette.raised),
      // At thumbnail size the row beside it carries the title.
      child: title.isEmpty || width < 80
          ? const Center(
              child: Icon(Icons.movie_outlined, size: 15, color: Palette.muted),
            )
          : Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  title,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Typo.cardTitle.copyWith(color: Palette.dim),
                ),
              ),
            ),
    );
  }
}
