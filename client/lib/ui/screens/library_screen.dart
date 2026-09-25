import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../api/preferences_store.dart';
import '../../platform/local_settings.dart';
import '../player/episode_frames.dart';
import '../theme.dart';
import '../widgets/artwork_image.dart';
import '../widgets/buttons.dart';
import '../widgets/episode_card.dart' show EpisodePicture;
import '../widgets/horizontal_strip.dart';
import '../widgets/library_text.dart';
import '../widgets/loading.dart';
import '../widgets/poster_tile.dart';
import '../widgets/rating_button.dart';
import '../widgets/shelf.dart';
import '../widgets/top_bar.dart' show PillTab;

/// The two places in the library.
///
/// What is on disk is not a third: a title on disk carries the mark on its
/// poster wherever it is shown, and Settings › Storage lists them with their
/// sizes, which is the question somebody looking for what is on disk has.
enum LibrarySection {
  myList('My list'),
  history('History');

  const LibrarySection(this.title);

  final String title;
}

/// What the viewer keeps, has watched and thinks of it.
///
/// My list is a grid, as the search results are, because it is one list to
/// look through rather than rows to browse; with the new episodes of the
/// series being followed as a shelf above it, since those are the reason to
/// open the library on a Friday. History is lines rather than posters: it
/// is about episodes and evenings, and the place to score what was watched.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.api,
    required this.downloads,
    required this.preferences,
    required this.frames,
    required this.settings,
    required this.onOpen,
    this.section = LibrarySection.myList,
  });

  final LumeoApi api;
  final DownloadsStore downloads;
  final PreferencesStore preferences;
  final EpisodeFrames frames;

  /// Where the list's order is kept.
  final LocalSettings settings;

  /// Opens a title, on one of its episodes when one is named.
  final void Function(MediaItem item, {int? season, int? episode}) onOpen;
  final LibrarySection section;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  late LibrarySection _section = widget.section;
  late Future<_ListData> _list = _loadList();
  late final _history = _History(widget.api);

  @override
  void initState() {
    super.initState();
    if (_section == LibrarySection.history) unawaited(_history.more());
  }

  /// History is read the first time it is shown, not with the list: most
  /// visits to the library never open it.
  void _go(LibrarySection section) {
    setState(() => _section = section);
    if (section == LibrarySection.history) unawaited(_history.more());
  }

  @override
  void dispose() {
    _history.dispose();
    super.dispose();
  }

  Future<_ListData> _loadList() async {
    // New episodes are a shelf over the list, not the list: a core that
    // cannot work them out still shows what is on it.
    final fresh = widget.api.newEpisodes().catchError(
      (Object _) => <NewEpisodes>[],
    );
    final list = await widget.api.myList();
    return _ListData(list, await fresh);
  }

  /// History pages in as the end of it comes near, the way a shelf does.
  bool _onScroll(ScrollNotification n) {
    if (_section == LibrarySection.history &&
        n.metrics.axis == Axis.vertical &&
        n.metrics.extentAfter < 600) {
      _history.more();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _Header(
              section: _section,
              settings: widget.settings,
              onSection: _go,
            ),
          ),
          ...switch (_section) {
            LibrarySection.myList => _myList(),
            LibrarySection.history => _historyList(),
          },
          const SliverToBoxAdapter(child: SizedBox(height: 56)),
        ],
      ),
    );
  }

  List<Widget> _myList() => [
    FutureBuilder<_ListData>(
      future: _list,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SliverToBoxAdapter(
            child: _Note(
              title: 'The list did not load',
              text: 'The core did not answer for My list.',
              error: snapshot.error,
              onRetry: () => setState(() {
                _list = _loadList();
              }),
            ),
          );
        }
        final data = snapshot.data;
        if (data == null) {
          return const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: 48),
              child: Center(child: Loading()),
            ),
          );
        }
        return ListenableBuilder(
          listenable: widget.settings,
          builder: (context, _) => SliverMainAxisGroup(
            slivers: [
              if (data.fresh.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: _NewEpisodesShelf(
                    found: data.fresh,
                    downloads: widget.downloads,
                    onOpen: widget.onOpen,
                  ),
                ),
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      48,
                      ShelfMetrics.gap,
                      48,
                      ShelfMetrics.labelGap,
                    ),
                    child: Text('My list', style: Typo.shelfLabel),
                  ),
                ),
              ],
              if (data.list.isEmpty)
                const SliverToBoxAdapter(
                  child: _Note(
                    title: 'Nothing on your list yet',
                    text:
                        'Add a film or a series with + beside Play on its '
                        'page, and it waits here.',
                  ),
                )
              else
                _grid(sortListed(data.list, widget.settings.listSort)),
            ],
          ),
        );
      },
    ),
  ];

  Widget _grid(List<ListedTitle> titles) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 48),
    sliver: SliverGrid.builder(
      gridDelegate: _posterGrid,
      itemCount: titles.length,
      itemBuilder: (context, i) {
        final t = titles[i];
        return ListenableBuilder(
          listenable: widget.downloads,
          builder: (context, _) => PosterTile(
            key: ValueKey('listed:${t.item.id}'),
            item: t.item,
            progress: widget.downloads.progressFor(t.item.id),
            acquired: widget.downloads.isDoneFor(t.item.id),
            captioned: true,
            caption: listedCaption(t),
            score: t.rating,
            onOpen: () => widget.onOpen(t.item),
          ),
        );
      },
    ),
  );

  List<Widget> _historyList() => [
    ListenableBuilder(
      listenable: _history,
      builder: (context, _) {
        final h = _history;
        if (h.entries.isEmpty) {
          if (h.error != null) {
            return SliverToBoxAdapter(
              child: _Note(
                title: 'The history did not load',
                text: 'The core did not answer for what was watched.',
                error: h.error,
                onRetry: h.retry,
              ),
            );
          }
          return SliverToBoxAdapter(
            child: h.loading || !h.started
                ? const Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: Center(child: Loading()),
                  )
                : const _Note(
                    title: 'Nothing watched yet',
                    text:
                        'What you watch is listed here, the latest first, '
                        'with where you stopped. This is also where you '
                        'rate it.',
                  ),
          );
        }
        final now = DateTime.now();
        return SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 48),
          sliver: SliverList.builder(
            itemCount: h.entries.length + 1,
            itemBuilder: (context, i) {
              if (i == h.entries.length) {
                return _HistoryEnd(history: h);
              }
              final v = h.entries[i];
              return Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: _ViewingRow(
                    key: ValueKey(
                      'viewing:${v.item.id}:${v.entry.season}:${v.entry.episode}',
                    ),
                    viewing: v,
                    now: now,
                    preferences: widget.preferences,
                    frames: widget.frames,
                    onOpen: () => widget.onOpen(
                      v.item,
                      season: v.item.isSeries ? v.entry.season : null,
                      episode: v.item.isSeries ? v.entry.episode : null,
                    ),
                    onRate: (score) => _rate(v, score),
                    onClear: () => _rate(v, 0),
                    onRemove: () => _remove(v),
                  ),
                ),
              );
            },
          ),
        );
      },
    ),
  ];

  /// Scores what a line is about: the episode for a series, the film
  /// otherwise. The line changes at once and goes back if the core refuses.
  Future<void> _rate(Viewing v, int score) async {
    final was = v.rating;
    _history.replace(v, v.rated(score));
    try {
      if (score == 0) {
        await widget.api.unrate(
          v.item.id,
          season: v.entry.season,
          episode: v.entry.episode,
        );
      } else {
        await widget.api.rate(
          v.item.id,
          score,
          season: v.entry.season,
          episode: v.entry.episode,
        );
      }
    } on Object catch (_) {
      _history.replace(v.rated(score), v.rated(was));
      _say(
        score == 0 ? 'The rating was not removed' : 'The rating was not saved',
      );
    }
  }

  /// Takes a line out of the history, which is forgetting where it was left:
  /// the position goes with it, and so does its place in Continue watching.
  Future<void> _remove(Viewing v) async {
    final at = _history.remove(v);
    try {
      await widget.api.clearProgress(
        v.item.id,
        season: v.entry.season,
        episode: v.entry.episode,
      );
    } on Object catch (_) {
      _history.insert(at, v);
      _say('It was not removed from the history');
    }
  }

  void _say(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

/// The poster grid of the search results, with room for two lines under
/// each poster.
const _posterGrid = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: ShelfMetrics.posterWidth + ShelfMetrics.posterGap,
  childAspectRatio:
      ShelfMetrics.posterWidth /
      (ShelfMetrics.posterHeight + ShelfMetrics.captionHeight),
  crossAxisSpacing: ShelfMetrics.posterGap,
  mainAxisSpacing: ShelfMetrics.posterGap + 6,
);

/// My list in the order chosen. Titles compare without a leading article,
/// the way a shelf of films is alphabetised; what has no year or no score
/// goes to the end of an order by year or score.
List<ListedTitle> sortListed(List<ListedTitle> titles, String order) {
  final sorted = List.of(titles);
  int byAdded(ListedTitle a, ListedTitle b) => b.addedAt.compareTo(a.addedAt);
  int byTitle(ListedTitle a, ListedTitle b) =>
      _sortTitle(a.item.title).compareTo(_sortTitle(b.item.title));
  int last(int a, int b) => (a == 0 ? 1 : 0) - (b == 0 ? 1 : 0);
  switch (order) {
    case 'title':
      sorted.sort((a, b) {
        final t = byTitle(a, b);
        return t != 0 ? t : byAdded(a, b);
      });
    case 'year':
      sorted.sort((a, b) {
        final missing = last(a.item.year, b.item.year);
        if (missing != 0) return missing;
        final y = b.item.year.compareTo(a.item.year);
        return y != 0 ? y : byTitle(a, b);
      });
    case 'rating':
      sorted.sort((a, b) {
        final missing = last(a.rating, b.rating);
        if (missing != 0) return missing;
        final r = b.rating.compareTo(a.rating);
        return r != 0 ? r : byAdded(a, b);
      });
    default:
      sorted.sort(byAdded);
  }
  return sorted;
}

String _sortTitle(String title) {
  final lower = title.toLowerCase().trim();
  for (final article in const ['the ', 'a ', 'an ']) {
    if (lower.startsWith(article) && lower.length > article.length) {
      return lower.substring(article.length);
    }
  }
  return lower;
}

const _sortNames = {
  'added': 'Recently added',
  'title': 'Title',
  'year': 'Release year',
  'rating': 'Your rating',
};

class _ListData {
  const _ListData(this.list, this.fresh);

  final List<ListedTitle> list;
  final List<NewEpisodes> fresh;
}

/// The history as far as it has been read, and the reading of the rest.
class _History extends ChangeNotifier {
  _History(this._api);

  static const _page = 50;

  final LumeoApi _api;
  final entries = <Viewing>[];
  bool loading = false;
  bool started = false;
  bool _more = true;
  Object? error;
  bool _disposed = false;

  /// Where the next page starts on the core's side. Lines taken out here
  /// were taken out there too, so it moves back with them.
  int _offset = 0;

  Future<void> more() async {
    if (loading || !_more || error != null) return;
    loading = true;
    _notify();
    try {
      final page = await _api.history(limit: _page, offset: _offset);
      entries.addAll(page.entries);
      _offset += page.entries.length;
      _more = page.more;
    } on Object catch (e) {
      error = e;
    } finally {
      loading = false;
      started = true;
      _notify();
    }
  }

  void retry() {
    error = null;
    unawaited(more());
  }

  void replace(Viewing old, Viewing now) {
    final at = entries.indexWhere((e) => _same(e, old));
    if (at < 0) return;
    entries[at] = now;
    _notify();
  }

  int remove(Viewing v) {
    final at = entries.indexWhere((e) => _same(e, v));
    if (at < 0) return 0;
    entries.removeAt(at);
    _offset--;
    _notify();
    return at;
  }

  void insert(int at, Viewing v) {
    entries.insert(at.clamp(0, entries.length), v);
    _offset++;
    _notify();
  }

  static bool _same(Viewing a, Viewing b) =>
      a.item.id == b.item.id &&
      a.entry.season == b.entry.season &&
      a.entry.episode == b.entry.episode;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The page's name, where in it the window is, and the order of the list.
class _Header extends StatelessWidget {
  const _Header({
    required this.section,
    required this.settings,
    required this.onSection,
  });

  final LibrarySection section;
  final LocalSettings settings;
  final ValueChanged<LibrarySection> onSection;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 96, 48, 24),
      child: Row(
        children: [
          Text(
            'Library',
            style: Typo.heroTitle.copyWith(
              fontSize: 28,
              fontWeight: FontWeight.w600,
              shadows: null,
            ),
          ),
          const SizedBox(width: 24),
          for (final s in LibrarySection.values)
            PillTab(
              key: ValueKey('library:${s.name}'),
              label: s.title,
              selected: s == section,
              onTap: () => onSection(s),
            ),
          const Spacer(),
          if (section == LibrarySection.myList) _SortButton(settings: settings),
        ],
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.settings});

  final LocalSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => MenuAnchor(
        alignmentOffset: const Offset(0, 6),
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            Palette.floating.withValues(alpha: 0.97),
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          side: const WidgetStatePropertyAll(BorderSide(color: Palette.rim)),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Shape.floating),
            ),
          ),
        ),
        menuChildren: [
          for (final entry in _sortNames.entries)
            MenuItemButton(
              onPressed: () => settings.listSort = entry.key,
              leadingIcon: SizedBox.square(
                dimension: 18,
                child: entry.key == settings.listSort
                    ? const Icon(Icons.check, size: 18)
                    : null,
              ),
              child: Text(entry.value, style: Typo.cardTitle),
            ),
        ],
        builder: (context, menu, _) => TextButton(
          key: const ValueKey('list-sort'),
          onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          style: TextButton.styleFrom(
            foregroundColor: Palette.dim,
            overlayColor: Palette.hover,
            padding: const EdgeInsets.only(left: 12, right: 6),
            minimumSize: const Size(0, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: const StadiumBorder(),
            textStyle: Typo.cardTitle.copyWith(fontWeight: FontWeight.w500),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sort: ${_sortNames[settings.listSort]}'),
              const Icon(Icons.arrow_drop_down, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// The followed series with something new, as a shelf over the list.
class _NewEpisodesShelf extends StatelessWidget {
  const _NewEpisodesShelf({
    required this.found,
    required this.downloads,
    required this.onOpen,
  });

  final List<NewEpisodes> found;
  final DownloadsStore downloads;
  final void Function(MediaItem item, {int? season, int? episode}) onOpen;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Column(
      key: const ValueKey('new-episodes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(48, 0, 48, ShelfMetrics.labelGap),
          child: Text('New episodes', style: Typo.shelfLabel),
        ),
        HorizontalStrip(
          height: ShelfMetrics.rowHeight + ShelfMetrics.captionHeight,
          itemCount: found.length,
          separatorWidth: ShelfMetrics.posterGap,
          itemBuilder: (context, i) {
            final n = found[i];
            return ListenableBuilder(
              listenable: downloads,
              builder: (context, _) => PosterTile(
                item: n.item,
                progress: downloads.progressFor(n.item.id),
                acquired: downloads.isDoneFor(n.item.id),
                captioned: true,
                caption: newEpisodeCaption(n, now),
                // Onto the new episode itself: the page otherwise opens
                // where watching goes on, which for somebody behind is an
                // older one.
                onOpen: () => onOpen(
                  n.item,
                  season: n.episode.season,
                  episode: n.episode.number,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// One line of the history.
class _ViewingRow extends StatelessWidget {
  const _ViewingRow({
    super.key,
    required this.viewing,
    required this.now,
    required this.preferences,
    required this.frames,
    required this.onOpen,
    required this.onRate,
    required this.onClear,
    required this.onRemove,
  });

  static const _thumbWidth = 96.0;

  final Viewing viewing;
  final DateTime now;
  final PreferencesStore preferences;
  final EpisodeFrames frames;
  final VoidCallback onOpen;
  final ValueChanged<int> onRate;
  final VoidCallback onClear;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final v = viewing;
    final when = dayLabel(v.entry.updatedAt.toLocal(), now);
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Palette.divider)),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          hoverColor: Palette.hover,
          borderRadius: const BorderRadius.all(Shape.controlRadius),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.all(
                    Radius.circular(Shape.art),
                  ),
                  child: SizedBox(
                    width: _thumbWidth,
                    height: _thumbWidth * 9 / 16,
                    child: _picture(),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        viewingTitle(v),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Typo.cardTitle,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '$when · ${viewingState(v.entry)}',
                        maxLines: 1,
                        style: Typo.data,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                RatingButton(
                  score: v.rating,
                  label: 'Rate',
                  onRate: onRate,
                  onClear: onClear,
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: 'Remove from history',
                  onPressed: onRemove,
                  color: Palette.muted,
                  hoverColor: Palette.hover,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// An episode's still, under the same spoiler rule as the season strip;
  /// a film's backdrop.
  Widget _picture() {
    final v = viewing;
    if (v.item.isSeries) {
      return ListenableBuilder(
        listenable: Listenable.merge([preferences, frames]),
        builder: (context, _) => EpisodePicture(
          episode:
              v.episode ??
              Episode(season: v.entry.season, number: v.entry.episode),
          width: _thumbWidth,
          frame: frames.of(v.item.id, v.entry.season, v.entry.episode),
          preference: preferences.current?.episodeArtwork ?? 'show',
          watched: v.entry.watched,
        ),
      );
    }
    const blank = ColoredBox(
      color: Palette.surface,
      child: Center(
        child: Icon(Icons.movie_outlined, size: 18, color: Palette.muted),
      ),
    );
    if (v.item.background.isEmpty) return blank;
    return Image(
      image: ResizeImage.resizeIfNeeded(
        (_thumbWidth * 2.2).round(),
        null,
        ArtworkImage(v.item.background),
      ),
      fit: BoxFit.cover,
      frameBuilder: (_, child, frame, _) => frame == null ? blank : child,
      errorBuilder: (_, _, _) => blank,
    );
  }
}

/// Under the last line: the next page on its way, or the reason it is not.
class _HistoryEnd extends StatelessWidget {
  const _HistoryEnd({required this.history});

  final _History history;

  @override
  Widget build(BuildContext context) {
    if (history.error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Row(
          children: [
            Text('The rest did not load', style: Typo.data),
            const SizedBox(width: 12),
            QuietButton(label: 'Try again', onPressed: history.retry),
          ],
        ),
      );
    }
    if (history.loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: Center(child: Loading(size: 24)),
      );
    }
    return const SizedBox.shrink();
  }
}

/// A page with nothing to show says why, and what would help.
class _Note extends StatelessWidget {
  const _Note({
    required this.title,
    required this.text,
    this.error,
    this.onRetry,
  });

  final String title;
  final String text;
  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 24, 48, 0),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Typo.shelfLabel),
              const SizedBox(height: 8),
              Text(text, style: Typo.body),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text('$error', style: Typo.data),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: 18),
                QuietButton(label: 'Try again', onPressed: onRetry!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
