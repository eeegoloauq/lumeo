import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import 'artwork_image.dart';

/// The washes that turn a frame we do not control into a page: a horizontal
/// one gives the type a ground, a light one on the right dims the frame's
/// brightest half, and a vertical one hands the page an edge. Both banners
/// draw this one.
///
/// The vertical wash is a smoothstep, because a linear ramp's knee reads as
/// a line on black. It reaches the page's colour at the banner's own edge,
/// under the first shelf.
///
/// Eight bits cannot express a fall this long on black, so the wash carries
/// a grain of one part in forty that turns the bands into texture. It is
/// additive, and only where the bands are, so solid black stays black.
///
/// One fragment shader (`shaders/scrim.frag`) in a single pass: stacked
/// gradients and a grain layer stuttered scrolling on laptop GPUs.
class ArtworkScrim extends StatefulWidget {
  const ArtworkScrim({super.key});

  @override
  State<ArtworkScrim> createState() => _ArtworkScrimState();
}

class _ArtworkScrimState extends State<ArtworkScrim> {
  static ui.FragmentProgram? _program;
  static Future<ui.FragmentProgram>? _loading;

  @override
  void initState() {
    super.initState();
    if (_program == null) {
      (_loading ??= ui.FragmentProgram.fromAsset('shaders/scrim.frag')).then((
        program,
      ) {
        _program = program;
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final program = _program;
    if (program == null) return const SizedBox.shrink();
    return CustomPaint(
      painter: _ScrimPainter(program.fragmentShader()),
      size: Size.infinite,
    );
  }
}

class _ScrimPainter extends CustomPainter {
  _ScrimPainter(this.shader);

  final ui.FragmentShader shader;

  @override
  void paint(Canvas canvas, Size size) {
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, Palette.page.r)
      ..setFloat(3, Palette.page.g)
      ..setFloat(4, Palette.page.b);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_ScrimPainter old) => false;
}

/// How tall a banner is: what the screen has left above the block that must
/// stay visible under it, each part measured from the widget that draws it.
/// Only a floor and a ceiling are chosen. A page with nothing under the
/// banner (a film) ignores the ceiling: the artwork is the window.
///
/// Rounded to whole device pixels: a height inside a pixel antialiases that
/// row and the scrim's, and the picture shows through as a line where the
/// banner ends.
class BannerMetrics {
  const BannerMetrics._();

  static const floor = 420.0;

  /// Past this the artwork becomes the page, which only a film's page may.
  static const ceiling = 720.0;

  /// [screen] is the scroll viewport, not the window.
  static double height(
    BuildContext context, {
    required double screen,
    required double reveal,
  }) {
    final raw = reveal <= 0
        ? math.max(screen, floor)
        : (screen - reveal).clamp(floor, ceiling);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return (raw * ratio).roundToDouble() / ratio;
  }
}

/// A banner's box: [height] tall, or taller when what it holds needs more,
/// so a short window scrolls rather than pushing the controls out. Whole
/// device pixels either way (see [BannerMetrics]).
class BannerBox extends StatelessWidget {
  const BannerBox({
    super.key,
    required this.height,
    required this.background,
    required this.child,
  });

  final double height;

  /// Drawn over the whole box, under [child].
  final List<Widget> background;

  /// Sits at the bottom of the box.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _WholePixels(
      ratio: MediaQuery.devicePixelRatioOf(context),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Stack(
          alignment: AlignmentDirectional.bottomStart,
          children: [
            // Its own layer, so scrolling the page or hovering the shelf that
            // lies over the banner does not record the artwork and scrim again.
            Positioned.fill(
              child: RepaintBoundary(
                child: Stack(fit: StackFit.expand, children: background),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

/// Rounds its child's height up to whole device pixels.
class _WholePixels extends SingleChildRenderObjectWidget {
  const _WholePixels({required this.ratio, required super.child});

  final double ratio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWholePixels(ratio);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderWholePixels renderObject,
  ) {
    renderObject.ratio = ratio;
  }
}

class _RenderWholePixels extends RenderProxyBox {
  _RenderWholePixels(this._ratio);

  double _ratio;
  set ratio(double value) {
    if (value == _ratio) return;
    _ratio = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    // Less a hair, so a height already on a pixel stays there.
    final whole = (child.size.height * _ratio - 1e-6).ceilToDouble() / _ratio;
    if (whole != child.size.height) {
      child.layout(constraints.tighten(height: whole), parentUsesSize: true);
    }
    size = child.size;
  }
}

/// The artwork behind a banner, decoded at the size it is drawn: a 4K still
/// at full size is a hundred megabytes.
class BannerArtwork extends StatelessWidget {
  const BannerArtwork({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const ColoredBox(color: Palette.surface);
    return Image(
      image: ResizeImage.resizeIfNeeded(
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round(),
        null,
        ArtworkImage(url),
      ),
      fit: BoxFit.cover,
      alignment: Alignment.topCenter,
      errorBuilder: (_, _, _) => const ColoredBox(color: Palette.surface),
    );
  }
}
