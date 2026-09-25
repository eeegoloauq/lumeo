import 'dart:math';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../theme.dart';
import '../widgets/artwork_scrim.dart';
import '../widgets/buttons.dart';
import '../widgets/hero_logo.dart';
import '../widgets/loading.dart';
import '../widgets/shelf.dart';

/// The shelves worth a home screen, named by us: a provider calls its rows
/// "Popular" and "New", which says nothing once five of them are stacked.
const _shelves = <String, String>{
  'movie/top': 'Popular films',
  'series/top': 'Popular series',
  'movie/imdbRating': 'Highest rated',
  'movie/year': 'Out recently',
  'series/imdbRating': 'Highest rated series',
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.api,
    required this.downloads,
    required this.onOpen,
    required this.onPlay,
  });

  final LumeoApi api;
  final DownloadsStore downloads;
  final void Function(MediaItem) onOpen;

  /// The banner's Play. It opens the title too — the sources and the episodes
  /// are there, and so is anything that can go wrong — but it also means it,
  /// which the button did not: both buttons under the banner did the same
  /// thing, so the one labelled Play started nothing.
  final void Function(MediaItem) onPlay;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<_HomeData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_HomeData> _load() async {
    final continueItems = widget.api.continueWatching().catchError(
      (_) => <ContinueItem>[],
    );
    final rows = {
      for (final row in await widget.api.catalogs())
        '${row.kind}/${row.id}': row,
    };
    final shelves = <ShelfSpec>[];
    for (final entry in _shelves.entries) {
      final row = rows[entry.key];
      if (row != null) shelves.add(ShelfSpec(label: entry.value, row: row));
    }
    // Depth comes from genres. The provider lists which ones its catalogue
    // accepts, so the page is as long as the catalogue actually is instead of
    // as long as we guessed.
    shelves.addAll(_genreShelves(rows['movie/top'], 'films', 14));
    shelves.addAll(_genreShelves(rows['series/top'], 'series', 8));

    final lead = shelves.firstOrNull;
    if (lead == null) {
      return _HomeData(null, const [], const [], await continueItems);
    }
    final leadItems = await widget.api.catalog(lead.row);
    if (leadItems.isEmpty) {
      return _HomeData(null, shelves, const [], await continueItems);
    }
    // Never the title that opens the shelf underneath: the same poster twice
    // in a row reads as a bug even when it is not one.
    final choices = leadItems.length > 1 ? leadItems.sublist(1) : leadItems;
    final pick = choices[Random().nextInt(min(10, choices.length))];
    MediaItem? hero;
    try {
      hero = await widget.api.item(pick.id);
    } on Object catch (_) {
      // One title without metadata is not a reason to withhold the catalogue.
      hero = null;
    }
    // The title in the banner does not also open the shelf underneath it.
    final rest = hero == null
        ? leadItems
        : leadItems.where((e) => e.id != hero!.id).toList(growable: false);
    return _HomeData(hero, shelves, rest, await continueItems);
  }

  List<ShelfSpec> _genreShelves(CatalogRow? row, String noun, int limit) {
    if (row == null) return const [];
    return [
      for (final genre in row.genres.take(limit))
        ShelfSpec(label: '$genre $noun', row: row, genre: genre),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _Failure(
            error: snapshot.error!,
            onRetry: () => setState(() {
              _data = _load();
            }),
          );
        }
        if (!snapshot.hasData) return const Center(child: Loading());
        final data = snapshot.data!;
        if (data.shelves.isEmpty && data.continueItems.isEmpty) {
          return const _NothingToShow();
        }
        final hasHero = data.hero != null;
        final continueFirst = data.continueItems.isNotEmpty;
        final catalogStart = hasHero && !continueFirst ? 1 : 0;
        final looseContinue = !hasHero && continueFirst;
        final looseCount =
            data.shelves.length - catalogStart + (looseContinue ? 1 : 0);
        return CustomScrollView(
          slivers: [
            if (hasHero)
              // The viewport, asked of the viewport rather than of the window:
              // the hero is as tall as the screen can spare above the shelf
              // that has to be under it.
              SliverLayoutBuilder(
                builder: (context, constraints) => SliverToBoxAdapter(
                  // The first shelf lands over the bottom of the artwork,
                  // so the page reads as one surface rather than a banner
                  // with a list bolted underneath.
                  child: _HeroSlot(
                    screen: constraints.viewportMainAxisExtent,
                    item: data.hero!,
                    onOpen: widget.onOpen,
                    onPlay: widget.onPlay,
                    firstShelf: continueFirst
                        ? ContinueShelf(
                            key: const ValueKey('continue-watching'),
                            items: data.continueItems,
                            downloads: widget.downloads,
                            onOpen: widget.onPlay,
                          )
                        : data.shelves.isEmpty
                        ? null
                        : Shelf(
                            key: ValueKey(_shelfKey(data.shelves.first)),
                            spec: data.shelves.first,
                            initial: data.leadItems,
                            api: widget.api,
                            downloads: widget.downloads,
                            onOpen: widget.onOpen,
                          ),
                  ),
                ),
              ),
            SliverList.builder(
              itemCount: max(0, looseCount),
              itemBuilder: (context, i) {
                if (looseContinue && i == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: ShelfMetrics.gap),
                    child: ContinueShelf(
                      key: const ValueKey('continue-watching'),
                      items: data.continueItems,
                      downloads: widget.downloads,
                      onOpen: widget.onPlay,
                    ),
                  );
                }
                final shelf =
                    data.shelves[catalogStart + i - (looseContinue ? 1 : 0)];
                return Padding(
                  padding: const EdgeInsets.only(bottom: ShelfMetrics.gap),
                  child: Shelf(
                    key: ValueKey(_shelfKey(shelf)),
                    spec: shelf,
                    api: widget.api,
                    downloads: widget.downloads,
                    onOpen: widget.onOpen,
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        );
      },
    );
  }
}

class _HomeData {
  const _HomeData(this.hero, this.shelves, this.leadItems, this.continueItems);

  final MediaItem? hero;
  final List<ShelfSpec> shelves;

  /// The first page of the first shelf, already fetched to choose the hero.
  final List<MediaItem> leadItems;
  final List<ContinueItem> continueItems;
}

/// The hero and the shelf that sits over the bottom of it.
///
/// They share one box because a viewport paints its first sliver last: a shelf
/// in a later sliver would go under the artwork, not over it. The rest of the
/// shelves follow in a lazy list, where they belong.
class _HeroSlot extends StatelessWidget {
  const _HeroSlot({
    required this.item,
    required this.screen,
    required this.onOpen,
    required this.onPlay,
    required this.firstShelf,
  });

  /// The first shelf has to carry the gap the list gives every other one, or
  /// the two rows under the hero sit tighter than the rest.
  static const _overlap = 84.0;

  /// What a home screen owes whoever opens it: one whole shelf, posters and
  /// label, under the hero. The shelf lies over the bottom of the artwork, so
  /// the part of it the hero has to make room for is that much shorter.
  static double get _reveal =>
      ShelfMetrics.height + ShelfMetrics.gap - _overlap;

  final MediaItem item;
  final double screen;
  final void Function(MediaItem) onOpen;
  final void Function(MediaItem) onPlay;
  final Widget? firstShelf;

  @override
  Widget build(BuildContext context) {
    final height = BannerMetrics.height(
      context,
      screen: screen,
      reveal: _reveal,
    );
    final hero = _Hero(
      item: item,
      height: height,
      onOpen: onOpen,
      onPlay: onPlay,
    );
    if (firstShelf == null) return hero;
    // The hero sizes the slot, so a hero grown to fit a short window keeps
    // the shelf under its buttons rather than over them.
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(
            bottom: ShelfMetrics.height + ShelfMetrics.gap - _overlap,
          ),
          child: hero,
        ),
        Positioned(
          bottom: ShelfMetrics.gap,
          left: 0,
          right: 0,
          height: ShelfMetrics.height,
          child: firstShelf!,
        ),
      ],
    );
  }
}

String _shelfKey(ShelfSpec spec) =>
    '${spec.row.kind}/${spec.row.id}/${spec.genre}';

class _Hero extends StatelessWidget {
  const _Hero({
    required this.item,
    required this.height,
    required this.onOpen,
    required this.onPlay,
  });

  final MediaItem item;

  /// The least it is; what it holds can make it taller.
  final double height;
  final void Function(MediaItem) onOpen;
  final void Function(MediaItem) onPlay;

  @override
  Widget build(BuildContext context) {
    return BannerBox(
      height: height,
      background: [
        BannerArtwork(url: item.background),
        const ArtworkScrim(),
      ],
      child: Padding(
        // The top clears the bar that lies over the hero.
        padding: const EdgeInsets.fromLTRB(48, 90, 48, 128),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: _Title(item: item),
            ),
            const SizedBox(height: 14),
            _MetaLine(item: item),
            if (item.overview.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Text(
                  item.overview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Typo.heroBody,
                ),
              ),
            ],
            const SizedBox(height: 22),
            Row(
              children: [
                PlayButton(label: 'Play', onPressed: () => onPlay(item)),
                const SizedBox(width: 10),
                QuietButton(label: 'More info', onPressed: () => onOpen(item)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The title card the provider drew, if there is one. Set type is the fallback,
/// not the intent: artwork says the name better than any face we could pick.
class _Title extends StatelessWidget {
  const _Title({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    if (item.logo.isEmpty) return Text(item.title, style: Typo.heroTitle);
    return HeroLogo(url: item.logo, title: item.title);
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final parts = <String>[
      if (item.years.isNotEmpty) item.years,
      if (item.runtime.isNotEmpty) item.runtime,
      if (item.genres.isNotEmpty) item.genres.take(2).join(' / '),
    ];
    return Row(
      children: [
        if (item.imdbRating > 0) ...[
          Text(
            item.imdbRating.toStringAsFixed(1),
            style: Typo.heroMeta.copyWith(
              color: Palette.text,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          const Text('·', style: Typo.heroMeta),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            parts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Typo.heroMeta,
          ),
        ),
      ],
    );
  }
}

/// The core answered, and there is nothing in the answer. Say which piece is
/// missing rather than showing an empty page.
class _NothingToShow extends StatelessWidget {
  const _NothingToShow();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'No catalogues',
              style: Typo.heroTitle.copyWith(fontSize: 26, shadows: null),
            ),
            const SizedBox(height: 12),
            Text(
              'The core is running but no addon on its Sources list offers '
              'a catalogue to browse. Cinemeta does, needs no key, and is '
              'on the list of a fresh install.',
              style: Typo.body,
            ),
          ],
        ),
      ),
    );
  }
}

/// An empty screen is an invitation to act: say what failed, and offer the one
/// thing that can help.
class _Failure extends StatelessWidget {
  const _Failure({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The catalogue is not answering',
              style: Typo.heroTitle.copyWith(fontSize: 26, shadows: null),
            ),
            const SizedBox(height: 12),
            Text(
              'The Lumeo core did not answer the catalogue request. Check that '
              'it is running, then try again.',
              style: Typo.body,
            ),
            const SizedBox(height: 8),
            Text('$error', style: Typo.data),
            const SizedBox(height: 22),
            QuietButton(label: 'Try again', onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
