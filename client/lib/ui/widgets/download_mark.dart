import 'package:flutter/material.dart';

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
            ? const Icon(Icons.download, semanticLabel: 'On disk')
            : CircularProgressIndicator(
                value: fraction!.clamp(0, 1),
                strokeWidth: 2,
                color: Palette.text,
                backgroundColor: const Color(0x33F3F5F9),
                semanticsLabel: 'Downloading',
              ),
      ),
    ),
  );
}
