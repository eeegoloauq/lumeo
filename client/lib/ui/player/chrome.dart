import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../l10n/l10n.dart';
import '../widgets/download_glyph.dart';
import '../widgets/window_controls.dart';
import 'chapters.dart';
import 'menus.dart';
import 'thumbnails.dart';

class ChromeModel {
  const ChromeModel({
    required this.title,
    required this.download,
    required this.position,
    required this.duration,
    this.chapters = const [],
    required this.playing,
    required this.volume,
    required this.muted,
    required this.fullscreen,
    required this.subtitlesOn,
    required this.menu,
    this.episodeTitle = '',
    this.hasNext = false,
  });

  final String title;
  final String episodeTitle;
  final Download? download;
  final Duration position;
  final Duration duration;
  final List<MpvChapter> chapters;
  final bool playing;
  final double volume;
  final bool muted;
  final bool fullscreen;
  final bool subtitlesOn;
  final PlayerMenu menu;
  final bool hasNext;
}

enum PlayerMenu { none, tracks, settings, episodes, download }

const chromeBandInset = 16.0;
const chromeBottomBand = 76.0;
const chromeHideDelay = Duration(milliseconds: 500);
const _menuStyle = MenuStyle(
  backgroundColor: WidgetStatePropertyAll(Colors.transparent),
  elevation: WidgetStatePropertyAll(0),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
  shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
  side: WidgetStatePropertyAll(BorderSide.none),
);

class ChromeActions {
  const ChromeActions({
    required this.close,
    required this.togglePlay,
    required this.scrub,
    required this.seek,
    required this.setVolume,
    required this.toggleMute,
    required this.toggleFullscreen,
    required this.openMenu,
    required this.closeMenu,
    required this.hoverBar,
    this.startScrub,
    this.endScrub,
    this.nextEpisode,
    this.episodes,
  });

  final VoidCallback close;
  final VoidCallback togglePlay;
  final void Function(double) scrub;
  final void Function(Duration) seek;
  final VoidCallback? startScrub;
  final VoidCallback? endScrub;
  final VoidCallback? nextEpisode;
  final VoidCallback? episodes;
  final void Function(double) setVolume;
  final VoidCallback toggleMute;
  final VoidCallback toggleFullscreen;
  final void Function(PlayerMenu) openMenu;
  final VoidCallback closeMenu;
  final void Function(bool) hoverBar;
}

class PlayerChrome extends StatelessWidget {
  const PlayerChrome({
    super.key,
    required this.model,
    required this.actions,
    this.menu,
    this.episodesPanel,
    this.thumbnails,
  });

  final ChromeModel model;
  final ChromeActions actions;
  final Widget? menu;
  final Widget? episodesPanel;
  final Thumbnails? thumbnails;

  @override
  Widget build(BuildContext context) {
    final download = model.download;
    final chapter = chapterAt(model.chapters, model.position);
    return Stack(
      children: [
        const Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 72,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x8C000000), Colors.transparent],
                ),
              ),
              child: SizedBox.expand(),
            ),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 120,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0xB3000000), Colors.transparent],
                ),
              ),
              child: SizedBox.expand(),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: _Band(
            actions: actions,
            padding: const EdgeInsets.fromLTRB(24, 16, 14, 16),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  PlayerButton(
                    icon: Icons.arrow_back,
                    tooltip: context.l10n.playerBackEsc,
                    onPressed: actions.close,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          model.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            height: 1.25,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (model.episodeTitle.isNotEmpty)
                          Text(
                            model.episodeTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xB3FFFFFF),
                              fontSize: 13,
                              height: 1.25,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!model.fullscreen) ...[
                    const SizedBox(width: 16),
                    const WindowControls(),
                  ],
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _Band(
            actions: actions,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              children: [
                Scrubber(
                  position: model.position,
                  duration: model.duration,
                  chapters: model.chapters,
                  thumbnails: thumbnails,
                  acquired: download?.progress.fraction ?? 0,
                  onScrub: actions.scrub,
                  onSeek: actions.seek,
                  onStart: actions.startScrub,
                  onEnd: actions.endScrub,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      PlayerButton(
                        icon: model.playing ? Icons.pause : Icons.play_arrow,
                        tooltip: model.playing
                            ? context.l10n.playerPauseSpace
                            : context.l10n.playerPlaySpace,
                        onPressed: actions.togglePlay,
                      ),
                      if (model.hasNext && actions.nextEpisode != null)
                        PlayerButton(
                          icon: Icons.skip_next,
                          tooltip: context.l10n.playerNextEpisode,
                          onPressed: actions.nextEpisode!,
                        ),
                      VolumeControl(
                        volume: model.volume,
                        muted: model.muted,
                        onChanged: actions.setVolume,
                        onToggleMute: actions.toggleMute,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${clock(model.position)} / ${clock(model.duration)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      // One flexible child: a Flexible beside a Spacer split
                      // the space and pushed the right group to the middle.
                      Expanded(
                        child: chapter == null
                            ? const SizedBox()
                            : Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  '· ${chapterLabel(model.chapters, chapter, context.l10n)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xB3FFFFFF),
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                      ),
                      if (download != null)
                        MenuButton(
                          icon: Icons.download,
                          glyph: DownloadGlyph.of(download),
                          tooltip: download.isDone
                              ? context.l10n.playerOnDisk
                              : context.l10n.playerDownload,
                          which: PlayerMenu.download,
                          width: DownloadPanel.width,
                          model: model,
                          actions: actions,
                          panel: menu,
                        ),
                      MenuButton(
                        icon: model.subtitlesOn
                            ? Icons.closed_caption
                            : Icons.closed_caption_outlined,
                        tooltip: context.l10n.playerSubtitlesShortcut,
                        which: PlayerMenu.tracks,
                        width: TracksMenu.width,
                        model: model,
                        actions: actions,
                        panel: menu,
                      ),
                      MenuButton(
                        icon: Icons.settings,
                        tooltip: context.l10n.playerSettings,
                        which: PlayerMenu.settings,
                        width: 340,
                        model: model,
                        actions: actions,
                        panel: menu,
                      ),
                      if ((download?.episode ?? 0) > 0 &&
                          actions.episodes != null)
                        PlayerButton(
                          icon: Icons.playlist_play,
                          tooltip: context.l10n.playerEpisodes,
                          onPressed: actions.episodes!,
                        ),
                      PlayerButton(
                        icon: model.fullscreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        tooltip: model.fullscreen
                            ? context.l10n.playerExitFullscreen
                            : context.l10n.playerFullscreen,
                        onPressed: actions.toggleFullscreen,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (model.menu == PlayerMenu.episodes && episodesPanel != null)
          Positioned(
            right: 24,
            top: 24,
            bottom: chromeBottomBand,
            child: episodesPanel!,
          ),
      ],
    );
  }
}

class _Band extends StatelessWidget {
  const _Band({
    required this.actions,
    required this.padding,
    required this.child,
  });
  final ChromeActions actions;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => actions.hoverBar(true),
    onExit: (_) => actions.hoverBar(false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Padding(padding: padding, child: child),
    ),
  );
}

class PlayerButton extends StatelessWidget {
  const PlayerButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.glyph,
  });
  final IconData icon;

  /// Drawn in place of [icon] when the button shows a state, not a verb.
  final Widget? glyph;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    waitDuration: Duration.zero,
    child: IconButton(
      onPressed: onPressed,
      icon: glyph ?? Icon(icon, size: 24),
      color: Colors.white,
      iconSize: 24,
      style: IconButton.styleFrom(
        fixedSize: const Size(40, 40),
        minimumSize: const Size(40, 40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: Colors.transparent,
        hoverColor: const Color(0x14FFFFFF),
      ),
    ),
  );
}

class MenuButton extends StatefulWidget {
  const MenuButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.which,
    required this.width,
    required this.model,
    required this.actions,
    required this.panel,
    this.glyph,
  });
  final IconData icon;
  final Widget? glyph;
  final String tooltip;
  final PlayerMenu which;
  final double width;
  final ChromeModel model;
  final ChromeActions actions;
  final Widget? panel;

  @override
  State<MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<MenuButton> {
  final _controller = MenuController();
  bool get _open => widget.model.menu == widget.which;

  void _sync() {
    if (!mounted) return;
    if (_open && !_controller.isOpen) {
      openAtRightEdge(context, _controller, widget.width);
    }
    if (!_open && _controller.isOpen) _controller.close();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(MenuButton old) {
    super.didUpdateWidget(old);
    if (_open != (old.model.menu == old.which)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
    }
  }

  @override
  Widget build(BuildContext context) => MenuAnchor(
    controller: _controller,
    // A click on another bar button both closes this menu and opens its own;
    // the picture ignores the click that closes a menu (see _onPictureButtons).
    consumeOutsideTap: false,
    useRootOverlay: true,
    alignmentOffset: const Offset(0, 24),
    style: _menuStyle,
    onClose: () {
      if (_open) widget.actions.closeMenu();
    },
    menuChildren: [
      if (_open && widget.panel != null)
        SizedBox(
          width: widget.width,
          child: Align(
            alignment: Alignment.centerRight,
            heightFactor: 1,
            child: widget.panel!,
          ),
        ),
    ],
    builder: (_, _, _) => PlayerButton(
      icon: widget.icon,
      glyph: widget.glyph,
      tooltip: widget.tooltip,
      onPressed: () => widget.actions.openMenu(widget.which),
    ),
  );
}

/// Every panel ends 24 px from the window's right edge, whichever button it
/// hangs from; MenuAnchor flips it above the bar.
void openAtRightEdge(
  BuildContext anchor,
  MenuController controller,
  double width,
) {
  final box = anchor.findRenderObject()! as RenderBox;
  final left = box.localToGlobal(Offset.zero).dx;
  controller.open(
    position: Offset(
      MediaQuery.sizeOf(anchor).width - 24 - width - left,
      box.size.height + 24,
    ),
  );
}

String clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

class Scrubber extends StatefulWidget {
  const Scrubber({
    super.key,
    required this.position,
    required this.duration,
    this.chapters = const [],
    this.thumbnails,
    required this.acquired,
    required this.onScrub,
    required this.onSeek,
    this.onStart,
    this.onEnd,
  });
  final Duration position;
  final Duration duration;
  final List<MpvChapter> chapters;
  final Thumbnails? thumbnails;
  final double acquired;
  final void Function(double) onScrub;
  final void Function(Duration) onSeek;
  final VoidCallback? onStart;
  final VoidCallback? onEnd;

  @override
  State<Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<Scrubber> {
  double? _dragging;
  double? _hover;

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds.toDouble();
    final playable = total > 0;
    final value =
        _dragging ??
        (playable
            ? (widget.position.inMilliseconds / total).clamp(0.0, 1.0)
            : 0.0);
    Duration at(double fraction) =>
        Duration(milliseconds: (total * fraction).round());
    final marks = [
      for (final c in widget.chapters)
        if (playable && c.time > Duration.zero && c.time < widget.duration)
          c.time.inMilliseconds / total,
    ];
    final pointed = _dragging ?? _hover;
    final chapter = pointed == null
        ? null
        : chapterAt(widget.chapters, at(pointed));
    return SizedBox(
      height: 16,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              padding: EdgeInsets.zero,
              trackShape: _ChapteredTrackShape(marks),
              activeTrackColor: Colors.white,
              secondaryActiveTrackColor: const Color(0x73FFFFFF),
              inactiveTrackColor: const Color(0x40FFFFFF),
              thumbColor: Colors.white,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayColor: const Color(0x33FFFFFF),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
            ),
            child: MouseRegion(
              onHover: (event) {
                final width = context.size?.width ?? 0;
                if (width > 0) {
                  final hover = (event.localPosition.dx / width).clamp(
                    0.0,
                    1.0,
                  );
                  setState(() => _hover = hover);
                  if (playable) widget.thumbnails?.show(at(hover));
                }
              },
              onExit: (_) {
                setState(() => _hover = null);
                widget.thumbnails?.hide();
              },
              child: Slider(
                value: value,
                secondaryTrackValue: widget.acquired.clamp(0, 1),
                onChangeStart: playable
                    ? (_) {
                        widget.onStart?.call();
                      }
                    : null,
                onChanged: playable
                    ? (v) {
                        setState(() => _dragging = v);
                        widget.onScrub(v);
                        widget.thumbnails?.show(at(v));
                      }
                    : null,
                onChangeEnd: playable
                    ? (v) {
                        setState(() {
                          _dragging = null;
                          _hover = v;
                        });
                        widget.onSeek(at(v));
                        widget.onEnd?.call();
                      }
                    : null,
              ),
            ),
          ),
          if (playable && pointed != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 22,
              height: 400,
              child: IgnorePointer(
                child: CustomSingleChildLayout(
                  delegate: _OverPointer(pointed),
                  child: _Preview(
                    frame: widget.thumbnails?.frame,
                    chapter: chapter == null
                        ? null
                        : chapterLabel(widget.chapters, chapter, context.l10n),
                    time: clock(at(pointed)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Centred over the pointer, and stopped at the ends of the bar.
class _OverPointer extends SingleChildLayoutDelegate {
  const _OverPointer(this.fraction);
  final double fraction;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    (size.width * fraction - childSize.width / 2).clamp(
      0,
      math.max(0, size.width - childSize.width),
    ),
    size.height - childSize.height,
  );

  @override
  bool shouldRelayout(_OverPointer old) => old.fraction != fraction;
}

/// The frame under the pointer when there is one, the chapter when the file
/// has chapters, and the time.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.frame,
    required this.chapter,
    required this.time,
  });
  final ValueNotifier<ui.Image?>? frame;
  final String? chapter;
  final String time;

  static const _shadow = [Shadow(blurRadius: 3, color: Color(0xE6000000))];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Never wider than the bar, the frame's border included.
      final width = math.min(
        (constraints.maxWidth * 0.18).clamp(160.0, 320.0),
        math.max(0.0, constraints.maxWidth - 4),
      );
      Widget content(ui.Image? image) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (image != null)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: RawImage(
                  image: image,
                  width: width,
                  height: math.min(width, width * image.height / image.width),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          if (chapter != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: Text(
                chapter!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  shadows: _shadow,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Glass(
            radius: 11,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                time,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ],
      );
      final frame = this.frame;
      return frame == null
          ? content(null)
          : ValueListenableBuilder<ui.Image?>(
              valueListenable: frame,
              builder: (context, image, _) => content(image),
            );
    },
  );
}

// Slider's track shape is the only place with the exact track bounds.
class _ChapteredTrackShape extends RectangularSliderTrackShape {
  const _ChapteredTrackShape(this.marks);
  final List<double> marks;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
      textDirection: textDirection,
    );
    if (marks.isEmpty) return;
    final track = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final paint = Paint()..color = Colors.black;
    for (final mark in marks) {
      final x = textDirection == TextDirection.ltr
          ? track.left + track.width * mark
          : track.right - track.width * mark;
      context.canvas.drawRect(
        Rect.fromLTRB(x - 1, track.top, x + 1, track.bottom),
        paint,
      );
    }
  }
}

class VolumeControl extends StatefulWidget {
  const VolumeControl({
    super.key,
    required this.volume,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
  });
  static const max = 150.0;
  final double volume;
  final bool muted;
  final void Function(double) onChanged;
  final VoidCallback onToggleMute;

  @override
  State<VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<VolumeControl> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final shown = widget.muted ? 0.0 : widget.volume;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Row(
        children: [
          PlayerButton(
            icon: shown == 0
                ? Icons.volume_off
                : shown < 60
                ? Icons.volume_down
                : Icons.volume_up,
            tooltip: widget.muted
                ? context.l10n.playerUnmute
                : context.l10n.playerMute,
            onPressed: widget.onToggleMute,
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: _hover ? 76 : 0,
            child: _hover
                ? SliderTheme(
                    // Material's default padding left a 64 px slider no track.
                    data: const SliderThemeData(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      trackHeight: 3,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Color(0x40FFFFFF),
                      thumbColor: Colors.white,
                      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: shown.clamp(0, VolumeControl.max),
                      max: VolumeControl.max,
                      onChanged: widget.onChanged,
                    ),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
