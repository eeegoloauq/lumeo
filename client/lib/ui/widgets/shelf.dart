import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import 'horizontal_strip.dart';
import 'download_mark.dart';
import 'poster_tile.dart';

/// The measurements of a shelf, in one place: the hero sizes itself from
/// them, and everything derives from the poster and the label.
class ShelfMetrics {
  const ShelfMetrics._();

  static const posterWidth = 160.0;
  static const posterAspect = 2 / 3;
  static const posterHeight = posterWidth / posterAspect;

  /// The lift on hover has to fit in the gap, or neighbours get clipped.
  static const hoverScale = 1.05;
  static const posterGap = 8.0;
  static const rowHeight = posterHeight + 6;

  static const labelGap = 14.0;
  static double get labelHeight =>
      (Typo.shelfLabel.fontSize! * Typo.shelfLabel.height!).ceilToDouble() +
      labelGap;

  /// The space between one shelf and the next.
  static const gap = 28.0;

  /// What a captioned tile costs below the artwork: the gap, the title and
  /// the year. Stated, not measured: the grid needs the cell height first.
  static const captionGap = 8.0;
  static const captionHeight = captionGap + 17 + 16;

  static double get height => labelHeight + rowHeight;
}

/// What a shelf is before it has any titles in it.
class ShelfSpec {
  const ShelfSpec({required this.row, this.genre = ''});

  final CatalogRow row;
  final String genre;

  /// Named when drawn rather than when loaded, so a change of language
  /// renames the shelves already on the page.
  String label(AppLocalizations l10n) {
    if (genre.isNotEmpty) {
      return row.kind == 'series'
          ? l10n.homeGenreSeries(genre)
          : l10n.homeGenreFilms(genre);
    }
    return switch ('${row.kind}/${row.id}') {
      'movie/top' => l10n.homePopularFilms,
      'series/top' => l10n.homePopularSeries,
      'movie/imdbRating' => l10n.homeHighestRated,
      'movie/year' => l10n.homeOutRecently,
      'series/imdbRating' => l10n.homeHighestRatedSeries,
      _ => row.id,
    };
  }
}

/// One horizontal shelf, which loads itself and keeps going. It fetches
/// nothing until built, and asks for the next page while a screen of
/// posters is still left.
class Shelf extends StatefulWidget {
  const Shelf({
    super.key,
    required this.spec,
    required this.api,
    required this.downloads,
    required this.onOpen,
    this.initial = const [],
  });

  final ShelfSpec spec;

  /// A first page already fetched, for the shelf the hero was picked from.
  final List<MediaItem> initial;
  final LumeoApi api;
  final DownloadsStore downloads;
  final void Function(MediaItem) onOpen;

  @override
  State<Shelf> createState() => _ShelfState();
}

/// Watch progress is a complete, ordered list from the core: the catalogue
/// shelf's row and tiles, without paging.
class ContinueShelf extends StatelessWidget {
  const ContinueShelf({
    super.key,
    required this.items,
    required this.downloads,
    required this.onOpen,
  });

  final List<ContinueItem> items;
  final DownloadsStore downloads;
  final void Function(MediaItem) onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 0, 48, ShelfMetrics.labelGap),
          child: Text(
            context.l10n.homeContinueWatching,
            style: Typo.shelfLabel,
          ),
        ),
        HorizontalStrip(
          height: ShelfMetrics.rowHeight,
          itemCount: items.length,
          separatorWidth: ShelfMetrics.posterGap,
          itemBuilder: (context, i) {
            final item = items[i];
            return ListenableBuilder(
              listenable: downloads,
              builder: (context, _) => PosterTile(
                item: item.item,
                mark: DownloadMark.of(
                  downloads,
                  item.item.id,
                  episode: (
                    season: item.next.season,
                    episode: item.next.episode,
                  ),
                ),
                watchFraction: item.next.fraction,
                onOpen: () => onOpen(item.item),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ShelfState extends State<Shelf> with AutomaticKeepAliveClientMixin {
  final _controller = ScrollController();
  late List<MediaItem> _items = List.of(widget.initial);
  bool _loading = false;
  bool _exhausted = false;
  bool _empty = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    if (_items.isEmpty) _loadMore();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loading || _exhausted) return;
    if (_controller.position.maxScrollExtent - _controller.offset < 900) {
      _loadMore();
    }
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final next = await widget.api.catalog(
        widget.spec.row,
        genre: widget.spec.genre,
        skip: _items.length,
      );
      if (!mounted) return;
      setState(() {
        // Providers repeat their last page once they run out, so a page that
        // adds nothing new is the end of the shelf.
        final known = _items.map((e) => e.id).toSet();
        final fresh = next.where((e) => !known.contains(e.id)).toList();
        if (fresh.isEmpty) {
          _exhausted = true;
          _empty = _items.isEmpty;
        } else {
          _items = [..._items, ...fresh];
        }
        _loading = false;
      });
    } catch (_) {
      // A failed request is not the end of the shelf: the next scroll tries again.
      // Only a shelf with nothing at all steps aside, so a dead genre does not
      // pulse forever.
      if (mounted) {
        setState(() {
          _empty = _items.isEmpty;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // A genre nobody has titles for is not a shelf.
    if (_empty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 0, 48, ShelfMetrics.labelGap),
          child: Text(widget.spec.label(context.l10n), style: Typo.shelfLabel),
        ),
        if (_items.isEmpty)
          const SizedBox(
            height: ShelfMetrics.rowHeight,
            child: _ShelfSkeleton(),
          )
        else
          HorizontalStrip(
            controller: _controller,
            height: ShelfMetrics.rowHeight,
            itemCount: _items.length,
            separatorWidth: ShelfMetrics.posterGap,
            itemBuilder: (context, i) {
              final item = _items[i];
              // Only the tile listens, so a poll does not rebuild fifty posters.
              return ListenableBuilder(
                listenable: widget.downloads,
                builder: (context, _) => PosterTile(
                  item: item,
                  mark: DownloadMark.of(widget.downloads, item.id),
                  onOpen: () => widget.onOpen(item),
                ),
              );
            },
          ),
      ],
    );
  }
}

/// A shelf that has not arrived yet holds its own space, so nothing below it
/// jumps when it does.
class _ShelfSkeleton extends StatelessWidget {
  const _ShelfSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 48),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 8,
      separatorBuilder: (_, _) => const SizedBox(width: ShelfMetrics.posterGap),
      itemBuilder: (context, _) => const SizedBox(
        width: ShelfMetrics.posterWidth,
        child: AspectRatio(
          aspectRatio: ShelfMetrics.posterAspect,
          child: ColoredBox(color: Palette.surface),
        ),
      ),
    );
  }
}
