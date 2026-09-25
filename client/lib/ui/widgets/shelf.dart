import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../theme.dart';
import 'horizontal_strip.dart';
import 'poster_tile.dart';

/// The measurements of a shelf, in one place.
///
/// The hero has to know how tall the shelf that overlaps it will be, and a
/// number copied into that calculation would drift the first time a padding
/// changes here. Everything derives from the poster and the label, so it
/// cannot.
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

  /// What a captioned tile costs below the artwork: the gap, the title and the
  /// year. Stated here rather than measured, because the grid that lays those
  /// tiles out has to know the cell's height before any of them is built.
  static const captionGap = 8.0;
  static const captionHeight = captionGap + 17 + 16;

  static double get height => labelHeight + rowHeight;
}

/// What a shelf is before it has any titles in it.
class ShelfSpec {
  const ShelfSpec({required this.label, required this.row, this.genre = ''});

  final String label;
  final CatalogRow row;
  final String genre;
}

/// One horizontal shelf, which loads itself and keeps going.
///
/// It fetches nothing until it is built, so a page of twenty-five shelves
/// costs one request on open rather than twenty-five. Horizontally, the next
/// catalogue page arrives while there is still a screen of posters left, so a
/// row never visibly runs out at fifty.
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

  /// A first page somebody already fetched — the shelf the hero was picked
  /// from has one, and asking the core for it twice would be silly.
  final List<MediaItem> initial;
  final LumeoApi api;
  final DownloadsStore downloads;
  final void Function(MediaItem) onOpen;

  @override
  State<Shelf> createState() => _ShelfState();
}

/// Watch progress is already a complete, ordered list from the core, so this
/// shelf shares the catalogue shelf's row and tiles without inventing paging
/// for a list that cannot have another page.
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
        const Padding(
          padding: EdgeInsets.fromLTRB(48, 0, 48, ShelfMetrics.labelGap),
          child: Text('Continue watching', style: Typo.shelfLabel),
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
                progress: downloads.progressFor(item.item.id),
                acquired: downloads.isDoneFor(item.item.id),
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
      // A failed request is not the end of the shelf. The next scroll tries
      // again; only a shelf that has nothing at all steps aside, so one dead
      // genre does not leave a skeleton pulsing forever.
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
    // A genre nobody has titles for is not a shelf; it leaves rather than
    // pretending to load.
    if (_empty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(48, 0, 48, ShelfMetrics.labelGap),
          child: Text(widget.spec.label, style: Typo.shelfLabel),
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
              // Only the tile listens, not the row: a poll every couple of
              // seconds should not rebuild a list of fifty posters to move
              // one bar.
              return ListenableBuilder(
                listenable: widget.downloads,
                builder: (context, _) => PosterTile(
                  item: item,
                  progress: widget.downloads.progressFor(item.id),
                  acquired: widget.downloads.isDoneFor(item.id),
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
