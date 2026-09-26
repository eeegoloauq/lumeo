import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../../platform/decoders.dart';
import '../theme.dart';
import 'buttons.dart';
import 'episode_card.dart' show shortDate;
import 'source_list.dart';

/// The choice of how to watch one thing: which copies exist, which one Play
/// will start, and whether the list is open.
///
/// It is a separate object because the button and the list do not sit
/// together: the button is in the banner, the list is a drawer over the page,
/// and the player's gear lists the same copies.
class SourceChoice extends ChangeNotifier {
  SourceChoice({
    required this.api,
    required this.itemId,
    this.season = 0,
    this.episode = 0,
    this.released,
    this.onStarted,
    this.onAddSource,
    this.startWhenReady = false,
  }) {
    load();
  }

  final LumeoApi api;
  final String itemId;
  final int season;
  final int episode;

  /// The episode's air date, when the provider gave one: what an empty list
  /// means depends on it.
  final DateTime? released;

  /// Called with the download that Play just started. Watching begins here:
  /// the file does not have to exist yet, only the download.
  final void Function(Download)? onStarted;

  /// Opens the Sources settings, for a list that is empty because no source
  /// addon is installed: none ships with the app.
  final VoidCallback? onAddSource;

  List<MediaSource>? sources;
  List<ProviderFailure> failed = const [];

  /// How many source addons the core asked.
  int providers = 0;
  MediaSource? picked;
  Object? error;
  bool loading = false;
  bool starting = false;

  /// Play was pressed before there was anything to play.
  ///
  /// It used to be dropped: start() found no source and returned, so the first
  /// press of the only button on the page did nothing and had to be repeated.
  /// The press is a decision, not a request for the current state, so it is
  /// kept and honoured as soon as the list arrives. It is also how a Play
  /// pressed in the banner on the home screen carries over to this page.
  bool startWhenReady;
  bool _disposed = false;

  /// Play has been asked for and has not happened yet, whether because the
  /// sources are still coming or because the download is being created.
  bool get pending => starting || startWhenReady;

  /// Play has something to start, or will once the list arrives. After an
  /// empty list it is off: a button that does nothing when pressed is worse
  /// than one that says it cannot be pressed.
  bool get playable => loading || picked != null;

  Future<void> load() async {
    loading = true;
    _ping();
    try {
      final found = await api.sources(itemId, season: season, episode: episode);
      // What this machine can decode decides which of them Play starts, so the
      // list waits for that answer rather than choosing without it. It was
      // asked for when the application started and is a memory read by now;
      // the await is here because "usually already there" is not a guarantee.
      await DeviceDecoders.instance.load();
      if (_disposed) return;
      sources = found.sources;
      failed = found.failed;
      providers = found.providers;
      picked = preferredSource(found.sources);
      error = null;
    } on Object catch (e) {
      error = e;
      // Nothing to honour it with, and nothing to wait for either.
      startWhenReady = false;
    } finally {
      loading = false;
      _ping();
      if (startWhenReady && picked != null) {
        startWhenReady = false;
        unawaited(start());
      }
    }
  }

  void pick(MediaSource source) {
    picked = source;
    _ping();
  }

  Future<void> start() => _start(play: true);

  /// The same copy Play would start, fetched without opening the player.
  Future<void> download() => _start(play: false);

  Future<void> _start({required bool play}) async {
    if (starting) return;
    final source = picked;
    if (source == null) {
      // Still looking. Hold the press instead of losing it; if the look is
      // already over and found nothing, there is genuinely nothing to hold.
      if (play && loading && !startWhenReady) {
        startWhenReady = true;
        _ping();
      }
      return;
    }
    starting = true;
    _ping();
    try {
      final download = await api.startDownload(
        itemId: itemId,
        source: source,
        season: season,
        episode: episode,
      );
      // The page may be gone by now — a slow core and a viewer who went back.
      // Calling this anyway opens the player over whatever they went back to.
      if (_disposed || !play) return;
      onStarted?.call(download);
    } on Object catch (e) {
      error = e;
    } finally {
      starting = false;
      _ping();
    }
  }

  String label(AppLocalizations l10n) =>
      season <= 0 ? l10n.commonPlay : l10n.playerPlayEpisode(season, episode);

  void _ping() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Which copy Play starts, out of the ranked list the core sent.
///
/// The core ranks by the swarm and by what the copy is, and puts ahead of
/// that what the library already chose: a copy on disk, then the pack used
/// last time for this title. What it cannot rank by is this machine, because
/// the same list is served to every client. So the one thing decided here is
/// the one thing only this end knows: a copy whose codec nothing here decodes
/// is a black screen, not the best copy. It stays in the table, marked; it is
/// not what a press of Play, or a download of the season, means.
MediaSource? preferredSource(List<MediaSource> found) {
  if (found.isEmpty) return null;
  bool playable(MediaSource s) =>
      DeviceDecoders.instance.gapIn(s.release) == null;
  return found.firstWhere(playable, orElse: () => found.first);
}

/// Downloads the copy Play would start for an episode, without opening the
/// player; null when no copy is listed for it.
Future<Download?> downloadPreferred(
  LumeoApi api,
  String itemId, {
  required int season,
  required int episode,
  bool prefetch = false,
}) async {
  final found = await api.sources(itemId, season: season, episode: episode);
  await DeviceDecoders.instance.load();
  final source = preferredSource(found.sources);
  if (source == null) return null;
  return api.startDownload(
    itemId: itemId,
    source: source,
    season: season,
    episode: episode,
    prefetch: prefetch,
  );
}

/// Play, and under it what Play will start: the copy on disk or the stream.
class PlayHead extends StatelessWidget {
  const PlayHead({
    super.key,
    required this.choice,
    this.progress,
    this.series = false,
    this.action,
  });

  final SourceChoice choice;
  final WatchEntry? progress;
  final bool series;

  /// Beside the source: a film's download button.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final entry = progress;
    final resume =
        entry != null &&
        entry.position > const Duration(seconds: 10) &&
        entry.duration > entry.position;
    return ListenableBuilder(
      listenable: choice,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PlayButton(
                label: !resume
                    ? choice.label(context.l10n)
                    : series
                    ? context.l10n.playerResumeEpisode(
                        entry.season,
                        entry.episode,
                      )
                    : context.l10n.playerResume,
                onPressed: choice.playable ? choice.start : null,
              ),
              if (resume) ...[
                const SizedBox(width: 16),
                Text(_left(entry, context.l10n), style: Typo.heroMeta),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: _Summary(choice: choice)),
              if (action case final action?) ...[
                const SizedBox(width: 8),
                action,
              ],
            ],
          ),
        ],
      ),
    );
  }

  static String _left(WatchEntry entry, AppLocalizations l10n) {
    final left = entry.duration - entry.position;
    final seconds = NumberFormat(
      '00',
      l10n.localeName,
    ).format(left.inSeconds.remainder(60));
    final clock = left.inHours > 0
        ? '${left.inHours}:'
              '${NumberFormat('00', l10n.localeName).format(left.inMinutes.remainder(60))}:$seconds'
        : '${left.inMinutes}:$seconds';
    return l10n.playerClockLeft(clock);
  }
}

/// What Play is about to start, and the way into the rest; or why there is
/// nothing to start.
class _Summary extends StatelessWidget {
  const _Summary({required this.choice});

  final SourceChoice choice;

  @override
  Widget build(BuildContext context) {
    if (choice.loading) {
      return Text(
        choice.pending
            ? context.l10n.playerWaitingForSource
            : context.l10n.playerLookingForSources,
        style: Typo.data,
      );
    }
    if (choice.error != null && choice.sources == null) {
      return _Line(
        text: choice.error is LumeoApiException
            ? context.l10n.playerCoreCouldNotAsk
            : context.l10n.playerCoreNoAnswer,
        action: context.l10n.commonTryAgain,
        onTap: choice.load,
      );
    }
    final picked = choice.picked;
    if (picked == null) {
      if (choice.providers == 0) {
        return _Line(
          text: context.l10n.playerNoSourceAddons,
          action: choice.onAddSource == null
              ? null
              : context.l10n.playerAddSource,
          onTap: choice.onAddSource ?? () {},
        );
      }
      final empty = emptySources(
        failed: choice.failed,
        released: choice.released,
        now: DateTime.now(),
        l10n: context.l10n,
      );
      return _Line(
        text: empty.text,
        action: empty.retry ? context.l10n.commonTryAgain : null,
        onTap: choice.load,
      );
    }
    final onDisk = picked.local == 'done';
    final r = picked.release;
    final facts = [
      if (r.resolution.isNotEmpty) r.resolution,
      if (onDisk)
        sourceTitle(picked, context.l10n)
      else
        formatBytes(picked.size, context.l10n),
    ].where((e) => e.isNotEmpty).join(' · ');
    return Tooltip(
      message: picked.rawName,
      child: TextButton(
        key: const ValueKey('source-chip'),
        onPressed: () => showSources(context, choice),
        style: TextButton.styleFrom(
          backgroundColor: Palette.tint,
          foregroundColor: Palette.text,
          fixedSize: const Size.fromHeight(DownloadButton.size),
          padding: const EdgeInsets.only(left: 12, right: 6),
          shape: const StadiumBorder(),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(onDisk ? Icons.check : Icons.play_circle_outline, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text.rich(
                TextSpan(
                  text: onDisk
                      ? context.l10n.downloadsOnDisk
                      : context.l10n.playerStream,
                  children: [
                    if (facts.isNotEmpty)
                      TextSpan(
                        text: ' · $facts',
                        style: const TextStyle(
                          color: Palette.dim,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Typo.cardTitle.copyWith(fontSize: 13),
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
    );
  }
}

/// Why the source list came back empty, and whether asking again can change
/// it.
///
/// [released] is Cinemeta's date, midnight UTC of the release day rather than
/// an air time, so "today" is the whole of that day and an empty list on it is
/// normal: copies turn up in the hours after the episode airs.
({String text, bool retry}) emptySources({
  required List<ProviderFailure> failed,
  DateTime? released,
  required DateTime now,
  required AppLocalizations l10n,
}) {
  final out = released?.toUtc();
  final utc = now.toUtc();
  if (out != null && out.isAfter(utc)) {
    return (
      text: l10n.itemOutDate(shortDate(out, l10n.localeName)),
      retry: false,
    );
  }
  // A refusal is the reason whatever the date: without it the list might not
  // have been empty.
  if (failed.isNotEmpty) {
    return (text: failed.map((f) => f.phrase(l10n)).join(' · '), retry: true);
  }
  if (out != null) {
    final days = DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
    ).difference(DateTime.utc(out.year, out.month, out.day)).inDays;
    if (days == 0) return (text: l10n.playerOutTodayNoCopies, retry: true);
    if (days == 1) return (text: l10n.playerOutYesterdayNoCopies, retry: true);
  }
  return (text: l10n.playerNoCopies, retry: true);
}

class _Line extends StatelessWidget {
  const _Line({required this.text, required this.onTap, this.action});

  final String text;
  final String? action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Typo.data.copyWith(color: Palette.dim),
          ),
        ),
        if (action case final action?) ...[
          const SizedBox(width: 12),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              backgroundColor: Palette.tint,
              foregroundColor: Palette.text,
              fixedSize: const Size.fromHeight(32),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              shape: const StadiumBorder(),
            ),
            child: Text(action, style: Typo.dataStrong),
          ),
        ],
      ],
    );
  }
}
