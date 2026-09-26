import 'dart:io';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../widgets/episode_card.dart' show EpisodePicture, shortDate;
import 'menus.dart';

class EpisodeStill extends StatelessWidget {
  const EpisodeStill(
    this.episode, {
    super.key,
    required this.width,
    required this.height,
    required this.frame,
    required this.artwork,
    this.watched = false,
  });

  final Episode episode;
  final double width;
  final double height;

  final File? frame;

  /// The "Episode stills" preference: show, blur (until watched) or hide.
  final String artwork;
  final bool watched;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(6),
    child: SizedBox(
      width: width,
      height: height,
      child: EpisodePicture(
        episode: episode,
        width: width,
        frame: frame,
        preference: artwork,
        watched: watched,
      ),
    ),
  );
}

class EpisodesPanel extends StatefulWidget {
  const EpisodesPanel({
    super.key,
    required this.episodes,
    required this.currentSeason,
    required this.currentEpisode,
    required this.progress,
    required this.runtime,
    required this.artwork,
    required this.frameOf,
    required this.onPlay,
  });

  final String artwork;
  final File? Function(Episode) frameOf;
  final List<Episode> episodes;
  final int currentSeason;
  final int currentEpisode;
  final WatchProgress? progress;
  final String runtime;
  final void Function(Episode) onPlay;

  @override
  State<EpisodesPanel> createState() => _EpisodesPanelState();
}

class _EpisodesPanelState extends State<EpisodesPanel> {
  late int season = widget.currentSeason;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = widget.episodes
          .where((e) => e.season == season)
          .toList()
          .indexWhere((e) => e.number == widget.currentEpisode);
      if (index > 0 && _scroll.hasClients) _scroll.jumpTo(index * 88.0);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seasons = widget.episodes.map((e) => e.season).toSet().toList()
      ..sort();
    final episodes = widget.episodes.where((e) => e.season == season).toList();
    return MenuPanel(
      width: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: MenuAnchor(
                menuChildren: [
                  for (final s in seasons)
                    MenuItemButton(
                      onPressed: () => setState(() {
                        season = s;
                        if (_scroll.hasClients) _scroll.jumpTo(0);
                      }),
                      child: Text(context.l10n.playerSeason(s)),
                    ),
                ],
                builder: (context, controller, _) => TextButton(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  child: Text(
                    context.l10n.playerSeasonDropdown(season),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              controller: _scroll,
              shrinkWrap: true,
              itemCount: episodes.length,
              itemExtent: 88,
              itemBuilder: (context, index) {
                final e = episodes[index];
                final entry = widget.progress?.entry(e.season, e.number);
                final current =
                    e.season == widget.currentSeason &&
                    e.number == widget.currentEpisode;
                final upcoming = e.isUpcoming;
                String detail;
                if (upcoming) {
                  detail = context.l10n.playerOutDate(
                    shortDate(
                      e.released!,
                      Localizations.localeOf(context).toString(),
                    ),
                  );
                } else if (entry != null &&
                    entry.position > Duration.zero &&
                    entry.duration > entry.position) {
                  detail = context.l10n.downloadsTimeLeftMinutes(
                    (entry.duration - entry.position).inMinutes,
                  );
                } else {
                  final minutes = entry?.duration.inMinutes ?? 0;
                  detail = [
                    if (minutes > 0)
                      context.l10n.downloadsMinutes(minutes)
                    else if (widget.runtime.isNotEmpty)
                      widget.runtime,
                    if (entry?.watched ?? false) context.l10n.playerWatched,
                  ].join(' · ');
                }
                return Opacity(
                  opacity: upcoming ? 0.45 : 1,
                  child: Material(
                    color: current
                        ? const Color(0x14FFFFFF)
                        : Colors.transparent,
                    child: InkWell(
                      onTap: upcoming || current
                          ? null
                          : () => widget.onPlay(e),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            Stack(
                              children: [
                                EpisodeStill(
                                  e,
                                  width: 128,
                                  height: 72,
                                  artwork: widget.artwork,
                                  frame: widget.frameOf(e),
                                  watched: entry?.watched ?? false,
                                ),
                                if (entry != null && entry.bar > 0)
                                  Positioned(
                                    left: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 128 * entry.bar,
                                      height: 3,
                                      color: Colors.white,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    e.label(context.l10n),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    detail,
                                    style: const TextStyle(
                                      color: Color(0xFFAAAAAA),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class NextEpisodeCard extends StatelessWidget {
  const NextEpisodeCard({
    super.key,
    required this.episode,
    required this.fill,
    required this.secondsLeft,
    required this.artwork,
    required this.frame,
    required this.onPressed,
  });
  final String artwork;
  final File? frame;
  final Episode episode;
  final double fill;

  /// Null when nothing counts down: the next episode waits for a press.
  final int? secondsLeft;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Glass(
    radius: 12,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  EpisodeStill(
                    episode,
                    width: 340,
                    height: 180,
                    artwork: artwork,
                    frame: frame,
                  ),
                  if (secondsLeft != null)
                    SizedBox(
                      width: 56,
                      height: 56,
                      // The fill arrives in steps (position updates, a 100 ms
                      // timer); tweening between them keeps the ring smooth.
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: fill),
                        duration: const Duration(milliseconds: 250),
                        builder: (_, value, _) => CircularProgressIndicator(
                          value: value,
                          strokeWidth: 3,
                          color: Colors.white,
                          backgroundColor: const Color(0x40FFFFFF),
                        ),
                      ),
                    ),
                  const Icon(Icons.play_arrow, color: Colors.white, size: 30),
                ],
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      secondsLeft == null
                          ? context.l10n.playerNextEpisode
                          : context.l10n.playerNextIn(secondsLeft!),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFAAAAAA),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      episode.fullLabel(context.l10n),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
