#include "fakecore.h"
#include "languages.h"
#include "rows.h"
#include "tracks.h"

#include <QSignalSpy>
#include <QtTest>

namespace {

QVariantMap sub(int id, const QString &lang, bool selected = false, bool forced = false) {
  return {{"id", id}, {"type", "sub"}, {"lang", lang}, {"selected", selected}, {"forced", forced}};
}

} // namespace

// What audio and subtitles decide without an mpv: the player tests have
// the real one.
class TracksTest : public QObject {
  Q_OBJECT

  Languages languages{FakeCore::fixture("languages.json").toArray().toVariantList()};

private slots:
  // A container's ISO 639-2, a muxer's BCP 47 and a preference's 639-1 are
  // one language.
  void whatAFileCallsALanguage() {
    QCOMPARE(languages.canonical("eng"), "en");
    QCOMPARE(languages.canonical("EN-us"), "en");
    QCOMPARE(languages.canonical("jpn"), "ja");
    QCOMPARE(languages.canonical("xyz"), "xyz");
    QCOMPARE(languages.name("rus"), "Russian");
    QCOMPARE(languages.name("xyz"), "");
  }

  void theViewersOrder() {
    QCOMPARE(languages.rank("eng", {"ru", "en"}), 1);
    QCOMPARE(languages.rank("ru-RU", {"ru"}), 0);
    QCOMPARE(languages.rank("ja", {"ru", "en"}), -1);
    QCOMPARE(languages.rank("", {"en"}), -1);
  }

  // Off leaves a forced track, which carries the lines that are not in the
  // soundtrack's language; on takes the file's track the viewer ranks first.
  void theAnswerForTheSoundtracksLanguage() {
    const auto rank = [this](const QString &language) {
      return languages.rank(language, {"ru", "en"});
    };
    QCOMPARE(Tracks::subtitleForAudio({sub(1, "eng", true)}, false, rank), "no");
    QCOMPARE(Tracks::subtitleForAudio({sub(1, "eng", true, true)}, false, rank), "");
    QCOMPARE(Tracks::subtitleForAudio({sub(1, "eng"), sub(2, "rus")}, true, rank), "2");
    QCOMPARE(Tracks::subtitleForAudio({sub(1, "eng", true), sub(2, "rus")}, true, rank), "");
    QCOMPARE(Tracks::subtitleForAudio({sub(1, "jpn")}, true, rank), "");
  }

  // mpv 0.38 gave the box `sub-border-style`; an older mpv draws it with
  // `sub-back-color` alone.
  void theBackgroundOnEitherMpv() {
    const QVariantMap box = Tracks::backgroundProperties("box", true);
    QCOMPARE(box["sub-border-style"].toString(), "background-box");
    QCOMPARE(box["sub-back-color"].toString(), "#C0000000");
    const QVariantMap shadow = Tracks::backgroundProperties("shadow", true);
    QCOMPARE(shadow["sub-border-style"].toString(), "outline-and-shadow");
    QCOMPARE(shadow["sub-border-size"].toDouble(), 1.5);
    QCOMPARE(shadow["sub-shadow-offset"].toInt(), 3);
    const QVariantMap old = Tracks::backgroundProperties("box", false);
    QVERIFY(!old.contains("sub-border-style"));
    QCOMPARE(old["sub-back-color"].toString(), "#C0000000");
  }

  // A row that stays is changed, not made again.
  void rowsChangeInPlace() {
    Rows rows({"label"});
    rows.set({{{"label", "a"}}, {{"label", "b"}}});
    QSignalSpy changed(&rows, &Rows::dataChanged);
    QSignalSpy inserted(&rows, &Rows::rowsInserted);
    QSignalSpy removed(&rows, &Rows::rowsRemoved);
    QSignalSpy reset(&rows, &Rows::modelReset);
    rows.set({{{"label", "a"}}, {{"label", "c"}}, {{"label", "d"}}});
    QCOMPARE(changed.count(), 1);
    QCOMPARE(inserted.count(), 1);
    rows.set({{{"label", "a"}}});
    QCOMPARE(removed.count(), 1);
    QCOMPARE(reset.count(), 0);
    QCOMPARE(rows.data(rows.index(0), Qt::UserRole).toString(), "a");
  }
};

QTEST_GUILESS_MAIN(TracksTest)
#include "tracks_test.moc"
