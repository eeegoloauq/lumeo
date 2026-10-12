import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/widgets/artwork_image.dart';
import 'package:lumeo/ui/widgets/hero_logo.dart';

/// Builds a solid image of one colour, so the luminance rule can be tested
/// without a network and without shipping someone's artwork as a fixture.
Future<ui.Image> _swatch(int r, int g, int b, {int alpha = 255}) {
  const size = 16;
  final pixels = Uint8List(size * size * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
    pixels[i + 3] = alpha;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    size,
    size,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

void main() {
  test('a black title card is repainted, because it would vanish', () async {
    expect(await logoNeedsInk(await _swatch(5, 5, 5)), isTrue);
  });

  test('white lettering is left alone', () async {
    expect(await logoNeedsInk(await _swatch(235, 235, 235)), isFalse);
  });

  // The case that made the threshold what it is: dark, but its colours are
  // the design. Repainting this one white would be the worse bug.
  test('a dark but coloured mark keeps its colours', () async {
    expect(await logoNeedsInk(await _swatch(90, 40, 120)), isFalse);
  });

  test('transparent pixels are not part of the mark', () async {
    expect(await logoNeedsInk(await _swatch(0, 0, 0, alpha: 10)), isFalse);
  });

  testWidgets('the title is text in the logo\'s box until the logo comes', (
    tester,
  ) async {
    // The title stayed blank until the logo loaded or finally failed, which
    // on a slow line took longer than reading the page.
    const url = 'test://slow-logo';
    final logo = Completer<ImageInfo>();
    PaintingBinding.instance.imageCache.putIfAbsent(
      const ArtworkImage(url),
      () => OneFrameImageStreamCompleter(logo.future),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HeroLogo(url: url, title: 'Night of the Living Dead'),
        ),
      ),
    );
    final height = tester.getSize(find.byType(HeroLogo)).height;
    expect(find.text('Night of the Living Dead'), findsNothing);
    await tester.pump(HeroLogo.textAfter);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Night of the Living Dead'), findsOneWidget);
    expect(
      tester.getSize(find.byType(HeroLogo)).height,
      height,
      reason: 'nothing below moves',
    );

    final image = await tester.runAsync(() => _swatch(235, 235, 235));
    await tester.runAsync(() async {
      logo.complete(ImageInfo(image: image!));
      // The logo is measured off the frame before it is drawn.
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Night of the Living Dead'), findsNothing);
  });
}
