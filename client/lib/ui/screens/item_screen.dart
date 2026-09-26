import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../api/client.dart';
import '../../api/downloads_store.dart';
import '../../api/models.dart';
import '../../api/preferences_store.dart';
import '../../l10n/l10n.dart';
import '../player/episode_frames.dart';
import '../theme.dart';
import '../widgets/artwork_scrim.dart';
import '../widgets/buttons.dart';
import '../widgets/episode_card.dart';
import '../widgets/hero_logo.dart';
import '../widgets/horizontal_strip.dart';
import '../widgets/library_actions.dart';
import '../widgets/loading.dart';
import '../widgets/play_block.dart';

/// Which episode the page opens on: the one to play next when there is one,
/// and otherwise the last one watched.
///
/// "No next episode" is not "start from the beginning". A series that has
/// been caught up with has nothing to play until the next episode airs, and
/// reading that as nothing-at-all opened a title four seasons in at the
/// pilot, with Play pointed at it. With no progress at all there is genuinely
/// nothing to go on, and the page opens at the first episode as it always
/// did.
WatchEntry? openingEpisode(WatchProgress progress) {
  final next = progress.next;
  if (next != null) return next;
  WatchEntry? latest;
  for (final entry in progress.entries) {
    if (latest == null || entry.updatedAt.isAfter(latest.updatedAt)) {
      latest = entry;
    }
  }
  return latest;
}

/// The episode the page points Play and the source list at, with [season]'s
/// tab open: the one picked or resumed in it, else its first aired episode.
/// A season with nothing aired (an announced one) keeps the episode from
/// before; its dated cards are there to read, not to play.
Episode? pageEpisode({
  required int season,
  required List<Episode> episodes,
  Episode? picked,
  Episode? resumed,
}) {
  if (picked?.season == season) return picked;
  if (resumed?.season == season) return resumed;
  return episodes.where((e) => !e.isUpcoming).firstOrNull ??
      picked ??
      resumed ??
      episodes.firstOrNull;
}

/// Everything about one title, on one page.
///
/// No tabs: for a film the episode tab would not exist, and a page whose
/// structure changes with what you opened is harder to learn than a page you
/// scroll. Sources are not a section either — for a series they belong to an
/// episode, not to the title — so they hang under whatever Play would start.
class ItemScreen extends StatefulWidget {
  const ItemScreen({
    super.key,
    required this.itemId,
    required this.api,
    required this.downloads,
    required this.frames,
    required this.preferences,
    required this.onPlay,
    required this.onAddSource,
    this.autoplay = false,
    this.episode,
  });

  final String itemId;
  final LumeoApi api;
  final DownloadsStore downloads;
  final EpisodeFrames frames;
  final PreferencesStore preferences;

  /// Play was pressed somewhere else — on the banner of the home screen — and
  /// this page is where the sources for it live. Nothing is resolved twice:
  /// the press is carried into the first source list this page asks for, and
  /// starts it the moment it arrives.
  final bool autoplay;

  /// The episode to open on, when the page was opened for one — a line of
  /// the history. Otherwise the page opens where watching goes on.
  final ({int season, int episode})? episode;

  /// Hands the window over to the player once there is something to play.
  final void Function(String downloadId, String title, String background)
  onPlay;

  /// Opens the Sources settings, where a source addon is added.
  final VoidCallback onAddSource;

  @override
  State<ItemScreen> createState() => _ItemScreenState();
}

class _ItemScreenState extends State<ItemScreen> {
  late Future<_ItemData> _data;
  SourceChoice? _choice;
  Episode? _current;
  Timer? _settle;
  int? _season;
  final _episodeScroll = ScrollController();
  bool _placedCurrent = false;

  /// One per position in the strip, kept across seasons.
  final _cardNodes = <FocusNode>[];

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_ItemData> _load() async {
    final item = widget.api.item(widget.itemId);
    final progress = widget.api
        .progress(widget.itemId)
        .catchError((_) => const WatchProgress(entries: []));
    return _ItemData(item: await item, progress: await progress);
  }

  @override
  void dispose() {
    _settle?.cancel();
    _choice?.dispose();
    _episodeScroll.dispose();
    for (final node in _cardNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// A film's artwork is the whole window, so its source table opens below
  /// the fold — and a list that opens where nobody can see it did not open.
  /// The page follows the toggle: down far enough that the table is on
  /// screen with the Play head still above it, and back up when it closes.
  ///
  /// The page always has one current episode: the banner's Play button plays
  /// it, and the sources drawer lists its copies. Picking a card
  /// re-points both, which is why there is one choice and not one per row.
  SourceChoice _choiceFor(Episode? episode) {
    final existing = _choice;
    if (existing != null &&
        existing.season == (episode?.season ?? 0) &&
        existing.episode == (episode?.number ?? 0)) {
      return existing;
    }
    existing?.dispose();
    final choice = SourceChoice(
      api: widget.api,
      itemId: widget.itemId,
      season: episode?.season ?? 0,
      episode: episode?.number ?? 0,
      released: episode?.released,
      // Only the first list this page asks for: a Play from the banner means
      // this title, not whichever episode gets selected later.
      startWhenReady: widget.autoplay && existing == null,
      onStarted: (download) =>
          widget.onPlay(download.id, _playTitle(episode), _lastBackground),
      onAddSource: widget.onAddSource,
    );
    _choice = choice;
    return choice;
  }

  String _playTitle(Episode? episode) {
    final title = _lastTitle;
    if (episode == null) return title;
    final s = NumberFormat(
      '00',
      context.l10n.localeName,
    ).format(episode.season);
    final e = NumberFormat(
      '00',
      context.l10n.localeName,
    ).format(episode.number);
    return context.l10n.itemPlaybackTitle(title, s, e);
  }

  /// The title as it was last drawn. The player needs a name and the item is
  /// behind a future; keeping the last one avoids threading it through every
  /// callback.
  String _lastTitle = '';

  /// And the artwork with it: the player puts it behind the wait for the
  /// file, and it is the title's, not the episode's — a still of an episode
  /// not yet watched is the one picture this client takes care not to show.
  String _lastBackground = '';

  /// Plays an episode straight from its card. The list may still be on its
  /// way, so it starts as soon as there is something to start.
  void _playEpisode(Episode e) {
    _settle?.cancel();
    setState(() => _current = e);
    _choiceFor(e).start();
  }

  /// Selecting is not playing. A card points the page at its episode — the
  /// banner's button, its source line and the table all follow — and the play
  /// mark on the still is what actually starts it.
  void _selectEpisode(Episode e) {
    if (_current?.number == e.number && _current?.season == e.season) return;
    setState(() => _current = e);
    // Selecting is cheap, but asking a provider for a list is not: clicking
    // along a season would fire one request per card. The list is fetched for
    // the episode the pointer settles on.
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _choiceFor(e));
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_ItemData>(
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
        if (!snapshot.hasData) {
          return const Center(child: Loading());
        }
        final data = snapshot.data!;
        final item = data.item;
        final progress = data.progress;
        _lastTitle = item.title;
        _lastBackground = item.background;
        final seasons = _seasonsOf(item);
        final opensAt =
            widget.episode ??
            switch (openingEpisode(progress)) {
              final e? => (season: e.season, episode: e.episode),
              null => null,
            };
        final resumed = opensAt == null
            ? null
            : item.episodes
                  .where(
                    (e) =>
                        e.season == opensAt.season &&
                        e.number == opensAt.episode,
                  )
                  .firstOrNull;
        final season =
            _season ?? resumed?.season ?? (seasons.isEmpty ? 0 : seasons.first);
        final episodes = item.episodes
            .where((e) => e.season == season)
            .toList();
        final current = pageEpisode(
          season: season,
          episodes: episodes,
          picked: _current,
          resumed: resumed,
        );
        final choice = _choiceFor(current);
        final currentProgress = current == null
            ? progress.entry(0, 0)
            : progress.entry(current.season, current.number);
        _placeCurrent(episodes, current);
        final currentIndex = episodes.indexWhere(
          (e) => e.season == current?.season && e.number == current?.number,
        );

        return CustomScrollView(
          slivers: [
            // The viewport rather than the window: the banner is what the
            // screen has left over above the season block, so it is that
            // screen it has to be measured against.
            SliverLayoutBuilder(
              builder: (context, constraints) => SliverToBoxAdapter(
                child: _Banner(
                  item: item,
                  choice: choice,
                  progress: currentProgress,
                  series: item.isSeries,
                  screen: constraints.viewportMainAxisExtent,
                  reveal: seasons.isEmpty ? 0 : _seasonBlock,
                  action: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!item.isSeries) _filmDownload(choice),
                      LibraryActions(api: widget.api, itemId: widget.itemId),
                    ],
                  ),
                ),
              ),
            ),
            if (seasons.isNotEmpty)
              SliverToBoxAdapter(
                child: _Seasons(
                  seasons: seasons,
                  current: season,
                  action: _seasonDownload(season, episodes),
                  onPick: (s) => setState(() {
                    _season = s;
                    _placedCurrent = false;
                  }),
                ),
              ),
            // Always there, even with nothing to say: a sliver that came and
            // went with the synopsis rebuilt the strip below it, and the
            // strip scrolled back to the season's first episode.
            if (seasons.isNotEmpty)
              SliverToBoxAdapter(
                child: _EpisodeSynopsis(
                  episode: current?.season == season ? current : null,
                ),
              ),
            if (episodes.isNotEmpty)
              SliverToBoxAdapter(
                child: HorizontalStrip(
                  key: ValueKey('season:$season'),
                  controller: _episodeScroll,
                  height: _stripHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 48,
                    vertical: EpisodeCard.ring,
                  ),
                  itemCount: episodes.length,
                  separatorWidth: 14,
                  itemBuilder: (context, i) => ListenableBuilder(
                    listenable: Listenable.merge([
                      widget.preferences,
                      widget.downloads,
                      widget.frames,
                    ]),
                    builder: (context, _) => EpisodeCard(
                      episode: episodes[i],
                      focusNode: _cardNode(i),
                      tabStop: i == max(0, currentIndex),
                      frame: widget.frames.of(
                        widget.itemId,
                        episodes[i].season,
                        episodes[i].number,
                      ),
                      selected: episodes[i].number == current?.number,
                      progress: progress.entry(
                        episodes[i].season,
                        episodes[i].number,
                      ),
                      artworkPreference:
                          widget.preferences.current?.episodeArtwork ?? 'show',
                      download: widget.downloads.all
                          .where(
                            (d) =>
                                d.itemId == widget.itemId &&
                                d.season == episodes[i].season &&
                                d.episode == episodes[i].number,
                          )
                          .firstOrNull,
                      onSelect: () => _selectEpisode(episodes[i]),
                      onPlay: () => _playEpisode(episodes[i]),
                      onStep: (by) => i + by >= 0 && i + by < episodes.length
                          ? _step(i + by, episodes.length)
                          : _crossSeason(item, seasons, season, by),
                    ),
                  ),
                ),
              ),
            // The banner is measured to leave exactly this under the strip;
            // any more and a page that fits the window scrolls.
            if (episodes.isNotEmpty)
              const SliverToBoxAdapter(child: SizedBox(height: _breath)),
          ],
        );
      },
    );
  }

  /// A film's download: the copy Play would start, fetched without playing.
  /// Once it is all here the button goes, and the source says "On disk".
  Widget _filmDownload(SourceChoice choice) => ListenableBuilder(
    listenable: Listenable.merge([widget.downloads, choice]),
    builder: (context, _) {
      final row = widget.downloads.all
          .where((d) => d.itemId == widget.itemId && d.state != 'failed')
          .firstOrNull;
      if (row?.isDone ?? false) return const SizedBox.shrink();
      final running = choice.starting || (row?.isActive ?? false);
      final percent = ((row?.progress.fraction ?? 0) * 100).floor();
      // The gap to the buttons after it goes with it, or a film on disk
      // leaves a hole where the button was.
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: DownloadButton(
          tooltip: running
              ? context.l10n.itemDownloadingPercent(percent)
              : context.l10n.commonDownload,
          fraction: running ? row?.progress.fraction ?? 0 : null,
          onPressed: choice.picked == null ? null : choice.download,
        ),
      );
    },
  );

  /// The season's download: every released episode, each the copy Play would
  /// start for it.
  Widget _seasonDownload(int season, List<Episode> episodes) =>
      ListenableBuilder(
        listenable: widget.downloads,
        builder: (context, _) {
          final out = episodes.where((e) => !e.isUpcoming).toList();
          if (out.isEmpty) return const SizedBox.shrink();
          final rows = {
            for (final d in widget.downloads.all)
              if (d.itemId == widget.itemId &&
                  d.season == season &&
                  d.state != 'failed')
                d.episode: d,
          };
          double share(Episode e) => switch (rows[e.number]) {
            final d? when d.isDone => 1,
            final d? => d.progress.fraction,
            null => 0,
          };
          final have = out.where((e) => rows[e.number]?.isDone ?? false).length;
          final running = _queueing || rows.values.any((d) => d.isActive);
          final name = season == 0
              ? context.l10n.itemSpecialsDownload
              : context.l10n.itemSeasonDownload(season);
          final named = season == 0
              ? context.l10n.itemSpecials
              : context.l10n.itemSeason(season);
          return DownloadButton(
            tooltip: have == out.length
                ? context.l10n.itemDownloadOnDisk(named)
                : running
                ? context.l10n.itemDownloadProgress(named, have, out.length)
                : have > 0
                ? context.l10n.itemDownloadRest(name)
                : context.l10n.itemDownloadNamed(name),
            done: have == out.length,
            fraction: running
                ? out.map(share).reduce((a, b) => a + b) / out.length
                : null,
            onPressed: () => _downloadSeason(out, rows.keys.toSet()),
          );
        },
      );

  /// Set while the season's downloads are being asked for, one episode at a
  /// time: a provider asked for seventeen lists at once answers with a 403.
  bool _queueing = false;

  Future<void> _downloadSeason(List<Episode> episodes, Set<int> known) async {
    setState(() => _queueing = true);
    try {
      for (final e in episodes) {
        if (known.contains(e.number)) continue;
        final started = await downloadPreferred(
          widget.api,
          widget.itemId,
          season: e.season,
          episode: e.number,
        );
        if (started == null) continue;
        if (!mounted) return;
      }
    } on Object catch (error) {
      // Only the core not answering lands here: a provider that refuses gives
      // an empty list, and that episode is skipped. Without the core the rest
      // would fail the same way.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.l10n.itemSeasonStartFailed(error.toString())),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _queueing = false);
    }
  }

  FocusNode _cardNode(int index) {
    while (_cardNodes.length <= index) {
      _cardNodes.add(FocusNode(debugLabel: 'episode ${_cardNodes.length}'));
    }
    return _cardNodes[index];
  }

  /// Moves the keyboard to the card at [index], with the strip scrolled so
  /// a neighbour stays in sight on either side: a card at the very edge of
  /// the strip is a card nobody can see was reached.
  void _step(int index, int count) {
    if (index < 0 || index >= count || !_episodeScroll.hasClients) return;
    const stride = EpisodeCard.width + 14;
    final position = _episodeScroll.position;
    final viewport = position.viewportDimension;
    // Offsets that leave the previous card fully in from the left and the
    // next one fully in from the right, inside the strip's 48 px padding.
    final keepPrevious = (index - 1) * stride;
    final keepNext = (index + 1) * stride + EpisodeCard.width + 96 - viewport;
    final double to;
    if (keepNext > keepPrevious) {
      to = index * stride + (EpisodeCard.width + 96 - viewport) / 2;
    } else {
      to = position.pixels.clamp(keepNext, keepPrevious);
    }
    _episodeScroll.animateTo(
      to.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    _cardNode(index).requestFocus();
  }

  /// Past either end of a season the arrows go on into the next one, as a
  /// remote does on a TV: the tabs are the mouse's way between seasons.
  /// Specials are not part of the run.
  void _crossSeason(MediaItem item, List<int> seasons, int season, int by) {
    final runs = seasons.where((s) => s > 0).toList();
    final at = runs.indexOf(season);
    if (at < 0 || at + by < 0 || at + by >= runs.length) return;
    final next = item.episodes.where((e) => e.season == runs[at + by]).toList();
    if (next.isEmpty) return;
    final index = by > 0 ? 0 : next.length - 1;
    setState(() {
      _season = runs[at + by];
      _current = next[index].isUpcoming ? _current : next[index];
      _placedCurrent = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _step(index, next.length);
    });
  }

  void _placeCurrent(List<Episode> episodes, Episode? current) {
    if (_placedCurrent || current == null) return;
    final index = episodes.indexWhere(
      (e) => e.season == current.season && e.number == current.number,
    );
    _placedCurrent = true;
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_episodeScroll.hasClients) return;
      _episodeScroll.jumpTo(
        (index * (EpisodeCard.width + 14)).clamp(
          0.0,
          _episodeScroll.position.maxScrollExtent,
        ),
      );
      // The arrows work without a click first, and a TV has nothing to click
      // with. Not `autofocus`: the shell takes the keyboard after every
      // navigation, in a callback registered before this one.
      _cardNode(index).requestFocus();
    });
  }

  /// Specials come as season 0 and are real, so they are offered — just not
  /// first, because nobody opens a series to watch its extras.
  static List<int> _seasonsOf(MediaItem item) {
    final seasons = item.episodes.map((e) => e.season).toSet().toList()..sort();
    if (seasons.length > 1 && seasons.first == 0) {
      seasons.removeAt(0);
      seasons.add(0);
    }
    return seasons;
  }
}

class _ItemData {
  const _ItemData({required this.item, required this.progress});

  final MediaItem item;
  final WatchProgress progress;
}

/// What a series page owes whoever opens it, and therefore what the banner
/// above it has to leave room for: the row of seasons, the line about the
/// current episode, and a whole card of the strip — not the top of one, which
/// is a strip nobody knows is there. Each part is asked of the widget that
/// draws it, so this follows a change to any of them instead of going stale.
/// A film has none of it, and its banner is only bounded by the ceiling.
double get _seasonBlock =>
    _Seasons.height + _EpisodeSynopsis.height + _stripHeight + _breath;

const _stripHeight = EpisodeCard.height + 2 * EpisodeCard.ring;

/// The card is not flush with the bottom edge of the window.
const _breath = 16.0;

/// What the selected episode is about, in one place instead of on every card.
///
/// A strip of cards answers "which episode"; this answers "what is it". Kept
/// above the strip so it stays put while the cards move under the pointer, and
/// tied to the selection rather than to hover so nothing changes without being
/// asked.
class _EpisodeSynopsis extends StatelessWidget {
  const _EpisodeSynopsis({required this.episode});

  static const _lines = 2;
  static const _gap = 6.0;
  static const _below = 18.0;

  static double _line(TextStyle style) =>
      (style.fontSize! * style.height!).ceilToDouble();

  /// The same height whether or not this episode fills it: a page that
  /// changed height with the length of a synopsis would move the strip under
  /// the pointer every time a card was picked.
  static double get height =>
      _line(_titleStyle) + _gap + _line(Typo.body) * _lines + _below;

  static final _titleStyle = Typo.cardTitle.copyWith(fontSize: 17);

  final Episode? episode;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 0, 48, _below),
      child: SizedBox(
        height: height - _below,
        child: e == null
            ? null
            : ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        text: e.fullLabel(context.l10n),
                        children: [
                          if (e.released != null)
                            TextSpan(
                              text:
                                  '   ${DateFormat.yMMMd(context.l10n.localeName).format(e.released!)}',
                              style: Typo.data.copyWith(color: Palette.muted),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _titleStyle,
                    ),
                    const SizedBox(height: _gap),
                    Text(
                      e.overview,
                      // Two lines, not three: this is the one line of prose
                      // between the button and the strip, and a third line is
                      // what pushes the season off the bottom of a short
                      // window.
                      maxLines: _lines,
                      overflow: TextOverflow.ellipsis,
                      style: Typo.body.copyWith(color: Palette.dim),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The banner: artwork, what it is, and the one control that matters.
class _Banner extends StatelessWidget {
  const _Banner({
    required this.item,
    required this.choice,
    required this.progress,
    required this.series,
    required this.screen,
    required this.reveal,
    this.action,
  });

  final MediaItem item;
  final SourceChoice choice;
  final WatchEntry? progress;
  final bool series;
  final Widget? action;

  /// The scroll viewport, and how much of it belongs to what follows.
  final double screen;
  final double reveal;

  @override
  Widget build(BuildContext context) {
    return BannerBox(
      height: BannerMetrics.height(context, screen: screen, reveal: reveal),
      background: [
        BannerArtwork(url: item.background),
        const ArtworkScrim(),
      ],
      child: Padding(
        padding: const EdgeInsets.fromLTRB(48, 90, 48, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: item.logo.isEmpty
                  ? Text(item.title, style: Typo.heroTitle)
                  : HeroLogo(url: item.logo, title: item.title),
            ),
            const SizedBox(height: 14),
            _MetaLine(item: item),
            if (item.overview.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Text(
                  item.overview,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Typo.heroBody,
                ),
              ),
            ],
            const SizedBox(height: 24),
            PlayHead(
              choice: choice,
              progress: progress,
              series: series,
              action: action,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.item});

  final MediaItem item;

  @override
  Widget build(BuildContext context) {
    final seasons = item.episodes
        .map((e) => e.season)
        .where((s) => s > 0)
        .toSet();
    final parts = <String>[
      if (item.years.isNotEmpty) item.years,
      if (seasons.isNotEmpty) context.l10n.itemSeasonCount(seasons.length),
      if (item.runtime.isNotEmpty) item.runtime,
      if (item.genres.isNotEmpty) item.genres.take(3).join(' / '),
    ];
    return Row(
      children: [
        if (item.imdbRating > 0) ...[
          Text(
            NumberFormat(
              '0.0',
              context.l10n.localeName,
            ).format(item.imdbRating),
            style: Typo.heroMeta.copyWith(color: Palette.text),
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

class _Seasons extends StatelessWidget {
  const _Seasons({
    required this.seasons,
    required this.current,
    required this.action,
    required this.onPick,
  });

  static const _below = 14.0;

  /// The taller of a chip's box and the download button, plus the space under
  /// the row: what the banner has to leave room for.
  static double get height =>
      max(_SeasonChip.height, DownloadButton.size) + _below;

  final List<int> seasons;
  final int current;

  /// The season's download, at the end of the row.
  final Widget action;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 0, 48, _below),
      child: Row(
        children: [
          Expanded(
            child: seasons.length == 1
                ? const Divider(color: Palette.line, height: 1)
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in seasons)
                        _SeasonChip(
                          label: s == 0
                              ? context.l10n.itemSpecials
                              : context.l10n.itemSeason(s),
                          selected: s == current,
                          onTap: () => onPick(s),
                        ),
                    ],
                  ),
          ),
          const SizedBox(width: 12),
          action,
        ],
      ),
    );
  }
}

class _SeasonChip extends StatelessWidget {
  const _SeasonChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  static const _padding = 8.0;
  static const _border = 1.0;

  static double get height =>
      (Typo.cardTitle.fontSize! * Typo.cardTitle.height!).ceilToDouble() +
      (_padding + _border) * 2;

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: _padding,
          ),
          decoration: BoxDecoration(
            // A season is navigation, not a choice of what plays, so it is
            // marked by being raised rather than by the accent.
            color: selected ? Palette.raised : Colors.transparent,
            border: Border.all(
              color: selected ? Colors.transparent : Palette.line,
              width: _border,
            ),
            borderRadius: BorderRadius.circular(Shape.control),
          ),
          child: Text(
            label,
            style: Typo.cardTitle.copyWith(
              color: selected ? Palette.text : Palette.dim,
            ),
          ),
        ),
      ),
    );
  }
}

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
              context.l10n.itemLoadFailed,
              style: Typo.heroTitle.copyWith(fontSize: 26, shadows: null),
            ),
            const SizedBox(height: 12),
            Text(context.l10n.itemLoadFailedHint, style: Typo.body),
            const SizedBox(height: 8),
            Text('$error', style: Typo.data),
            const SizedBox(height: 22),
            QuietButton(label: context.l10n.commonTryAgain, onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
