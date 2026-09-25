import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme.dart';
import 'artwork_image.dart';

/// The title card the provider drew, made visible on our ground.
///
/// Logo artwork is usually white lettering on transparency, but not always:
/// some titles ship a dark logo drawn for a light poster, and on a dark hero
/// it disappears entirely. So the artwork is measured once — mean luminance
/// over the pixels that are actually opaque — and a dark logo is filled white
/// rather than dropped. Its shape is the design; only the ink changes.
class HeroLogo extends StatefulWidget {
  const HeroLogo({
    super.key,
    required this.url,
    required this.title,
    this.height = 132,
  });

  final String url;
  final String title;
  final double height;

  @override
  State<HeroLogo> createState() => _HeroLogoState();
}

/// Whether a logo is dark enough that it would vanish on our ground and has
/// nothing to lose by being repainted white.
///
/// Measured against real Cinemeta artwork: a black mark lands near 0.02, a
/// dark but coloured one — Masters of the Universe, say — sits at 0.28 and
/// must keep its colours, and ordinary white lettering is above 0.6. The line
/// is drawn well below the coloured case on purpose.
Future<bool> logoNeedsInk(ui.Image image) async {
  // Straight, not premultiplied: with premultiplied bytes every softened edge
  // pixel reads darker than it is and drags the average down.
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  if (data == null) return false;
  final bytes = data.buffer.asUint8List();
  var sum = 0.0;
  var counted = 0;
  // Every eighth pixel is plenty to tell white lettering from black.
  for (var i = 0; i + 3 < bytes.length; i += 32) {
    if (bytes[i + 3] < 128) continue; // edge or transparent: not the mark
    sum += 0.2126 * bytes[i] + 0.7152 * bytes[i + 1] + 0.0722 * bytes[i + 2];
    counted++;
  }
  if (counted == 0) return false;
  return sum / counted / 255 < darkLogoThreshold;
}

const darkLogoThreshold = 0.18;

class _HeroLogoState extends State<HeroLogo> {
  /// Measured once per logo for the life of the process: the verdict cannot
  /// change while the artwork does not.
  static final Map<String, bool> _tint = {};

  bool? _needsTint;
  bool _failed = false;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _inspect();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  void _inspect() {
    final known = _tint[widget.url];
    if (known != null) {
      _needsTint = known;
      return;
    }
    _stream = ArtworkImage(widget.url).resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener(
      (info, _) async {
        final dark = await logoNeedsInk(info.image);
        _tint[widget.url] = dark;
        // Done with the stream the moment the verdict exists: the listener is
        // what holds the full-size decode alive, and the measurement is the
        // only thing that ever wanted it. The Image below draws from
        // the cache, which is a separate matter.
        _release();
        if (mounted) setState(() => _needsTint = dark);
      },
      onError: (_, _) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _stream!.addListener(_listener!);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return Text(widget.title, style: Typo.heroTitle);
    if (_needsTint == null) {
      // Hold the space rather than flash a dark logo and repaint it white.
      return SizedBox(height: widget.height);
    }
    final image = Image(
      image: ArtworkImage(widget.url),
      height: widget.height,
      alignment: Alignment.centerLeft,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => Text(widget.title, style: Typo.heroTitle),
    );
    if (!_needsTint!) return image;
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
      child: image,
    );
  }
}
