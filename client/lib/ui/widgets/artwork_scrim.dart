import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import 'artwork_image.dart';

/// The washes that turn a frame we do not control into a page.
///
/// One horizontal, which gives the type a ground to sit on; a light one on
/// the right, because the frame is brightest where nothing has darkened it and
/// a bright half that ends is more of an edge than a dim half that ends; one
/// vertical, which hands the page an edge to start from. The home banner and
/// the title banner both draw this one, so they cannot drift apart again.
///
/// The vertical wash is a smoothstep, not a straight line. A linear ramp to
/// opaque has a knee where the alpha stops climbing, and on black the eye reads
/// that corner as a line across the picture. It starts falling at about half
/// the banner and reaches the page's colour at the banner's own edge, where the
/// first shelf already overlaps it: a ramp that finished short left a flat
/// black band with the picture stopping above it, which read as a cut.
///
/// Eight bits per channel cannot express a fall this long on black, so the
/// wash carries a grain of one part in forty: noise pushes each band's edge
/// above or below the threshold at random, and an eye that was reading a step
/// reads a texture instead. It is additive, so it can only lift a value, and it
/// lives only in the stretch where the bands are — over solid page colour it
/// lifted black into a faintly lighter rectangle ending at the banner's edge.
///
/// All of it is one fragment shader (`shaders/scrim.frag`), drawn in a single
/// pass. As stacked gradients and a masked grain layer it was four full-banner
/// draws and an offscreen pass each frame, which stuttered scrolling on laptop
/// GPUs.
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

/// How tall a banner is.
///
/// Not a share of the window. A fraction picked by eye is a number that
/// happens to look right on the screen it was picked on, and the promise this
/// page makes is not about a fraction — it is that opening a title lands you
/// on something to choose from rather than on a poster and a scrollbar. So the
/// banner is what the screen has left over above the block that has to stay
/// visible under it, and every number in that block belongs to the widget that
/// draws it: change the episode card and the banner follows without anyone
/// editing this.
///
/// Two numbers are still chosen, and they are the two that cannot be derived
/// from anything: a floor, below which a banner stops being a picture, and a
/// ceiling, above which the page it heads becomes a screen with nothing on it
/// to pick. Every hero in every design system has both.
///
/// A page with nothing under the banner is the exception to the ceiling. A
/// film has no strip to show, so there is nothing for a shorter banner to
/// reveal — only page under the picture, and a band of page under a picture
/// that stopped is the one thing this arithmetic exists to avoid. The
/// artwork is the window, and the source table, when it is asked for, is the
/// thing the page scrolls to.
///
/// The result is rounded to whole device pixels. A height that lands inside a
/// physical pixel is drawn with that row antialiased, and the scrim over the
/// artwork gets the same treatment: both end up a little short of opaque, and
/// what shows through the gap is the picture — one warm line straight across
/// the page, exactly where the banner ends. That is the seam this class
/// exists to make impossible; the gradient's stops, twice suspected, never
/// had anything to do with it.
class BannerMetrics {
  const BannerMetrics._();

  static const floor = 420.0;

  /// Past this the artwork stops being the head of a page and becomes the
  /// page — which is what a film's page is meant to be, and what a page with
  /// a list under it must not become.
  static const ceiling = 720.0;

  /// [screen] is the scroll viewport, not the window — they are the same today
  /// and stop being the same the first time anything else shares the page.
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

/// A banner's box: [height] tall, or taller when what it holds needs more.
///
/// A fixed height let a short window push the text and buttons out of the
/// bottom of the banner and over the row under it. The page scrolls, so a
/// banner that grows costs a scroll, not a control. It stays a whole number of
/// device pixels whichever height wins, for the seam [BannerMetrics] is about.
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
              child: RepaintBoundary(child: Stack(children: background)),
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

/// The artwork behind a banner, at the size it will actually be drawn.
///
/// Both banners loaded it the same way and both wrote the same cacheWidth
/// arithmetic; a full-size decode of a 4K still is a hundred megabytes held
/// for a picture shown at a fraction of it.
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
