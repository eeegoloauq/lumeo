import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'download_mark.dart';
import 'shelf.dart';

/// One title in a shelf.
///
/// No caption underneath: a poster is a title card already, and a row of them
/// reads as a shelf only when nothing separates the artwork. The name and what
/// the artwork cannot say — year, rating, how much of it is on disk — appear on
/// hover, where they cost no layout.
class PosterTile extends StatefulWidget {
  const PosterTile({
    super.key,
    required this.item,
    required this.onOpen,
    this.progress,
    this.watchFraction,
    this.acquired = false,
    this.captioned = false,
    this.caption,
    this.score = 0,
    this.width = ShelfMetrics.posterWidth,
  });

  final MediaItem item;
  final VoidCallback onOpen;

  /// How much of this title is on disk, summed over everything downloaded for
  /// it. Null when none of it has been asked for.
  final Progress? progress;
  final double? watchFraction;
  final bool acquired;

  /// The name and year printed under the artwork.
  ///
  /// Off on a shelf, where a poster is a title card already and a row reads as
  /// a shelf only when nothing separates the artwork. On the results page it
  /// is on, because a wall of unfamiliar titles is a different thing: some of
  /// those posters are in another language, some are the wrong artwork for the
  /// right film, and some do not exist at all — the placeholder card is then
  /// the only tile on the page that says its own name.
  final bool captioned;

  /// The line under the name when [captioned], in place of the year: on My
  /// list what matters is how far the viewer is, not when the film came out.
  final String? caption;

  /// The viewer's own score, 1 to 10, after the caption. A star and the
  /// number, where the catalogue's rating is only ever a bare number: the
  /// star is what says it is theirs. An icon rather than a character, which
  /// the type's subset does not carry.
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: widget.width,
                  child: AspectRatio(
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
                            // Fades rather than appears: a hard cut on every pointer
                            // crossing makes a shelf feel like it is flickering.
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
                            if (widget.progress != null)
                              Positioned(
                                top: WatchStatus.badgeInset,
                                right: WatchStatus.badgeInset,
                                child: widget.acquired
                                    ? const DownloadMark.done()
                                    : DownloadMark.progress(
                                        widget.progress!.fraction,
                                      ),
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
                ),
                // Excluded from semantics rather than merged into it: the tile
                // already announces itself by name, and a screen reader that reads
                // the caption too says the title twice.
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
                                    TextSpan(text: '${widget.score}'),
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
    );
  }
}

/// What the hovered card says.
///
/// The title first. A poster usually prints its own, but at 160 points wide
/// that lettering is a texture rather than a word — which is exactly when
/// somebody is hovering to find out what they are looking at — and the ones
/// with no artwork have nothing at all. Then the two facts, pushed to opposite
/// edges: read as a pair in the middle they look like one value broken in
/// half, and the rating is what the eye comes back for, so it gets a corner of
/// its own.
///
/// Deliberately not an expansion: growing a card to half again
/// its size shoves its neighbours aside, and a shelf that rearranges under the
/// pointer is harder to aim at, not easier to read.
/// Type over artwork we do not control needs its own contrast.
const _overArt = [
  Shadow(color: Color(0xE6000000), blurRadius: 10, offset: Offset(0, 1)),
];

class _HoverFacts extends StatelessWidget {
  const _HoverFacts({required this.item, this.captioned = false});

  final MediaItem item;

  /// Whether the name and the year are already printed under the tile. When
  /// they are, this says only what they do not: the rating.
  final bool captioned;

  @override
  Widget build(BuildContext context) {
    final rating = item.imdbRating > 0
        ? item.imdbRating.toStringAsFixed(1)
        : '';
    return DecoratedBox(
      // Dark enough at the foot that type sits on a ground rather than on
      // whatever the poster happens to have there, and gone by half way up, so
      // the hovered card is still the brightest thing in the row.
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
            // Unless the tile is already the title: a card with no artwork
            // prints the name itself, and saying it again ten points lower is
            // the same word twice.
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

/// Artwork that never leaves a hole in the shelf: until it arrives the tile is
/// a card with the title on it, and if it never arrives that is what stays.
///
/// Public because the search panel shows the same posters at thumbnail size,
/// and two widgets loading one URL two ways is how one of them ends up without
/// [cacheWidth] and holds a panel of full-size bitmaps.
class PosterArtwork extends StatelessWidget {
  const PosterArtwork({
    super.key,
    required this.item,
    required this.width,
    this.named = true,
  });

  /// Whether the card that stands in for missing artwork carries the title.
  /// False where the title is already printed under the tile: the same name
  /// twice in two type sizes reads as a fault rather than as emphasis.
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
      // Posters arrive around 660px wide and are shown at 160. Without the
      // resize every one of them is decoded and held at full size, which a
      // page of twenty-seven shelves turns into hundreds of megabytes.
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

/// A tile with no artwork behind it.
///
/// It has to look like a card and not like a hole in the row, which the page
/// ground alone does not manage — a surface two steps off the background reads
/// as nothing at all on a dim screen. So: a lighter ground, an edge, and the
/// title, which is the whole reason anybody was looking at that rectangle.
class _Blank extends StatelessWidget {
  const _Blank({required this.title, required this.width});

  final String title;
  final double width;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Palette.raised),
      // At thumbnail size the name does not fit and is not the point: the row
      // beside it carries the title already, and four lines of clipped type in
      // a 36 point box reads as a rendering fault.
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
