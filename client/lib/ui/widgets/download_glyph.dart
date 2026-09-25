import 'package:flutter/material.dart';

import '../../api/models.dart';

/// Download as one mark, wherever a button stands for it: an arrow; a ring
/// filling up while it arrives, left empty while nobody is sending; a solid
/// disk with the arrow knocked out once all of it is on disk.
class DownloadGlyph extends StatelessWidget {
  const DownloadGlyph({
    super.key,
    this.fraction,
    this.done = false,
    this.stalled = false,
    this.size = 24,
    this.color = Colors.white,
  });

  /// The state of one download, or of several read as one.
  DownloadGlyph.of(
    Download download, {
    Key? key,
    double size = 24,
    Color color = Colors.white,
  }) : this(
         key: key,
         fraction: download.isActive ? download.progress.fraction : null,
         done: download.isDone,
         stalled: download.isActive && download.progress.peers == 0,
         size: size,
         color: color,
       );

  /// Null when nothing is arriving.
  final double? fraction;
  final bool done;
  final bool stalled;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (done) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: Icon(
          Icons.download,
          size: size * 0.6,
          color: const Color(0xFF161616),
        ),
      );
    }
    if (fraction == null) return Icon(Icons.download, size: size, color: color);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              // Zero is "asked for, nothing yet": spin rather than sit empty.
              value: stalled ? 0 : (fraction! > 0 ? fraction : null),
              strokeWidth: size / 12,
              color: color,
              backgroundColor: color.withValues(alpha: 0.25),
            ),
          ),
          Icon(
            Icons.download,
            size: size * 0.55,
            color: stalled ? color.withValues(alpha: 0.6) : color,
          ),
        ],
      ),
    );
  }
}
