import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme.dart';
import 'artwork_image.dart';

/// The two washes that turn a frame we do not control into a page.
///
/// One horizontal, which gives the type a ground to sit on; one vertical,
/// which hands the page an edge to start from. They were written out twice —
/// once in the home banner, once in the title banner — and drifted apart by a
/// stop each, which is how the title page ended up with a visible line across
/// it: the vertical wash was still a fifth transparent where the artwork
/// stopped, so the picture did not fade out, it was cut off.
///
/// The ramp therefore ends well before the edge. Whatever the last band of a
/// banner is, it is the page's colour and nothing else.
class ArtworkScrim extends StatelessWidget {
  const ArtworkScrim({super.key});

  /// Where the vertical wash becomes the page and stays it.
  ///
  /// It was 0.86, and that was the cut. The ramp finished a seventh of the
  /// banner short of the bottom, so the last band was not a picture fading
  /// out — it was a flat black field with a picture stopping above it, and the
  /// eye reads the line between "still the frame" and "already the page"
  /// however smooth the ramp above it was. Now the wash arrives at the page's
  /// colour at the banner's own edge, and the edge is where the first shelf
  /// already overlaps it.
  static const _solidFrom = 0.995;

  /// Where it starts falling. Roughly half the banner, which is what a hero
  /// gets in every interface that does this well: a fall short enough to see
  /// begin is a fall you can see end.
  static const _fallFrom = 0.45;

  /// The vertical wash, as a curve rather than a straight line.
  ///
  /// A linear ramp to opaque has a knee in it: the alpha climbs at a constant
  /// rate and then simply stops, and the eye reads that corner as an edge —
  /// which on a blue-black ground was lost in the ground and on black is a
  /// line across the picture. These stops are a smoothstep, so the wash
  /// arrives at the page's colour asymptotically and there is no moment where
  /// it changes its mind.
  ///
  /// It is also why there are nine of them and not four. Between two stops the
  /// engine interpolates in eight-bit steps, and over four hundred points of
  /// screen that is a visible stair; more stops put each stair inside a
  /// shorter run. The rest of the stair is taken out by the grain below.
  static List<Color> _fall() => [
    Palette.ground(0.50),
    Palette.ground(0),
    for (var i = 0; i <= 10; i++) Palette.ground(_smoothstep(i / 10)),
    Palette.ground(1),
  ];

  static List<double> _fallStops() => [
    0,
    0.26,
    for (var i = 0; i <= 10; i++)
      _fallFrom + (_solidFrom - _fallFrom) * (i / 10),
    1,
  ];

  /// 3t² − 2t³: flat at both ends, steepest in the middle.
  static double _smoothstep(double t) => t * t * (3 - 2 * t);

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerRight,
              end: Alignment.centerLeft,
              colors: [
                Palette.ground(0),
                Palette.ground(0.70),
                Palette.ground(0.94),
              ],
              stops: const [0.42, 0.72, 1],
            ),
          ),
        ),
        // The right-hand edge, lightly. Not a mirror of the wash on the left:
        // that one exists so type can be read over it and is heavy enough to
        // say so. This one exists because the frame is brightest where nothing
        // has darkened it, and a bright half that ends is more of an edge than
        // a dim half that ends.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Palette.ground(0), Palette.ground(0.34)],
              stops: const [0.72, 1],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: _fall(),
              stops: _fallStops(),
            ),
          ),
        ),
        const _Grain(),
      ],
    );
  }
}

/// A film grain of one part in forty, laid over the wash.
///
/// Eight bits per channel cannot express a gradient this long: between two
/// values there is nowhere to go, so the engine draws bands, and on black —
/// where the last stretch of the ramp lives in the darkest few values — the
/// bands are wide enough to count. Every industry that fades to black solves
/// this the same way and has since film: put noise over it. A pixel of noise
/// pushes each band's edge above or below the threshold at random, and an eye
/// that was reading a step reads a texture instead.
///
/// One part in forty is below the threshold of "there is something on this
/// picture" and above the threshold of "these are bands". It is drawn additive
/// so it can only lift a value, never dig a hole in the artwork.
///
/// And it is masked to the stretch of the banner where the bands actually
/// are. Laid over the whole rectangle it did the opposite of its job: additive
/// noise over a part of the picture that is already solid page colour lifts
/// black by a couple of values, which is a faintly lighter rectangle ending
/// exactly at the banner's bottom edge — a seam drawn by the very thing put
/// there to remove one.
class _Grain extends StatefulWidget {
  const _Grain();

  @override
  State<_Grain> createState() => _GrainState();
}

class _GrainState extends State<_Grain> {
  /// One tile for the whole application: it is 128 by 128 and every banner in
  /// the process repeats the same one.
  static ui.Image? _tile;
  static Future<ui.Image>? _loading;

  @override
  void initState() {
    super.initState();
    if (_tile == null) {
      (_loading ??= _make()).then((image) {
        _tile = image;
        if (mounted) setState(() {});
      });
    }
  }

  static Future<ui.Image> _make() {
    const side = 128;
    // Seeded, so the grain is the same on every run and a screenshot that
    // differs from the last one differs for a reason.
    final random = math.Random(20260903);
    final pixels = Uint8List(side * side * 4);
    for (var i = 0; i < side * side; i++) {
      final v = random.nextInt(256);
      pixels[i * 4] = v;
      pixels[i * 4 + 1] = v;
      pixels[i * 4 + 2] = v;
      pixels[i * 4 + 3] = 255;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      side,
      side,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  @override
  Widget build(BuildContext context) {
    final tile = _tile;
    if (tile == null) return const SizedBox.shrink();
    return CustomPaint(painter: _GrainPainter(tile), size: Size.infinite);
  }
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter(this.tile);

  final ui.Image tile;

  /// One part in forty.
  static const _strength = 0.025;

  /// Where the noise lives: nothing at the top, where the picture is itself
  /// and needs no help; full through the fall, where the bands are; nothing
  /// again at the foot, where there is only page.
  static const _maskStops = [0.30, 0.50, 0.92, 1.0];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // The layer is what makes the whole thing additive once, rather than each
    // draw inside it fighting the one before.
    canvas.saveLayer(rect, Paint()..blendMode = BlendMode.plus);
    canvas.drawRect(
      rect,
      Paint()
        ..colorFilter = const ColorFilter.mode(
          Color.fromRGBO(255, 255, 255, _strength),
          BlendMode.modulate,
        )
        ..shader = ImageShader(
          tile,
          TileMode.repeated,
          TileMode.repeated,
          Matrix4.identity().storage,
        ),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00FFFFFF),
            Color(0xFFFFFFFF),
            Color(0xFFFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: _maskStops,
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GrainPainter old) => old.tile != tile;
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
            for (final layer in background) Positioned.fill(child: layer),
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
