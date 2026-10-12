// What the player shows instead of, or over, the picture: the wait for a film,
// the reason it did not start, and short notices.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../theme.dart';
import '../widgets/buttons.dart';
import '../widgets/play_block.dart' show emptySources;
import '../widgets/source_list.dart' show formatBytes;
import 'chrome.dart' show clock;
import 'menus.dart' show SettingsMenu;

/// Translate mpv failures into actionable playback messages.
String playbackTrouble(Object error, AppLocalizations l10n) {
  final text = '$error';
  final codec = decoderErrorCodec(error);
  if (codec != null) {
    // Ask mpv about decoder availability before claiming it is missing.
    return l10n.playerDecoderCouldNotDecode(codec);
  }
  if (text.contains('Failed to open')) {
    // Startup retries are exhausted; the failing layer remains unknown.
    return l10n.playerCouldNotStartFile;
  }
  return text;
}

/// The codec an mpv error says it had no decoder for.
String? decoderErrorCodec(Object error) =>
    RegExp(r"decoder for codec '([^']+)'").firstMatch('$error')?.group(1);

class PlayerNotice extends StatelessWidget {
  const PlayerNotice({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Palette.floating.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(Shape.control),
        border: Border.all(color: Palette.rim),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Text(text, style: Typo.cardTitle.copyWith(color: Palette.dim)),
      ),
    );
  }
}

/// How long a download finds no peers before the player offers another copy.
const noPeersPatience = Duration(seconds: 30);

/// The download has looked for peers for [noPeersPatience] with the network
/// up: another copy is worth offering. Offline, no copy would do better.
bool findingNoPeers(Download d, DateTime now) {
  final since = d.waitingSince;
  return d.isActive &&
      d.stage == DownloadStage.findingPeers &&
      !d.offline &&
      since != null &&
      now.difference(since) >= noPeersPatience;
}

/// What the wait is on, the downloads panel's stage: how long it has looked
/// for peers, then how many it found, then how much has come and how fast.
String _waitLine(Download d, DateTime now, AppLocalizations l10n) {
  final p = d.progress;
  switch (d.stage) {
    case DownloadStage.findingPeers:
      final label = d.offline ? l10n.downloadsOffline : d.stage.label(l10n);
      final since = d.waitingSince;
      if (since == null) return label;
      final waited = now.difference(since);
      return l10n.downloadsWaitingSince(
        label,
        clock(waited.isNegative ? Duration.zero : waited),
      );
    case DownloadStage.fetchingMetadata:
      return l10n.playerPeers(d.stage.label(l10n), p.peers);
    case DownloadStage.arriving:
      return [
        l10n.playerPeers(
          l10n.playerPercent((p.fraction * 100).round()),
          p.peers,
        ),
        if (p.rate > 0) l10n.downloadsRate(formatBytes(p.rate, l10n)),
      ].join(' · ');
  }
}

class PlayerWaiting extends StatefulWidget {
  const PlayerWaiting({
    super.key,
    required this.title,
    required this.download,
    this.nextCopy,
    required this.onNextCopy,
    required this.error,
    required this.choiceError,
    required this.choiceEmpty,
    this.choiceFailed = const [],
    required this.overPicture,
    required this.playbackError,
    required this.decoderMissing,
    required this.decoderInstallHint,
    required this.onRetry,
    required this.onBack,
    required this.showBack,
  });

  /// The blurred artwork is there at once; the spinner and the title only once
  /// the wait is long enough to need saying. A file on disk opens in under a
  /// second, mostly mpv starting, and a spinner flashed for half of it read as
  /// something going wrong.
  static const delay = Duration(seconds: 1);

  final String title;

  /// The download being waited for, while it is still arriving; null for a
  /// file on disk or once the wait is for another episode.
  final Download? download;

  /// The copy offered in its place once it has found no peers for a while.
  final MediaSource? nextCopy;
  final ValueChanged<MediaSource> onNextCopy;
  final Object? error;
  final Object? choiceError;
  final bool choiceEmpty;

  /// The providers that refused or did not answer while the list came back
  /// empty: then they, not the copies, are the reason.
  final List<ProviderFailure> choiceFailed;
  final bool overPicture;
  final Object? playbackError;
  final bool? decoderMissing;
  final String? decoderInstallHint;
  final VoidCallback onRetry;
  final VoidCallback onBack;
  final bool showBack;

  @override
  State<PlayerWaiting> createState() => _PlayerWaitingState();
}

class _PlayerWaitingState extends State<PlayerWaiting> {
  bool _showPresentation = false;
  Timer? _timer;

  /// Counts the time spent finding peers between polls.
  late final Timer _clock;

  @override
  void initState() {
    super.initState();
    _timer = Timer(PlayerWaiting.delay, () {
      if (mounted) setState(() => _showPresentation = true);
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (widget.download?.waitingSince != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed =
        widget.error != null ||
        widget.choiceError != null ||
        widget.choiceEmpty ||
        widget.playbackError != null;
    final codec = widget.playbackError == null
        ? null
        : decoderErrorCodec(widget.playbackError!);
    final message = widget.choiceEmpty
        ? widget.choiceFailed.isEmpty
              ? context.l10n.playerNoCopyOf(widget.title)
              : emptySources(
                  failed: widget.choiceFailed,
                  now: DateTime.now(),
                  l10n: context.l10n,
                ).text
        : widget.choiceError != null
        ? context.l10n.playerCouldNotStartCopy
        : widget.error != null
        ? context.l10n.playerCoreStopped
        : widget.playbackError != null
        ? widget.decoderMissing == true && codec != null
              ? context.l10n.playerDecoderMissingShort(codec)
              : context.l10n.playerCopyWouldNotStart
        : '';
    final download = widget.download, next = widget.nextCopy;
    final now = DateTime.now();
    return Stack(
      children: [
        if (widget.overPicture)
          const Positioned.fill(child: ColoredBox(color: Color(0x99000000))),
        if (failed || _showPresentation)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!failed) ...[
                  const SizedBox(
                    width: 56,
                    height: 56,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: Colors.white,
                      backgroundColor: Color(0x33FFFFFF),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!failed && download != null && download.isActive) ...[
                  const SizedBox(height: 8),
                  Text(
                    _waitLine(download, now, context.l10n),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0x99FFFFFF),
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  // Below the line, so the ring and the title stay put.
                  if (next != null && findingNoPeers(download, now)) ...[
                    const SizedBox(height: 16),
                    QuietButton(
                      label: context.l10n.playerTryAnotherCopy,
                      onPressed: () => widget.onNextCopy(next),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        SettingsMenu.sourceLabel(next, context.l10n),
                        if (next.size > 0) formatBytes(next.size, context.l10n),
                        if (next.seeders > 0)
                          context.l10n.playerSeedCount(next.seeders),
                      ].join(' · '),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0x80FFFFFF),
                      ),
                    ),
                  ],
                ],
                if (failed) ...[
                  const SizedBox(height: 8),
                  Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFFAAAAAA),
                      fontSize: 13,
                    ),
                  ),
                  if (widget.decoderMissing == true &&
                      widget.decoderInstallHint != null) ...[
                    const SizedBox(height: 6),
                    SelectableText(
                      widget.decoderInstallHint!,
                      textAlign: TextAlign.center,
                      style: Typo.data,
                    ),
                  ],
                  const SizedBox(height: 16),
                  QuietButton(
                    label: context.l10n.playerTryAgain,
                    onPressed: widget.onRetry,
                  ),
                ],
              ],
            ),
          ),
        if (widget.showBack)
          Positioned(
            left: 24,
            top: 16,
            child: IconButton(
              onPressed: widget.onBack,
              tooltip: context.l10n.playerBackEsc,
              icon: const Icon(Icons.arrow_back, color: Colors.white),
            ),
          ),
      ],
    );
  }
}
