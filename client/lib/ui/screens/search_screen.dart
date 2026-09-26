import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import '../widgets/buttons.dart';
import '../widgets/poster_tile.dart';
import '../widgets/search_box.dart' show rankSearchResults;
import '../widgets/shelf.dart';

/// Search results as a grid rather than shelves: there is one list here, and
/// wrapping it is what lets someone see twenty answers at once instead of
/// scrolling sideways through them.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.query,
    required this.api,
    required this.downloads,
    required this.onOpen,
  });

  final String query;
  final LumeoApi api;
  final DownloadsStore downloads;
  final void Function(MediaItem) onOpen;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  late Future<List<MediaItem>> _results = _search();

  Future<List<MediaItem>> _search() async {
    // Both kinds, because nobody searching for a name knows or cares whether
    // it turned out to be a film or a series — and both at once, because asking
    // in turn makes the page wait for two round trips instead of one.
    //
    // Answered separately, though, not through `Future.wait`: one provider
    // timing out used to take the other one's answers down with it, so a word
    // with six series behind it came out as "nothing found".
    // Both handlers attached before either is awaited: attaching the second
    // after awaiting the first leaves a window where series can fail with
    // nobody listening, which Dart reports as an unhandled asynchronous error.
    var failed = 0;
    final films = widget.api.search(widget.query, kind: 'movie').onError((
      error,
      _,
    ) {
      failed++;
      return const [];
    });
    final series = widget.api.search(widget.query, kind: 'series').onError((
      error,
      _,
    ) {
      failed++;
      return const [];
    });
    final answers = [await films, await series];
    // Only both failing is the core being unreachable; one is a gap in the
    // catalogue, and the other list is still worth the page.
    if (failed == 2) {
      throw Exception('the catalogue did not answer');
    }
    // The same order the panel used, rather than one list after the other.
    // They are the same search: seeing the series first in the panel and last
    // on the page reads as the page having lost it.
    return rankSearchResults(
      widget.query,
      films: answers[0],
      series: answers[1],
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MediaItem>>(
      future: _results,
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <MediaItem>[];
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(48, 96, 48, 24),
                child: Row(
                  children: [
                    // Flexible, because a long enough query would otherwise
                    // run this heading off the side of the window.
                    Flexible(
                      child: Text(
                        snapshot.hasError
                            ? context.l10n.searchCatalogueUnavailable
                            : !snapshot.hasData
                            ? context.l10n.searchSearching(widget.query)
                            : items.isEmpty
                            ? context.l10n.searchNoResults(widget.query)
                            : context.l10n.searchResultCount(
                                items.length,
                                widget.query,
                              ),
                        style: Typo.shelfLabel,
                      ),
                    ),
                    // An empty screen is an invitation to act, and the one
                    // thing that can help here is asking again — the failure
                    // is usually a core that was still starting.
                    if (snapshot.hasError) ...[
                      const SizedBox(width: 16),
                      QuietButton(
                        label: context.l10n.commonTryAgain,
                        onPressed: () => setState(() {
                          _results = _search();
                        }),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (items.isEmpty && snapshot.hasData && !snapshot.hasError)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Text(
                    context.l10n.searchProviderHint,
                    style: Typo.body,
                  ),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent:
                      ShelfMetrics.posterWidth + ShelfMetrics.posterGap,
                  // The cell is the poster plus what the caption under it
                  // needs; left at the poster's own ratio the last line of
                  // every tile is cut off by the row below it.
                  childAspectRatio:
                      ShelfMetrics.posterWidth /
                      (ShelfMetrics.posterHeight + ShelfMetrics.captionHeight),
                  crossAxisSpacing: ShelfMetrics.posterGap,
                  mainAxisSpacing: ShelfMetrics.posterGap + 6,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) => ListenableBuilder(
                  listenable: widget.downloads,
                  builder: (context, _) => PosterTile(
                    item: items[i],
                    progress: widget.downloads.progressFor(items[i].id),
                    acquired: widget.downloads.isDoneFor(items[i].id),
                    captioned: true,
                    onOpen: () => widget.onOpen(items[i]),
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 56)),
          ],
        );
      },
    );
  }
}
