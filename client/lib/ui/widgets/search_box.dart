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
/// One [SearchAnchor] holds both, and that is deliberate: the panel a
/// SearchAnchor opens takes the position and the width of whatever the anchor
/// is. Anchored on the magnifier alone, a five hundred point panel would drop
/// out of a thirty point button and hang off to one side of the window;
/// anchored on the whole group, it opens exactly where the group was — the
/// tabs turn into a field with the answers under it, which is the one place
/// somebody who just typed is already looking.
///
/// Which is why the anchor is a box of [fieldHeight] and not whatever the bar
/// gives it. The panel's top edge is the anchor's top edge, and the anchor
/// left to fill the bar was sixty-eight points tall starting at the window's
/// frame: the field opened flush against the top of the window, higher than
/// the tabs it replaced and detached from them, and closing collapsed it into
/// that same edge. Bounded to the height of the field, the panel starts where
/// the tabs stand and grows downwards — the bar widens into a field in place,
/// the way every search field in a header does.
///
/// Nothing here is ours except the appearance: the overlay and where it sits,
/// the animation out of the anchor, the click outside, Escape, and a field
/// that keeps its own focus all come with the component. Not the keyboard
/// through the list — SearchAnchor has no notion of a highlighted suggestion,
/// and while a row can be reached with Tab, Down and Up in the field move the
/// caret and nothing else. Enter submits the word, which is the one keyboard
/// path that exists here.
///
/// What we add is a wait before asking — a keystroke is two HTTP requests to
/// the core, and nobody types one letter — and the height of the list, which
/// the component does not animate because it does not expect the answers to
/// arrive after the panel has (see [_Answers]).
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

  /// Held by the shell: Ctrl+F is pressed while a page has the keyboard, and
  /// opening the panel is something the shell has to be able to do to a widget
  /// it does not own.
  final SearchController controller;

  /// The width of the group at rest, which is also the width of the panel.
  final double width;

  /// Enter: everything for this word, as a page.
  final void Function(String) onSubmit;

  /// A line in the panel: that title, directly.
  final void Function(MediaItem) onOpen;

  /// What the middle of the bar is when nobody is searching.
  final Widget child;

  /// The field, and so the box the bar has to give this widget: the panel
  /// unfolds from exactly that rectangle. A little taller than the 34 points
  /// the tabs stand in, and centred on the same line, so that opening search
  /// widens the middle of the bar instead of moving it.
  static const fieldHeight = 42.0;

  @override
  State<SearchNav> createState() => _SearchNavState();
}

class _SearchNavState extends State<SearchNav> {
  /// Long enough that a typed word is one search rather than nine, short
  /// enough that the list feels like it is answering the keyboard.
  static const _wait = Duration(milliseconds: 220);

  /// Five titles and the line that opens the rest — what the catalogues this
  /// is modelled on show, and as many as fit over the page rather than instead
  /// of it. A panel that fills the window is a page, and there is already a
  /// page for that.
  static const _shown = 5;

  /// Answers already paid for, keyed by the lowercased word. Bounded, because
  /// this lives as long as the window does and somebody deleting a word one
  /// letter at a time leaves an entry behind for every prefix.
  final _cache = <String, List<MediaItem>>{};
  static const _cacheLimit = 40;

  /// The word the field holds now. A search that comes back for anything else
  /// is answering a question nobody is asking any more.
  String _wanted = '';

  /// What is on screen. Kept so a superseded search can leave it there instead
  /// of blanking the panel between two keystrokes.
  List<Widget> _showing = const [];

  /// Set when neither kind answered at all. The difference matters on screen:
  /// "nothing found" is about the word, and this is about the core.
  bool _unreachable = false;

  /// What was searched for before, offered under the empty field. Its own
  /// listenable, so forgetting one redraws the rows without asking the
  /// component for new suggestions, which it does only when the text moves.
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
      // No history is an empty field, which is what it was before there was
      // any: not worth a word in the panel.
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
      // The panel is as tall as its contents and no taller. Without this the
      // view is two thirds of the screen whatever is in it, so a word with one
      // answer opens a wall of empty surface.
      shrinkWrap: true,
      viewConstraints: BoxConstraints(
        minWidth: widget.width,
        maxWidth: widget.width,
        maxHeight: 620,
      ),
      viewBackgroundColor: Palette.floating,
      viewSurfaceTintColor: Colors.transparent,
      viewElevation: 12,
      // The answers arrive above the page, so they are shaped like it: the
      // floating radius, and a lit edge instead of an outline. A square panel
      // outlined in grey reads as a hole cut in the page rather than as
      // something laid on top of it.
      viewShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Shape.floating),
        side: const BorderSide(color: Palette.rim),
      ),
      // Ours, and inside the list rather than above it: see [_Answers]. The
      // component's own would be a hairline under an empty field, because the
      // list it belongs to has to be there before there is anything in it.
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
      // Material's own is a 24 point cross in a 48 point button, which in a
      // field this size reads as the loudest thing in the panel. And it is
      // there even with nothing typed, offering to clear an empty field.
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
      // The panel opens empty. It is the same rule as clearing it on the way
      // out — nobody wants the last search sitting in the field of a window
      // that is showing something else — but done here, because emptying the
      // field on the way out empties the list with it: the answers were gone
      // in the frame the panel began to close, and what closed was an empty
      // box. Left alone, the panel rolls up with the titles still in it.
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
      // Not an empty list: an empty list takes the whole list away, and with
      // it the box that gives the answers something to unroll out of. This is
      // that box, with the searches from before in it, or nothing. See
      // [_Answers].
      _showing = [
        _RecentSearches(recent: _recent, onPick: _repeat, onForget: _forget),
      ];
      return _showing;
    }
    final items = await _lookup(query);
    // Null means a later keystroke owns the field now: its own call is already
    // on its way, and blanking the panel until it lands is a flicker.
    if (items == null) return _showing;
    if (_unreachable) {
      _showing = const [_Rule(), _Unreachable()];
      return _showing;
    }
    _showing = [
      // The line under the field, which the component would otherwise draw
      // for us — see the divider above.
      const _Rule(),
      for (final item in items) ...[
        if (item != items.first) const _Rule(),
        _Result(
          // The rows are what a test taps and what it looks inside: the same
          // title is printed on posters in the shelf behind the panel.
          key: ValueKey('result:${item.id}'),
          item: item,
          onOpen: () => _open(item),
        ),
      ],
      // The line over the last row is the one that carries meaning: everything
      // above it is an answer, and the line under it is a way out of the panel.
      const _Rule(),
      _AllResults(query: query, onTap: () => _submit(query)),
      // The list ends at the panel's edge without this, which reads as a page
      // cut off rather than a panel that ends.
      const SizedBox(height: 8),
    ];
    return _showing;
  }

  /// The titles for one word, or null if that word is no longer the question.
  ///
  /// The two kinds are asked at once and answered separately. Separately
  /// matters: through `Future.wait` one provider timing out took the other
  /// one's answers with it, so a catalogue that could name six series looked
  /// like it had nothing at all.
  Future<List<MediaItem>?> _lookup(String query) async {
    final key = query.toLowerCase();
    final cached = _cache[key];
    if (cached != null) {
      // Cleared here as well as below: a word that failed leaves the flag set,
      // and the next word answering out of the cache would wear that failure.
      _unreachable = false;
      return cached;
    }
    await Future<void>.delayed(_wait);
    if (_wanted != query) return null;

    // Both handlers are attached before either is awaited. Attaching the
    // second one after awaiting the first is a window in which series can fail
    // with nobody listening, which Dart reports as an unhandled asynchronous
    // error rather than as an empty list.
    var failed = 0;
    final films = widget.api.search(query, kind: 'movie').onError((_, _) {
      failed++;
      return const [];
    });
    final series = widget.api.search(query, kind: 'series').onError((_, _) {
      failed++;
      return const [];
    });
    final gotFilms = await films;
    final gotSeries = await series;
    if (_wanted != query) return null;

    // Only when neither kind answered is this the core being unreachable
    // rather than a word with no films behind it.
    _unreachable = failed == 2;
    if (_unreachable) return const <MediaItem>[];

    final ranked = rankSearchResults(
      query,
      films: gotFilms,
      series: gotSeries,
      limit: _shown,
    );
    // Half an answer is not worth remembering: cached, it would keep the
    // provider that failed from ever being asked again for this word.
    if (failed == 0) {
      if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
      _cache[key] = ranked;
    }
    return ranked;
  }
}

/// The order six lines are worth showing in.
///
/// Two lists come back, one for each kind, and each is in the provider's own
/// order of relevance — which knows what people actually opened, and is a
/// better judgement of what "matrix" means than anything computable here.
/// What it cannot know is which of the two to take the next line from: the
/// answers carry no rating, no popularity and no score of any kind. A search
/// result from this catalogue is a name, a year and a poster.
///
/// Taking the two in step is what this replaces, and it is exactly what the
/// panel looked like — film, series, film, series, all the way down, whatever
/// the word was. Two answers are not equally good just because each is first
/// in its own list, and a word with three films behind it and one bad series
/// showed two of the films. (Concatenating is worse, and came before that: the
/// series that was the exact title went under every film the provider had.)
///
/// So the one judgement made here is the only one that can be made from the
/// row itself: how much of the title the typed word actually is. The exact
/// name first, then the titles that begin with it, then the titles that carry
/// it as a word, and last the ones that merely contain it somewhere. Inside a
/// tier the provider's order decides, because inside a tier it knows better.
/// The kind decides nothing at all except which of two otherwise identical
/// rows is printed first — there is no penalty for being a series.
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
    // Kept rather than dropped: the provider matched this on something that is
    // not on the row — an original title, another language's name — and
    // throwing it away is the client second-guessing a search it did not run.
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
        // A film and a series the provider rates the same, with the same claim
        // on the word, are shown film first because that is the more common
        // answer — not the better one, and not a rule about series.
        return byRank != 0 ? byRank : a.$3.compareTo(b.$3);
      });
  return [for (final row in ranked.take(limit ?? ranked.length)) row.$4];
}

/// A title reduced to the word somebody would say it by.
///
/// The leading article goes: "The Matrix" is what a person means when they
/// type "matrix", and a catalogue filing it under T is no reason to rank it
/// below a 1993 series that happens to be filed under M.
String _plain(String text) {
  final trimmed = text.trim().toLowerCase();
  for (final article in const ['the ', 'a ', 'an ']) {
    if (trimmed.startsWith(article)) return trimmed.substring(article.length);
  }
  return trimmed;
}

/// The answers, and how they arrive.
///
/// Everything else about this panel is animated by the component: it unfolds
/// out of the anchor and folds back into it. The list inside it is not — it is
/// rebuilt, so the one movement anybody actually watches was the one that
/// jumped. A word typed into an empty field went from forty points of field to
/// five rows and a footer between two frames, which is not a panel opening,
/// it is a panel being replaced by a different one.
///
/// So the list is always there, empty until there is something to say, and its
/// height is what changes. [AnimatedSize] clips to the height it is at, which
/// is why the rows are revealed downwards rather than squashed: the answers
/// are already the right size behind the edge that is moving.
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

/// One answer: the poster first, because that is what a title is recognised by
/// long before its name is read — and at its own proportions, which is the
/// whole reason this row is laid out by hand.
///
/// [ListTile] cannot draw it. It sizes the row from the text and then gives
/// the leading widget that height as a ceiling, so a poster asking for 56 by
/// 84 is handed 56 by 49 and `BoxFit.cover` crops a square out of the middle
/// of the artwork. Every attempt to make the covers bigger only made them
/// wider, and the reason was not in the number. What ListTile brought
/// otherwise — the pointer, the hover ground, the focus ring, Enter and Space
/// — is [InkWell]'s to begin with; what is ours here is the arithmetic of the
/// row, which is the part that had to change.
///
/// The text is centred against the artwork rather than pinned to its top.
/// Both exist: IMDb has three lines that fill the thumbnail's height and pins
/// them, Kinopoisk has two and centres them. Ours is two, and two lines
/// against an 84 point poster leave a hole under themselves.
///
/// The second line is words in their own order — "1996 Film" — rather than
/// facts strung on separators: a middle dot between two of them is a habit of
/// interfaces with nothing to say about either.
class _Result extends StatelessWidget {
  const _Result({super.key, required this.item, required this.onOpen});

  final MediaItem item;
  final VoidCallback onOpen;

  /// As wide as IMDb's thumbnail and half again as tall, because theirs is a
  /// 3:4 crop of the poster and this is the poster itself: cropping takes the
  /// top off, which is where a poster puts its name. Fifty-six was tried and
  /// made five rows six hundred points tall — a panel that is a page.
  static const _poster = 48.0;
  static const _pad = 9.0;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpen,
      hoverColor: Palette.raised,
      // The row the keyboard is on has to look like it. Arrow keys walk this
      // list, and a walk with nothing lit is a walk in the dark.
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

  /// What the name does not say, in the order it would be said out loud. No
  /// rating: the provider does not send one with a search result, and a column
  /// that is empty in every row but two is worse than no column.
  String _said(BuildContext context) {
    // The year first, as IMDb has it, and for the reason a search list exists
    // at all: the rows repeat one name — three of them here are called Fargo —
    // and what tells them apart is the year, not the word Film or Series. The
    // discriminating fact goes where the eye lands.
    final kind = item.kind == 'series'
        ? context.l10n.commonSeries
        : context.l10n.commonFilm;
    return item.years.isEmpty
        ? kind
        : context.l10n.searchYearKind(item.years, kind);
  }
}

/// The hairline between two answers. Full width rather than inset: the poster
/// column is not a margin, and a line that starts after it reads as a list
/// inside a list.
class _Rule extends StatelessWidget {
  const _Rule();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, thickness: 1, color: Palette.line);
}

/// Neither kind answered, so there is nothing to say about the word itself.
/// Offering "All results" here would open a page that is about to fail the
/// same way.
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
