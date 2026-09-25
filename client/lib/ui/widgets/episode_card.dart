import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../api/models.dart';
import '../theme.dart';
import 'artwork_image.dart';
import 'download_mark.dart';

/// One episode as a card in a strip.
///
/// A season is a row, not a page: fourteen full-width rows meant scrolling
/// past everything else to reach episode nine, and the strip puts the whole
/// season within one gesture — the same gesture the shelves on the home screen
/// already use.
///
/// There is no synopsis on a card. An episode synopsis is a spoiler for the
/// thing about to be pressed play on, the still and the title identify it
/// already, and printing it fourteen times in a row was the noisiest part of
/// the strip.
class EpisodeCard extends StatefulWidget {
  const EpisodeCard({
    super.key,
    required this.episode,
    required this.selected,
    required this.focusNode,
    required this.tabStop,
    required this.onSelect,
    required this.onPlay,
    required this.onStep,
    this.frame,
    this.progress,
    this.download,
    this.artworkPreference = 'show',
  });

  static const width = 300.0;
  static const stillHeight = width * 9 / 16;
  static const height = stillHeight + 64;

  /// Drawn outside the still, so whatever holds a row of cards leaves this
  /// much room around them or the ring is cut off.
  static const ring = 2.0;

  final Episode episode;
  final bool selected;

  /// The strip's, so it can move the keyboard to a card it has not built yet.
  final FocusNode focusNode;

  /// The one card Tab lands on: the chosen one, or the first when the chosen
  /// episode is in another season.
  final bool tabStop;
  final VoidCallback onSelect;
  final VoidCallback onPlay;

  /// Left or right from this card, by one.
  final void Function(int by) onStep;

  /// A frame from the file on disk, for an episode metahub has no still for.
  final File? frame;
  final WatchEntry? progress;
  final Download? download;
  final String artworkPreference;

  @override
  State<EpisodeCard> createState() => _EpisodeCardState();
}

class _StepIntent extends Intent {
  const _StepIntent(this.by);
  final int by;
}

/// One card is one stop for the keyboard, and being on it is choosing it:
/// the arrows walk the season and Enter plays what they reached. Tab enters
/// the strip on the chosen card only (a roving tab stop), so leaving the
/// strip is one key, not one per episode. The mouse chooses with a click and
/// plays with the button on the still.
class _EpisodeCardState extends State<EpisodeCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final e = widget.episode;
    final upcoming = e.isUpcoming;
    final lit = widget.selected || _focused;
    final meta = [
      if (upcoming && e.released != null) 'Out ${shortDate(e.released!)}',
      if (e.isRecent) shortDate(e.released!),
      if (e.rating > 0) e.rating.toStringAsFixed(1),
    ].join(' · ');
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft): _StepIntent(-1),
        SingleActivator(LogicalKeyboardKey.arrowRight): _StepIntent(1),
      },
      child: Actions(
        actions: {
          _StepIntent: CallbackAction<_StepIntent>(
            onInvoke: (intent) => widget.onStep(intent.by),
          ),
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => upcoming ? null : widget.onPlay(),
          ),
        },
        child: Focus(
          focusNode: widget.focusNode,
          skipTraversal: !widget.tabStop,
          onFocusChange: (focused) {
            // Flutter also calls this when the node's traversal flags change,
            // which the tab stop moving to the played card does; treating that
            // as focus arriving re-selected this card over the one played.
            if (focused == _focused) return;
            setState(() => _focused = focused);
            if (focused && !upcoming) widget.onSelect();
          },
          child: MouseRegion(
            cursor: upcoming
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              onTap: upcoming ? null : () => _byPointer(widget.onSelect),
              child: SizedBox(
                width: EpisodeCard.width,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Still(
                      episode: e,
                      frame: widget.frame,
                      dimmed: upcoming,
                      // The mouse's way to start; the keyboard has Enter.
                      showPlay: _hovered && !upcoming,
                      // A card the keyboard is on but cannot choose (not out
                      // yet) is marked apart from the chosen one.
                      ring: widget.selected || (_focused && !upcoming)
                          ? Palette.text
                          : _focused
                          ? Palette.muted
                          : null,
                      progress: widget.progress,
                      download: widget.download,
                      artworkPreference: widget.artworkPreference,
                      onPlay: () => _byPointer(widget.onPlay),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      e.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Typo.cardTitle.copyWith(
                        fontSize: 15,
                        color: upcoming
                            ? Palette.muted
                            : lit
                            ? Palette.text
                            : Palette.dim,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(meta, style: Typo.data.copyWith(color: Palette.muted)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Keeps the arrows walking from the card the pointer chose when the
  /// keyboard was already in the strip.
  void _byPointer(VoidCallback action) {
    action();
    if (_stripHasFocus) widget.focusNode.requestFocus();
  }

  bool get _stripHasFocus =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EpisodeCard>() !=
      null;
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String shortDate(DateTime d) => '${d.day} ${_months[d.month - 1]}';

class _Still extends StatelessWidget {
  const _Still({
    required this.episode,
    required this.frame,
    required this.showPlay,
    required this.ring,
    required this.progress,
    required this.download,
    required this.artworkPreference,
    required this.onPlay,
    this.dimmed = false,
  });

  final Episode episode;
  final File? frame;
  final bool showPlay;
  final Color? ring;
  final WatchEntry? progress;
  final Download? download;
  final String artworkPreference;
  final VoidCallback onPlay;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final watched = progress?.watched ?? false;
    final still = EpisodePicture(
      episode: episode,
      width: EpisodeCard.width,
      frame: frame,
      preference: artworkPreference,
      watched: watched,
    );
    final mark = switch (download) {
      final d? when d.isDone => const DownloadMark.done(),
      final d? when d.isActive => DownloadMark.progress(d.progress.fraction),
      _ => null,
    };
    return SizedBox(
      height: EpisodeCard.stillHeight,
      // Outside the picture, so it reads at a glance over any still.
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Shape.art + EpisodeCard.ring),
          border: ring == null
              ? null
              : Border.all(
                  color: ring!,
                  width: EpisodeCard.ring,
                  strokeAlign: BorderSide.strokeAlignOutside,
                ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Shape.art),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Opacity(opacity: dimmed ? 0.4 : 1, child: still),
              if (showPlay)
                Center(
                  child: ExcludeFocus(
                    child: IconButton.filled(
                      onPressed: onPlay,
                      tooltip: 'Play episode ${episode.number}',
                      iconSize: 30,
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xEBFFFFFF),
                        foregroundColor: Colors.black,
                        fixedSize: const Size.square(56),
                      ),
                      icon: const Icon(Icons.play_arrow),
                    ),
                  ),
                ),
              if (mark != null)
                Positioned(
                  top: WatchStatus.badgeInset,
                  right: WatchStatus.badgeInset,
                  child: mark,
                ),
              // Watched is a full bar, not a check: the same mark as a
              // bar half way, read the same way.
              if ((progress?.bar ?? 0) > 0)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: LinearProgressIndicator(
                    value: progress!.bar,
                    minHeight: WatchStatus.barHeight,
                    color: WatchStatus.bar,
                    backgroundColor: WatchStatus.track,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An episode's still: metahub's, else a frame from the file on disk, else
/// its number. The title page's cards and the player's episode list and next
/// card all draw it.
class EpisodePicture extends StatelessWidget {
  const EpisodePicture({
    super.key,
    required this.episode,
    required this.width,
    required this.frame,
    required this.preference,
    required this.watched,
  });

  final Episode episode;
  final double width;

  /// From [EpisodeFrames], for an episode metahub has no still for.
  final File? frame;

  /// The "Episode stills" preference: show, blur (until watched) or hide.
  final String preference;
  final bool watched;

  @override
  Widget build(BuildContext context) {
    final noStill = _NoStill(number: episode.number, width: width);
    if (preference == 'hide') return noStill;
    final cacheWidth = (width * MediaQuery.devicePixelRatioOf(context) * 1.1)
        .round();
    // Only a real still is a spoiler; the placeholder has nothing to hide and
    // its episode number should stay readable. So the blur goes on the frame
    // the image decoded and nowhere else: a still that failed to load is
    // built by the error builder, outside the frame builder, and is not
    // blurred.
    final blur = preference == 'blur' && !watched;
    Widget picture(ImageProvider provider, Widget fallback) => Image(
      image: ResizeImage.resizeIfNeeded(cacheWidth, null, provider),
      fit: BoxFit.cover,
      frameBuilder: (_, child, frame, _) => frame == null
          ? const ColoredBox(color: Palette.surface)
          : blur
          ? ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: child,
            )
          : child,
      errorBuilder: (_, _, _) => fallback,
    );
    final fromFile = frame == null
        ? noStill
        : picture(FileImage(frame!), noStill);
    if (episode.thumbnail.isEmpty) return fromFile;
    return picture(ArtworkImage(episode.thumbnail), fromFile);
  }
}

/// No still to show: the number the picture would have been used for anyway,
/// on the ground. Not the title's artwork: a season of the same picture reads
/// as every card being the same episode.
class _NoStill extends StatelessWidget {
  const _NoStill({required this.number, required this.width});

  final int number;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Palette.surface,
      child: Center(
        child: Text(
          '$number',
          style: TextStyle(
            fontFamily: Typo.sans,
            fontSize: width * 0.11,
            fontWeight: FontWeight.w600,
            color: const Color(0x3DF3F5F9),
          ),
        ),
      ),
    );
  }
}
