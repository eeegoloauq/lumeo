import 'package:flutter/material.dart';

import '../../api/downloads_store.dart';
import '../../l10n/l10n.dart';

import '../theme.dart';

/// On disk, or on its way there: what makes a title play without the swarm.
///
/// A corner badge rather than a bar, so the one bar along a picture's bottom
/// edge is always how much of it was watched.
class DownloadMark extends StatelessWidget {
  const DownloadMark.done({super.key}) : fraction = null;
  const DownloadMark.progress(double this.fraction, {super.key});

  /// Null once all of it is on disk.
  final double? fraction;

  /// The mark on a poster: how far what is arriving has got, while anything
  /// is; otherwise whether any of it is on disk. A download paused or given
  /// up on is not what the title is doing, and marks nothing. With [episode],
  /// only that episode's copies count: the one a card plays.
  static DownloadMark? of(
    DownloadsStore downloads,
    String itemId, {
    ({int season, int episode})? episode,
  }) {
    var completed = 0, total = 0;
    var arriving = false, onDisk = false;
    for (final d in downloads.all) {
      if (d.itemId != itemId ||
          episode != null &&
              (d.season != episode.season || d.episode != episode.episode)) {
        continue;
      }
      if (d.isDone) onDisk = true;
      if (d.isActive) {
        arriving = true;
        completed += d.progress.completed;
        total += d.progress.total;
      }
    }
    if (arriving) {
      return DownloadMark.progress(total <= 0 ? 0 : completed / total);
    }
    return onDisk ? const DownloadMark.done() : null;
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(WatchStatus.badgePadding),
    decoration: const BoxDecoration(
      color: Color(0x8C000000),
      shape: BoxShape.circle,
    ),
    child: IconTheme(
      data: const IconThemeData(
        size: WatchStatus.badgeIconSize,
        color: Palette.text,
      ),
      child: SizedBox.square(
        dimension: WatchStatus.badgeIconSize,
        child: fraction == null
            ? Icon(Icons.download, semanticLabel: context.l10n.downloadsOnDisk)
            : CircularProgressIndicator(
                value: fraction!.clamp(0, 1),
                strokeWidth: 2,
                color: Palette.text,
                backgroundColor: const Color(0x33F3F5F9),
                semanticsLabel: context.l10n.downloadsDownloading,
              ),
      ),
    ),
  );
}
