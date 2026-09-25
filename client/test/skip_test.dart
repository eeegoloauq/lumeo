import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumeo/api/models.dart';
import 'package:lumeo/ui/player/chapters.dart';
import 'package:lumeo/ui/player/chrome.dart';
import 'package:lumeo/ui/player/panels.dart';
import 'package:lumeo/ui/player/skip.dart';
import 'package:lumeo/ui/theme.dart';

void main() {
  group('which chapter is the opening and which the ending', () {
    test('the names releases actually use, in any case', () {
      for (final title in ['OP', 'Opening', 'opening', 'Intro', 'NCOP']) {
        final chapters = [
          const MpvChapter(time: Duration.zero, title: 'Cold open'),
          MpvChapter(time: const Duration(minutes: 2), title: title),
        ];
        expect(openingChapter(chapters), 1, reason: title);
      }
      for (final title in ['ED', 'Ending', 'credits', 'Preview', 'NCED']) {
        final chapters = [
          const MpvChapter(time: Duration.zero, title: 'Part A'),
          MpvChapter(time: const Duration(minutes: 20), title: title),
        ];
        expect(endingChapter(chapters), 1, reason: title);
      }
    });

    test('the song, not the cold open in front of it', () {
      // How a real release marks it: the scene before the song is "Intro".
      const chapters = [
        MpvChapter(time: Duration.zero, title: 'Intro'),
        MpvChapter(time: Duration(seconds: 87), title: 'OP'),
        MpvChapter(time: Duration(seconds: 178), title: 'Part A'),
      ];
      expect(openingChapter(chapters), 1);
      expect(
        openingChapter(const [
          MpvChapter(time: Duration.zero, title: 'Avant'),
          MpvChapter(time: Duration(seconds: 90), title: 'Part A'),
        ]),
        isNull,
      );
    });

    test('a word, not a prefix', () {
      // The two that a bare startsWith gets wrong, and they are wrong in the
      // worst way: one skips the first minutes of an episode, the other ends
      // it early.
      expect(
        openingChapter(const [
          MpvChapter(time: Duration.zero, title: 'Operation Mindcrime'),
        ]),
        isNull,
      );
      expect(
        endingChapter(const [
          MpvChapter(time: Duration.zero, title: 'Special Edition'),
        ]),
        isNull,
      );
      expect(openingChapter(const []), isNull);
      expect(
        endingChapter(const [MpvChapter(time: Duration.zero, title: 'Part B')]),
        isNull,
      );
    });

    test('a run of candidates is one ending, taken from its start', () {
      const chapters = [
        MpvChapter(time: Duration.zero, title: 'Part B'),
        MpvChapter(time: Duration(minutes: 21), title: 'Ending'),
        MpvChapter(time: Duration(minutes: 22, seconds: 30), title: 'Preview'),
      ];
      expect(endingChapter(chapters), 1);
    });

    test('a chapter that is also an opening is not the ending', () {
      // "Opening Credits" carries both words, and read as an ending it puts
      // the interval from the first chapter to the end of the file — a Next
      // button over the whole episode, slowly filling.
      const chapters = [
        MpvChapter(time: Duration.zero, title: 'Opening Credits'),
        MpvChapter(time: Duration(minutes: 2), title: 'Part A'),
        MpvChapter(time: Duration(minutes: 21), title: 'End Credits'),
      ];
      expect(openingChapter(chapters), 0);
      expect(endingChapter(chapters), 2);
    });

    test('an episode does not open with its own ending', () {
      // A western release calls the recap at the front "Previously" or
      // "Preview", and the first chapter of a file is never the credits.
      const chapters = [
        MpvChapter(time: Duration.zero, title: 'Preview'),
        MpvChapter(time: Duration(minutes: 2), title: 'Part A'),
      ];
      expect(endingChapter(chapters), isNull);
      // Nor anything at or before the opening, when a file names one.
      const withOpening = [
        MpvChapter(time: Duration.zero, title: 'Preview'),
        MpvChapter(time: Duration(minutes: 1), title: 'OP'),
        MpvChapter(time: Duration(minutes: 3), title: 'Part A'),
      ];
      expect(endingChapter(withOpening), isNull);
    });
  });

  group('what the button is offering', () {
    const opening = [
      MpvChapter(time: Duration.zero, title: 'Teaser'),
      MpvChapter(time: Duration(seconds: 100), title: 'Opening'),
      MpvChapter(time: Duration(seconds: 200), title: 'Part A'),
      MpvChapter(time: Duration(seconds: 1300), title: 'Ending'),
    ];
    const duration = Duration(seconds: 1400);

    SkipMoment? at(
      Duration position, {
      List<MpvChapter> chapters = opening,
      Duration length = duration,
      bool hasNext = true,
    }) => skipMoment(
      chapters: chapters,
      position: position,
      duration: length,
      hasNext: hasNext,
    );

    test('inside the opening: how far through it, and where a press lands', () {
      final moment = at(const Duration(seconds: 150));
      expect(moment?.action, SkipAction.intro);
      expect(moment?.fill, closeTo(0.5, 0.001));
      expect(moment?.target, const Duration(seconds: 200));
    });

    test(
      'the opening ends with the chapter, and comes back on a seek back to it',
      () {
        expect(at(const Duration(seconds: 99))?.action, isNull);
        expect(at(const Duration(seconds: 100))?.fill, 0);
        // The frame the next chapter starts on belongs to the episode.
        expect(
          at(const Duration(seconds: 200))?.action,
          isNot(SkipAction.intro),
        );
        expect(at(const Duration(seconds: 101))?.action, SkipAction.intro);
      },
    );

    test('an opening with nothing after it runs to the end of the file', () {
      const chapters = [
        MpvChapter(time: Duration.zero, title: 'Part A'),
        MpvChapter(time: Duration(seconds: 1300), title: 'OP'),
      ];
      final moment = at(const Duration(seconds: 1350), chapters: chapters);
      expect(moment?.action, SkipAction.intro);
      expect(moment?.target, duration);
      expect(moment?.fill, closeTo(0.5, 0.001));
    });

    test('a chapter of no length, and a file mpv has not measured yet', () {
      // Two marks at the same time: nothing to divide by, and nothing to say.
      expect(
        at(
          Duration.zero,
          chapters: const [
            MpvChapter(time: Duration.zero, title: 'Opening'),
            MpvChapter(time: Duration.zero, title: 'Part A'),
          ],
        ),
        isNull,
      );
      // A duration of zero is what mpv says before it knows: the last chapter
      // has no end, so neither the opening nor the ending can be filled.
      expect(
        at(
          const Duration(seconds: 10),
          chapters: const [MpvChapter(time: Duration.zero, title: 'OP')],
          length: Duration.zero,
        ),
        isNull,
      );
      expect(at(const Duration(seconds: 1350), length: Duration.zero), isNull);
    });

    test(
      'the ending: only with an episode to go to, and to the end of the file',
      () {
        expect(at(const Duration(seconds: 1350), hasNext: false), isNull);
        final moment = at(const Duration(seconds: 1350));
        expect(moment?.action, SkipAction.next);
        expect(moment?.fill, closeTo(0.5, 0.001));
        // Still there standing on the last frame, filled.
        expect(at(duration)?.fill, 1);
        // And not before the credits start.
        expect(at(const Duration(seconds: 1299))?.action, isNull);
      },
    );

    test('a preview after the ending is part of the same offer', () {
      const chapters = [
        MpvChapter(time: Duration.zero, title: 'Part A'),
        MpvChapter(time: Duration(seconds: 1300), title: 'Ending'),
        MpvChapter(time: Duration(seconds: 1380), title: 'Preview'),
      ];
      final moment = at(const Duration(seconds: 1390), chapters: chapters);
      expect(moment?.action, SkipAction.next);
      expect(moment?.end, duration);
      expect(moment?.fill, closeTo(0.9, 0.001));
    });

    test('the opening is offered whether or not there is a next episode', () {
      expect(
        at(const Duration(seconds: 150), hasNext: false)?.action,
        SkipAction.intro,
      );
    });

    group('with no credits marked', () {
      const unmarked = [MpvChapter(time: Duration.zero, title: 'Part A')];
      SkipMoment? near(
        Duration position, {
        Duration length = duration,
        bool hasNext = true,
      }) => skipMoment(
        chapters: unmarked,
        position: position,
        duration: length,
        hasNext: hasNext,
        notice: const Duration(seconds: 30),
      );

      test('the next episode is offered the notice before the end', () {
        expect(near(const Duration(seconds: 1369)), isNull);
        final moment = near(const Duration(seconds: 1385));
        expect(moment?.action, SkipAction.next);
        expect(moment?.end, duration);
        expect(
          moment?.credits,
          isFalse,
          reason: 'an offer, not the countdown: the last frame still counts',
        );
        expect(near(const Duration(seconds: 1385), hasNext: false), isNull);
        expect(
          moment!.fillUntilAdvance(
            const Duration(seconds: 1385),
            const Duration(seconds: 5),
          ),
          closeTo(15 / 35, 0.001),
        );
        expect(
          near(duration)!
              .fillUntilAdvance(duration, const Duration(seconds: 5)),
          closeTo(30 / 35, 0.001),
        );
      });

      test('marked credits still decide, whatever the notice', () {
        final moment = skipMoment(
          chapters: opening,
          position: const Duration(seconds: 1310),
          duration: duration,
          hasNext: true,
          notice: const Duration(seconds: 30),
        );
        expect(moment?.start, const Duration(seconds: 1300));
        expect(moment?.credits, isTrue);
        expect(
          moment!.fillUntilAdvance(
            const Duration(seconds: 1350),
            Duration.zero,
          ),
          closeTo(0.5, 0.001),
        );
      });

      test('a file shorter than twice the notice is offered at its end', () {
        // Otherwise a short file would carry the card from its first frame.
        expect(
          near(
            const Duration(seconds: 40),
            length: const Duration(seconds: 50),
          ),
          isNull,
        );
      });
    });
  });

  test('the next episode is named after the one on screen', () {
    expect(nextEpisodeTitle('Frieren · S01E05', 1, 6), 'Frieren · S01E06');
    expect(nextEpisodeTitle('Frieren · S01E28', 2, 1), 'Frieren · S02E01');
    // A name that carries no number — a banner's Play — gains one.
    expect(nextEpisodeTitle('Frieren', 1, 2), 'Frieren · S01E02');
    expect(episodeLabel(1, 6), 'S01E06');
  });

  testWidgets('the pill clears the bar it floats over', (tester) async {
    // chromeBottomBand is arithmetic about a layout, and the layout is what
    // decides: the row of controls is as tall as the Material slider in the
    // volume control (48), not as the big round button (46), and the two
    // points sat the pill on the bar.
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: lumeoTheme(),
        home: const Scaffold(
          body: PlayerChrome(
            model: ChromeModel(
              title: 'Frieren',
              download: null,
              position: Duration(minutes: 3),
              duration: Duration(minutes: 24),
              playing: true,
              volume: 100,
              muted: false,
              fullscreen: true,
              subtitlesOn: false,
              menu: PlayerMenu.none,
            ),
            actions: ChromeActions(
              close: _nothing,
              togglePlay: _nothing,
              scrub: _ignore,
              seek: _ignore,
              setVolume: _ignore,
              toggleMute: _nothing,
              toggleFullscreen: _nothing,
              openMenu: _ignore,
              closeMenu: _nothing,
              hoverBar: _ignore,
            ),
          ),
        ),
      ),
    );
    // The band is everything inside its own padding, which is the widget the
    // scrubber hangs from.
    final band = tester.getSize(
      find
          .ancestor(of: find.byType(Scrubber), matching: find.byType(Padding))
          .first,
    );
    expect(chromeBottomBand, greaterThanOrEqualTo(band.height));
  });

  testWidgets('the pill fills by the fraction it is given and presses once', (
    tester,
  ) async {
    var pressed = 0;
    Future<void> pump(double fill, VoidCallback onPressed) => tester.pumpWidget(
      MaterialApp(
        theme: lumeoTheme(),
        home: Scaffold(
          body: Center(
            child: SkipPill(
              label: 'Skip opening',
              fill: fill,
              onPressed: onPressed,
            ),
          ),
        ),
      ),
    );

    await pump(0.25, () => pressed++);
    expect(find.text('Skip opening'), findsOneWidget);
    expect(
      tester
          .widget<AnimatedFractionallySizedBox>(
            find.byType(AnimatedFractionallySizedBox),
          )
          .widthFactor,
      0.25,
    );
    await tester.tap(find.byType(SkipPill));
    expect(pressed, 1);
  });

  group('the next episode card', () {
    Future<void> show(WidgetTester tester, int? secondsLeft) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NextEpisodeCard(
                episode: const Episode(season: 1, number: 2, title: 'Two'),
                fill: 0.4,
                secondsLeft: secondsLeft,
                artwork: 'show',
                frame: null,
                onPressed: () {},
              ),
            ),
          ),
        );

    testWidgets('counts down when the next one starts by itself', (
      tester,
    ) async {
      await show(tester, 3);
      expect(find.text('Next episode in 3'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('waits without a countdown when it starts on a press', (
      tester,
    ) async {
      await show(tester, null);
      expect(find.text('Next episode'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });
}

void _nothing() {}
void _ignore(Object? _) {}
