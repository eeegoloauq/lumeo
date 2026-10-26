#include "next.h"

#include <QtTest>

namespace {

QVariantList chapters(std::initializer_list<std::pair<double, const char *>> list) {
  QVariantList out;
  for (const auto &[time, title] : list)
    out.append(QVariantMap{{"time", time}, {"title", QString(title)}});
  return out;
}

// A teaser, the opening song, the episode and its ending, in 1400 s.
const QVariantList anime =
    chapters({{0, "Teaser"}, {100, "Opening"}, {200, "Part A"}, {1300, "Ending"}});

Next::Moment at(double position, const QVariantList &list = anime, double length = 1400,
                bool hasNext = true, double notice = 0) {
  return Next::moment(list, position, length, hasNext, notice);
}

} // namespace

// Which chapters are the opening and the ending, and what is offered when:
// the rules without an mpv, which the player tests have.
class NextTest : public QObject {
  Q_OBJECT

private slots:
  void theNamesReleasesActuallyUseInAnyCase() {
    for (const char *title : {"OP", "Opening", "opening", "Intro", "NCOP"})
      QCOMPARE(Next::openingChapter(chapters({{0, "Cold open"}, {120, title}})), 1);
    for (const char *title : {"ED", "Ending", "credits", "Preview", "NCED"})
      QCOMPARE(Next::endingChapter(chapters({{0, "Part A"}, {1200, title}})), 1);
  }

  // How a real release marks it: the scene before the song is "Intro".
  void theSongNotTheColdOpenInFrontOfIt() {
    QCOMPARE(Next::openingChapter(chapters({{0, "Intro"}, {87, "OP"}, {178, "Part A"}})), 1);
    QCOMPARE(Next::openingChapter(chapters({{0, "Avant"}, {90, "Part A"}})), -1);
  }

  // A bare prefix would skip the first minutes of an episode, or end it early.
  void aWordNotAPrefix() {
    QCOMPARE(Next::openingChapter(chapters({{0, "Operation Mindcrime"}})), -1);
    QCOMPARE(Next::endingChapter(chapters({{0, "Part A"}, {60, "Special Edition"}})), -1);
    QCOMPARE(Next::openingChapter({}), -1);
  }

  void aRunOfCandidatesIsOneEndingFromItsStart() {
    QCOMPARE(Next::endingChapter(chapters({{0, "Part B"}, {1260, "Ending"}, {1350, "Preview"}})), 1);
  }

  // "Opening Credits" read as an ending would put a Next button over the
  // whole episode.
  void aChapterThatIsAlsoAnOpeningIsNotTheEnding() {
    const QVariantList list = chapters({{0, "Opening Credits"}, {120, "Part A"}, {1260, "End Credits"}});
    QCOMPARE(Next::openingChapter(list), 0);
    QCOMPARE(Next::endingChapter(list), 2);
  }

  // A recap at the front is called "Preview" too.
  void anEpisodeDoesNotOpenWithItsOwnEnding() {
    QCOMPARE(Next::endingChapter(chapters({{0, "Preview"}, {120, "Part A"}})), -1);
    QCOMPARE(Next::endingChapter(chapters({{0, "Preview"}, {60, "OP"}, {180, "Part A"}})), -1);
  }

  void theCreditsStartWhereTheNamedEndingDoes() {
    const QVariantList list = chapters({{0, "Part A"}, {1200, "Ending"}, {1320, "Preview"}});
    QVERIFY(!Next::inCredits(list, 1140));
    QVERIFY(Next::inCredits(list, 1200));
    QVERIFY(Next::inCredits(list, 1380));
    // Unnamed chapters leave it to the core's 90%.
    QVERIFY(!Next::inCredits(chapters({{0, "Chapter 1"}, {1200, "Chapter 2"}}), 1380));
  }

  void insideTheOpeningHowFarAndWhereAPressLands() {
    const Next::Moment moment = at(150);
    QCOMPARE(moment.action, "intro");
    QCOMPARE(moment.fill, 0.5);
    QCOMPARE(moment.end, 200.0);
  }

  // The frame the next chapter starts on belongs to the episode.
  void theOpeningEndsWithItsChapter() {
    QCOMPARE(at(99).action, "");
    QCOMPARE(at(100).fill, 0.0);
    QVERIFY(at(200).action != "intro");
  }

  void anOpeningWithNothingAfterItRunsToTheEnd() {
    const Next::Moment moment = at(1350, chapters({{0, "Part A"}, {1300, "OP"}}));
    QCOMPARE(moment.action, "intro");
    QCOMPARE(moment.end, 1400.0);
  }

  // Nothing to divide by: a chapter of no length, a file not measured yet.
  void aChapterOfNoLengthAndAFileNotMeasured() {
    QCOMPARE(at(0, chapters({{0, "Opening"}, {0, "Part A"}})).action, "");
    QCOMPARE(at(10, chapters({{0, "OP"}}), 0).action, "");
    QCOMPARE(at(1350, anime, 0).action, "");
  }

  void theEndingOnlyWithAnEpisodeToGoTo() {
    QCOMPARE(at(1350, anime, 1400, false).action, "");
    const Next::Moment moment = at(1350);
    QCOMPARE(moment.action, "next");
    QCOMPARE(moment.fill, 0.5);
    QVERIFY(moment.credits);
    // On the last frame, filled; not before the credits.
    QCOMPARE(at(1400).fill, 1.0);
    QCOMPARE(at(1299).action, "");
  }

  void aSceneAfterTheEndingIsSkippedTo() {
    const QVariantList list = chapters({{0, "Part A"}, {1200, "Ending"}, {1300, "Epilogue"}});
    for (bool hasNext : {true, false}) {
      const Next::Moment moment = at(1250, list, 1400, hasNext);
      QCOMPARE(moment.action, "ending");
      QCOMPARE(moment.end, 1300.0);
    }
    // The scene ends unmarked: the next one comes with the notice.
    QCOMPARE(at(1300, list).action, "");
    const Next::Moment last = at(1385, list, 1400, true, 30);
    QCOMPARE(last.action, "next");
    QVERIFY(!last.credits);
  }

  // An offer, not the countdown: the held last frame still counts.
  void unmarkedTheNoticeBeforeTheEnd() {
    const QVariantList unmarked = chapters({{0, "Part A"}});
    QCOMPARE(at(1369, unmarked, 1400, true, 30).action, "");
    const Next::Moment moment = at(1385, unmarked, 1400, true, 30);
    QCOMPARE(moment.action, "next");
    QVERIFY(!moment.credits);
    // Otherwise a short file would carry the card from its first frame.
    QCOMPARE(at(40, unmarked, 50, true, 30).action, "");
  }
};

QTEST_GUILESS_MAIN(NextTest)
#include "next_test.moc"
