import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import 'poster_tile.dart';

/// Search, and the tabs it shares the middle of the bar with.
///
/// One [SearchAnchor] holds both: its panel takes the anchor's position and
/// width, so it opens exactly where the group was. The anchor is a box of
/// [fieldHeight] because the panel's top edge is the anchor's: left to fill
/// the bar, the field would open flush against the window's top.
///
/// The overlay, its animation, the click outside, Escape and the field's
/// focus come with the component. It has no highlighted suggestion, so Down
/// and Up only move the caret; rows are reached with Tab, and Enter submits.
///
/// Ours: a wait before asking (a keystroke is two requests to the core), and
/// the height of the list, which the component does not animate (see
/// [_Answers]).
class SearchNav extends StatefulWidget {
  const SearchNav({
    super.key,
    required this.api,
    required this.controller,
    required this.width,
    required this.onSubmit,
    required this.onOpen,
    required this.child,
  });

  final LumeoApi api;

  /// Held by the shell, which opens the panel on Ctrl+F.
  final SearchController controller;

  /// The width of the group at rest, which is also the width of the panel.
  final double width;

  /// Enter: everything for this word, as a page.
  final void Function(String) onSubmit;

  /// A line in the panel: that title, directly.
  final void Function(MediaItem) onOpen;

  /// What the middle of the bar is when nobody is searching.
  final Widget child;

  /// The field, and so the box the bar gives this widget: the panel unfolds
  /// from it. A little taller than the tabs and centred on their line, so
  /// opening search widens the middle of the bar instead of moving it.
  static const fieldHeight = 42.0;

  @override
  State<SearchNav> createState() => _SearchNavState();
}

class _SearchNavState extends State<SearchNav> {
  /// Long enough that a typed word is one search rather than nine, short
  /// enough that the list answers the keyboard.
  static const _wait = Duration(milliseconds: 220);

  /// Five titles and the line that opens the rest: as many as fit over the
  /// page rather than instead of it.
  static const _shown = 5;

  /// Answers already fetched, keyed by the lowercased word. Bounded: deleting
  /// a word letter by letter leaves an entry for every prefix.
  final _cache = <String, List<MediaItem>>{};
  static const _cacheLimit = 40;

  /// The word the field holds now; an answer for any other is dropped.
  String _wanted = '';

  /// What is on screen, kept so a superseded search does not blank the panel
  /// between two keystrokes.
  List<Widget> _showing = const [];

  /// Set when neither kind answered at all: that is about the core, not the
  /// word.
  bool _unreachable = false;

  /// What was searched for before, offered under the empty field. Its own
  /// listenable, so forgetting one redraws the rows: the component asks for
  /// suggestions only when the text moves.
  final _recent = ValueNotifier<List<String>>(const []);

  @override
  void dispose() {
    _recent.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    try {
      final recent = await widget.api.recentSearches();
      if (mounted) _recent.value = recent;
    } on Object catch (_) {
      // No history: an empty field, not worth a word.
    }
  }

  /// A search somebody went through with: the word they submitted, or the
  /// one whose answer they opened.
  void _remember(String query) {
    if (query.isEmpty) return;
    final key = query.toLowerCase();
    _recent.value = [
      query,
      for (final q in _recent.value)
        if (q.toLowerCase() != key) q,
    ];
    unawaited(widget.api.rememberSearch(query).catchError((Object _) {}));
  }

  void _forget(String? query) {
    _recent.value = query == null
        ? const []
        : [
            for (final q in _recent.value)
              if (q != query) q,
          ];
    unawaited(
      widget.api.forgetSearches(query: query).catchError((Object _) {}),
    );
  }

  /// A remembered search, asked again: into the field, where the answers
  /// follow as if it had been typed.
  void _repeat(String query) {
    widget.controller.value = TextEditingValue(
      text: query,
      selection: TextSelection.collapsed(offset: query.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SearchAnchor(
      searchController: widget.controller,
      isFullScreen: false,
      // As tall as its contents; the default is two thirds of the screen.
      shrinkWrap: true,
      viewConstraints: BoxConstraints(
        minWidth: widget.width,
        maxWidth: widget.width,
        maxHeight: 620,
      ),
      viewBackgroundColor: Palette.floating,
      viewSurfaceTintColor: Colors.transparent,
      viewElevation: 12,
      // Laid over the page, so shaped like the other floating surfaces.
      viewShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Shape.floating),
        side: const BorderSide(color: Palette.rim),
      ),
      // Ours, inside the list (see [_Answers]): the component's would be a
      // hairline under an empty field.
      dividerColor: Colors.transparent,
      headerHeight: SearchNav.fieldHeight,
      headerTextStyle: Typo.cardTitle.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w400,
      ),
      headerHintStyle: Typo.body.copyWith(fontSize: 15),
      viewHintText: context.l10n.searchHint,
      viewLeading: const Padding(
        padding: EdgeInsets.only(left: 14, right: 4),
        child: Icon(Icons.search, size: 18, color: Palette.muted),
      ),
      // Material's is a 24 point cross in a 48 point button, loud in a field this
      // size, and shown even with nothing typed.
      viewTrailing: [
        ListenableBuilder(
          listenable: widget.controller,
          builder: (context, _) => widget.controller.text.isEmpty
              ? const SizedBox(width: 8)
              : IconButton(
                  onPressed: widget.controller.clear,
                  icon: const Icon(Icons.close, size: 15),
                  color: Palette.muted,
                  tooltip: context.l10n.commonClear,
                  visualDensity: VisualDensity.compact,
                ),
        ),
      ],
      textInputAction: TextInputAction.search,
      viewOnSubmitted: _submit,
      // Cleared on the way in, not out: emptying the field on the way out empties
      // the list in the frame the panel begins to close.
      viewOnOpen: () {
        _wanted = '';
        _showing = const [];
        widget.controller.clear();
        unawaited(_loadRecent());
      },
      viewBuilder: (suggestions) => _Answers(rows: suggestions.toList()),
      builder: (context, controller) => widget.child,
      suggestionsBuilder: _suggest,
    );
  }

  void _submit(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _remember(trimmed);
    widget.controller.closeView(null);
    widget.onSubmit(trimmed);
  }

  void _open(MediaItem item) {
    _remember(_wanted);
    widget.controller.closeView(null);
    widget.onOpen(item);
  }

  Future<Iterable<Widget>> _suggest(
    BuildContext context,
    SearchController controller,
  ) async {
    final query = controller.text.trim();
    _wanted = query;
    if (query.isEmpty) {
      // Not an empty list, which removes the box the answers unroll out of (see
      // [_Answers]).
      _showing = [
        _RecentSearches(recent: _recent, onPick: _repeat, onForget: _forget),
      ];
      return _showing;
    }
    final items = await _lookup(query);
    // Null: a later keystroke's call is on its way; blanking now would flicker.
    if (items == null) return _showing;
    if (_unreachable) {
      _showing = const [_Rule(), _Unreachable()];
      return _showing;
    }
    _showing = [
      // The line under the field; see the divider above.
      const _Rule(),
      for (final item in items) ...[
        if (item != items.first) const _Rule(),
        _Result(
          // What a test taps: the same title is on posters behind the panel.
          key: ValueKey('result:${item.id}'),
          item: item,
          onOpen: () => _open(item),
        ),
      ],
      // The line over the last row separates the answers from the way out.
      const _Rule(),
      _AllResults(query: query, onTap: () => _submit(query)),
      // Without it the list reads as cut off at the panel's edge.
      const SizedBox(height: 8),
    ];
    return _showing;
  }

  /// The titles for one word, or null if that word is no longer the question.
  Future<List<MediaItem>?> _lookup(String query) async {
    final key = query.toLowerCase();
    final cached = _cache[key];
    if (cached != null) {
      // Cleared here as well as below: a word that failed leaves the flag set,
      // and the next word answered from the cache would wear that failure.
      _unreachable = false;
      return cached;
    }
    await Future<void>.delayed(_wait);
    if (_wanted != query) return null;

    final (:items, :failed) = await searchBoth(
      widget.api,
      query,
      limit: _shown,
    );
    if (_wanted != query) return null;
    _unreachable = failed == 2;
    // A half answer is not cached, or the provider that failed would never be
    // asked again for this word.
    if (failed == 0) {
      if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
      _cache[key] = items;
    }
    return items;
  }
}

/// Films and series for [query], ranked together. Both are asked at once and
/// answered separately, so one provider timing out does not take the other
/// one's answers with it; [failed] counts the kinds that did not answer, and
/// two means the core is unreachable.
Future<({List<MediaItem> items, int failed})> searchBoth(
  LumeoApi api,
  String query, {
  int? limit,
}) async {
  var failed = 0;
  List<MediaItem> none(Object _, StackTrace _) {
    failed++;
    return const [];
  }

  // Both handlers are attached before either is awaited, or a series failure
  // in between is an unhandled asynchronous error.
  final films = api.search(query, kind: 'movie').onError(none);
  final series = api.search(query, kind: 'series').onError(none);
  final items = rankSearchResults(
    query,
    films: await films,
    series: await series,
    limit: limit,
  );
  return (items: items, failed: failed);
}

/// The order six lines are worth showing in.
///
/// Each kind comes back in the provider's order of relevance, with no score
/// to merge the two by. So the one judgement made here is how much of the
/// title the typed word is: the exact name, then titles that begin with it,
/// then those that carry it as a word, then those that contain it. Inside a
/// tier the provider's order decides; the kind only breaks a tie.
List<MediaItem> rankSearchResults(
  String query, {
  required List<MediaItem> films,
  required List<MediaItem> series,
  int? limit,
}) {
  final wanted = _plain(query);
  int tier(MediaItem item) {
    final title = _plain(item.title);
    if (title == wanted) return 0;
    if (title.startsWith(wanted)) return 1;
    if (title.contains(' $wanted')) return 2;
    // Kept: the provider matched it on something not on the row, such as an
    // original title.
    return 3;
  }

  final ranked =
      <(int, int, int, MediaItem)>[
        for (final (i, item) in films.indexed) (tier(item), i, 0, item),
        for (final (i, item) in series.indexed) (tier(item), i, 1, item),
      ]..sort((a, b) {
        final byTier = a.$1.compareTo(b.$1);
        if (byTier != 0) return byTier;
        final byRank = a.$2.compareTo(b.$2);
        // A tie goes to the film, the more common answer.
        return byRank != 0 ? byRank : a.$3.compareTo(b.$3);
      });
  return [for (final row in ranked.take(limit ?? ranked.length)) row.$4];
}

/// A title reduced to the word somebody would say it by: without the
/// leading article.
String _plain(String text) {
  final trimmed = text.trim().toLowerCase();
  for (final article in const ['the ', 'a ', 'an ']) {
    if (trimmed.startsWith(article)) return trimmed.substring(article.length);
  }
  return trimmed;
}

/// The answers, and how they arrive.
///
/// The component animates the panel but rebuilds the list inside it, so
/// answers would jump in between two frames. The list is always there, empty
/// until there is something to say, and its height animates; [AnimatedSize]
/// clips, so rows are revealed downwards rather than squashed.
class _Answers extends StatelessWidget {
  const _Answers({required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: Motion.panel,
      curve: Motion.ease,
      alignment: Alignment.topCenter,
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        children: rows,
      ),
    );
  }
}

/// One answer, poster first and at its own proportions. [ListTile] cannot
/// draw it: it caps the leading widget at the text's height, cropping the
/// poster. [InkWell] brings the pointer, hover, focus ring and keys.
///
/// The two lines are centred against the poster. The second is words in
/// their own order, "1996 Film", not facts strung on separators.
class _Result extends StatelessWidget {
  const _Result({super.key, required this.item, required this.onOpen});

  final MediaItem item;
  final VoidCallback onOpen;

  /// A whole poster, not a crop: cropping takes the top off, where a poster
  /// puts its name. Any taller and five rows make a panel the size of a page.
  static const _poster = 48.0;
  static const _pad = 9.0;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      hoverColor: Palette.raised,
      // The row Tab is on has to look like it.
      focusColor: Palette.raised,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, _pad, 14, _pad),
        child: Row(
          children: [
            SizedBox(
              width: _poster,
              height: _poster * 3 / 2,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: PosterArtwork(item: item, width: _poster),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Typo.cardTitle.copyWith(fontSize: 16, height: 1.2),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _said(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Typo.body.copyWith(
                      fontSize: 13.5,
                      height: 1.3,
                      color: Palette.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the name does not say. No rating: a search result carries none.
  String _said(BuildContext context) {
    // The year first: rows often share a name, and the year tells them apart.
    final kind = item.kind == 'series'
        ? context.l10n.commonSeries
        : context.l10n.commonFilm;
    return item.years.isEmpty
        ? kind
        : context.l10n.searchYearKind(item.years, kind);
  }
}

/// The hairline between two answers, full width: inset after the poster it
/// reads as a list inside a list.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, color: Palette.line);
}

/// Neither kind answered. No "All results": that page would fail the same
/// way.
class _Unreachable extends StatelessWidget {
  const _Unreachable();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      minVerticalPadding: 10,
      leading: const SizedBox(
        width: 48,
        child: Icon(Icons.cloud_off, size: 18, color: Palette.warn),
      ),
      title: Text(
        context.l10n.searchCatalogueUnavailable,
        style: Typo.body.copyWith(fontSize: 14, color: Palette.warn),
      ),
    );
  }
}

/// The searches from before, under an empty field: the latest first, each one
/// asked again with a click and forgotten with its cross.
class _RecentSearches extends StatelessWidget {
  const _RecentSearches({
    required this.recent,
    required this.onPick,
    required this.onForget,
  });

  final ValueListenable<List<String>> recent;
  final void Function(String) onPick;

  /// Null forgets every one.
  final void Function(String?) onForget;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: recent,
      builder: (context, queries, _) {
        if (queries.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Rule(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(context.l10n.searchRecent, style: Typo.data),
                  ),
                  TextButton(
                    onPressed: () => onForget(null),
                    style: TextButton.styleFrom(
                      foregroundColor: Palette.dim,
                      textStyle: const TextStyle(fontSize: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(context.l10n.commonClear),
                  ),
                ],
              ),
            ),
            for (final query in queries)
              ListTile(
                key: ValueKey('recent:$query'),
                onTap: () => onPick(query),
                hoverColor: Palette.raised,
                focusColor: Palette.raised,
                dense: true,
                contentPadding: const EdgeInsets.only(left: 14, right: 6),
                leading: const SizedBox(
                  width: 36,
                  child: Icon(Icons.history, size: 18, color: Palette.muted),
                ),
                title: Text(
                  query,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Typo.body.copyWith(fontSize: 14),
                ),
                trailing: IconButton(
                  onPressed: () => onForget(query),
                  icon: const Icon(Icons.close, size: 15),
                  color: Palette.muted,
                  tooltip: context.l10n.searchForget,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

/// The way out of the panel and into the page, for a word with more answers
/// than five.
class _AllResults extends StatelessWidget {
  const _AllResults({required this.query, required this.onTap});

  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      hoverColor: Palette.raised,
      focusColor: Palette.raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      minVerticalPadding: 10,
      leading: const SizedBox(
        width: 36,
        child: Icon(Icons.search, size: 18, color: Palette.muted),
      ),
      title: Text(
        context.l10n.searchAllResults(query),
        style: Typo.body.copyWith(fontSize: 14),
      ),
    );
  }
}
