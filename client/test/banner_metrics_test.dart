// The banner's height, which is arithmetic with a visible failure mode.
//
// A fraction of the window height is almost never a whole device pixel, and a
// box whose bottom edge falls inside a pixel is drawn with that row
// antialiased — the artwork under the scrim shows through it as one warm line
// across the page. It shipped twice, and the second attempt at fixing it moved
// the gradient's stops, which was never where the problem was.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/ui/widgets/artwork_scrim.dart';

void main() {
  testWidgets('a banner is a whole number of device pixels tall', (
    tester,
  ) async {
    // 375 is a plausible block under a banner — a season row, a line of
    // synopsis and a card — and the number does not matter here: what matters
    // is that whatever comes out of the subtraction lands on a pixel.
    // Window heights that are ordinary rather than convenient: a maximised
    // 1080p window minus a panel, a laptop screen, the default window.
    for (final height in [900.0, 1000.0, 1047.0, 1053.0, 1080.0, 1440.0]) {
      for (final ratio in [1.0, 1.25, 1.5, 1.75, 2.0]) {
        late double banner;
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(
              size: Size(1920, height),
              devicePixelRatio: ratio,
            ),
            child: Builder(
              builder: (context) {
                banner = BannerMetrics.height(
                  context,
                  screen: height,
                  reveal: 375,
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        final pixels = banner * ratio;
        expect(
          pixels,
          closeTo(pixels.roundToDouble(), 1e-9),
          reason:
              'window $height at $ratio: the banner ends mid-pixel, which '
              'is the seam across the page',
        );
      }
    }
  });

  testWidgets('a banner with nothing under it is the whole viewport', (
    tester,
  ) async {
    // A film reveals nothing, so its banner is not headed by a ceiling: the
    // picture is the window, whatever the window's height.
    for (final height in [820.0, 900.0, 1200.0, 1440.0]) {
      late double banner;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: Size(1920, height)),
          child: Builder(
            builder: (context) {
              banner = BannerMetrics.height(context, screen: height, reveal: 0);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(
        banner,
        height,
        reason:
            'window $height: a band of page under a '
            'film\'s picture is the seam the height exists to avoid',
      );
    }
  });

  testWidgets('a banner leaves the block under it on screen', (tester) async {
    // The promise the height exists for, checked at sizes nobody tuned it on.
    // A share of the window kept that promise only near the window the share
    // was picked on: at 62% a 900-tall screen put the episode strip a hundred
    // points below the fold.
    const reveal = 375.0;
    for (final height in [820.0, 900.0, 1047.0, 1200.0, 1440.0]) {
      late double banner;
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: Size(1920, height)),
          child: Builder(
            builder: (context) {
              banner = BannerMetrics.height(
                context,
                screen: height,
                reveal: reveal,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(
        banner + reveal,
        lessThanOrEqualTo(height),
        reason: 'window $height: the block under the banner is off screen',
      );
    }
  });

  testWidgets('a banner grows to hold what is in it, on whole pixels', (
    tester,
  ) async {
    // A short window: the height the viewport leaves is less than a title,
    // a synopsis and the buttons take. A banner of that fixed height pushed
    // them out of its bottom and over the row under it.
    const content = 333.3;
    for (final ratio in [1.0, 1.25, 1.5]) {
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(
            size: const Size(800, 560),
            devicePixelRatio: ratio,
          ),
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  BannerBox(
                    height: 200,
                    background: [ColoredBox(color: Color(0xFF000000))],
                    child: SizedBox(key: Key('content'), height: content),
                  ),
                  SizedBox(key: Key('below'), height: 50),
                ],
              ),
            ),
          ),
        ),
      );
      final banner = tester.getSize(find.byType(BannerBox)).height;
      expect(banner, greaterThanOrEqualTo(content));
      expect(
        banner * ratio,
        closeTo((banner * ratio).roundToDouble(), 1e-9),
        reason: 'at $ratio the grown banner ends mid-pixel',
      );
      expect(
        tester.getBottomLeft(find.byKey(const Key('content'))).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byKey(const Key('below'))).dy),
        reason: 'what the banner holds reaches into the row under it',
      );
    }
  });

  testWidgets('a banner with room to spare keeps its height', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: SingleChildScrollView(
          child: BannerBox(
            height: 420,
            background: [],
            child: SizedBox(height: 100),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(BannerBox)).height, 420);
  });
}
