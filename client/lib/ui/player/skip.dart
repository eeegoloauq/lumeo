import 'package:flutter/material.dart';

import '../theme.dart';
import 'chapters.dart';

enum SkipAction { intro, next }

/// One calculation keeps the visible offer and its interval in sync after seeks.
class SkipMoment {
  const SkipMoment({
    required this.action,
    required this.start,
    required this.end,
    required this.fill,
    this.credits = true,
  });

  final SkipAction action;

  /// Whether the file marked this interval. A next-episode offer made only
  /// because the end is near is not a countdown: the last frame still holds
  /// for its own.
  final bool credits;

  final Duration start;
  final Duration end;

  /// Fill is visual progress, not a decision to advance.
  final double fill;

  Duration get target => end;
}

/// [notice] is how long before the end the next episode is offered when the
/// file marks no credits; zero offers it only once the file has ended.
SkipMoment? skipMoment({
  required List<MpvChapter> chapters,
  required Duration position,
  required Duration duration,
  required bool hasNext,
  Duration notice = Duration.zero,
}) {
  final opening = openingChapter(chapters);
  if (opening != null) {
    // mpv lists starts only; the next start or file duration supplies the end.
    final end = opening + 1 < chapters.length
        ? chapters[opening + 1].time
        : duration;
    final moment = _moment(
      SkipAction.intro,
      chapters[opening].time,
      end,
      position,
      // At the next chapter, skipping would seek to the current frame.
      includeEnd: false,
    );
    if (moment != null) return moment;
  }
  if (!hasNext) return null;
  final ending = endingChapter(chapters);
  if (ending == null) {
    // Past half the file, "before the end" would be the whole episode: a
    // short file is offered its successor once it ends, as before.
    if (notice <= Duration.zero || duration < notice * 2) return null;
    return _moment(
      SkipAction.next,
      duration - notice,
      duration,
      position,
      includeEnd: true,
      credits: false,
    );
  }
  // The offer covers previews and credits after the ending chapter too.
  return _moment(
    SkipAction.next,
    chapters[ending].time,
    duration,
    position,
    // mpv can hold the last frame at exactly the file duration.
    includeEnd: true,
  );
}

SkipMoment? _moment(
  SkipAction action,
  Duration start,
  Duration end,
  Duration position, {
  required bool includeEnd,
  bool credits = true,
}) {
  final span = end - start;
  // Invalid or unavailable duration cannot produce a meaningful fill.
  if (span <= Duration.zero) return null;
  if (position < start) return null;
  if (includeEnd ? position > end : position >= end) return null;
  return SkipMoment(
    action: action,
    start: start,
    end: end,
    fill: (position - start).inMilliseconds / span.inMilliseconds,
    credits: credits,
  );
}

String episodeLabel(int season, int episode) =>
    'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

/// The player only has the displayed name, so replace its episode number.
String nextEpisodeTitle(String current, int season, int episode) {
  final label = episodeLabel(season, episode);
  final numbered = RegExp(r' · S\d+E\d+$');
  return numbered.hasMatch(current)
      ? current.replaceFirst(numbered, ' · $label')
      : '$current · $label';
}

class SkipPill extends StatelessWidget {
  const SkipPill({
    super.key,
    required this.label,
    required this.fill,
    required this.onPressed,
  });

  final String label;

  final double fill;

  final VoidCallback onPressed;

  /// Keys go to mpv, so this button needs a generous pointer target.
  static const height = 44.0;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(Shape.control),
      child: Stack(
        children: [
          Positioned.fill(
            child: ColoredBox(color: Palette.floating.withValues(alpha: 0.92)),
          ),
          Positioned.fill(
            child: AnimatedFractionallySizedBox(
              // Linear interpolation smooths stepped position updates without
              // making the clock accelerate or slow down.
              duration: Motion.wash,
              curve: Curves.linear,
              alignment: Alignment.centerLeft,
              widthFactor: fill.clamp(0.0, 1.0),
              child: const ColoredBox(color: Palette.tint),
            ),
          ),
          TextButton(
            onPressed: onPressed,
            style: TextButton.styleFrom(
              foregroundColor: Palette.text,
              disabledForegroundColor: Palette.dim,
              backgroundColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              minimumSize: const Size(0, height),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(Shape.control),
                side: const BorderSide(color: Palette.rim),
              ),
            ),
            child: Text(label, style: Typo.button),
          ),
        ],
      ),
    );
  }
}
