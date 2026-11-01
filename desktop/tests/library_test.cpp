#include "core.h"
#include "fakecore.h"
#include "library.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QtTest>

namespace {

QJsonObject listed(const QString &title, int year, int rating, const QString &added) {
  return {{"item", QJsonObject{{"id", title}, {"kind", "movie"}, {"title", title}, {"year", year}}},
          {"addedAt", added},
          {"rating", rating}};
}

QJsonObject line(int episode) {
  return {{"item", QJsonObject{{"id", "tt1"}, {"kind", "series"}, {"title", "Series"}}},
          {"entry", QJsonObject{{"season", 1}, {"episode", episode}, {"position", 0},
                                {"duration", 1200}, {"watched", true},
                                {"updatedAt", "2026-10-26T12:00:00Z"}}}};
}

QStringList forgotten(const FakeCore &fake) {
  return fake.requests().filter("DELETE /api/v1/progress/");
}

} // namespace

class LibraryTest : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  std::unique_ptr<Core> core;

private slots:
  void init() {
    fake = std::make_unique<FakeCore>();
    QVERIFY(fake->listen());
    core = std::make_unique<Core>(fake->address(), QString());
  }

  void myListIsInTheOrderChosen() {
    const QJsonArray titles{
        listed("The Bear", 2022, 7, "2026-09-01T00:00:00Z"),
        listed("Andor", 2022, 0, "2026-09-03T00:00:00Z"),
        listed("Arrival", 0, 9, "2026-09-02T00:00:00Z"),
        listed("Dune", 2024, 0, "2026-08-01T00:00:00Z"),
    };
    auto order = [&](const QString &by) {
      QStringList names;
      for (const QJsonValue &t : MyList::sorted(titles, by))
        names.append(t["item"]["title"].toString());
      return names;
    };
    QCOMPARE(order("added"), (QStringList{"Andor", "Arrival", "The Bear", "Dune"}));
    // Without the article; what has no year or no score goes last.
    QCOMPARE(order("title"), (QStringList{"Andor", "Arrival", "The Bear", "Dune"}));
    QCOMPARE(order("year"), (QStringList{"Dune", "Andor", "The Bear", "Arrival"}));
    QCOMPARE(order("rating"), (QStringList{"Arrival", "The Bear", "Andor", "Dune"}));
  }

  // To watch is nothing played; Watched a film watched or a series caught
  // up with; Watching anything between, a finished series with a new episode
  // out among them. The kind narrows each.
  void myListIsNarrowedToAStageAndAKind() {
    auto title = [](const QString &name, const QString &kind, int watched, int released, bool played) {
      return QJsonObject{
          {"item", QJsonObject{{"title", name}, {"kind", kind}}},
          {"seen", QJsonObject{{"watched", watched}, {"released", released}, {"played", played}}},
      };
    };
    const QJsonArray titles{
        title("Planned", "movie", 0, 1, false),
        title("Half way", "movie", 0, 1, true),
        title("Seen", "movie", 1, 1, true),
        title("Caught up", "series", 8, 8, true),
        title("New one out", "series", 8, 9, true),
        title("Not started", "series", 0, 9, false),
    };
    auto names = [&](const QString &stage, const QString &kind) {
      QStringList out;
      for (const QJsonValue &t : MyList::filtered(titles, stage, kind))
        out.append(t["item"]["title"].toString());
      return out;
    };
    QCOMPARE(names("all", ""), (QStringList{"Planned", "Half way", "Seen", "Caught up", "New one out", "Not started"}));
    QCOMPARE(names("toWatch", ""), (QStringList{"Planned", "Not started"}));
    QCOMPARE(names("watching", ""), (QStringList{"Half way", "New one out"}));
    QCOMPARE(names("watched", ""), (QStringList{"Seen", "Caught up"}));
    QCOMPARE(names("all", "series"), (QStringList{"Caught up", "New one out", "Not started"}));
    QCOMPARE(names("toWatch", "movie"), (QStringList{"Planned"}));
  }

  // The core is told only once the undo has run out, and the next page
  // starts one line earlier, since the core's history is a line shorter.
  void aLineTakenOutComesBackOnUndoAndIsForgottenWhenItRunsOut() {
    fake->answer("GET", "/api/v1/history", 200,
                 QJsonObject{{"entries", QJsonArray{line(2), line(1)}}, {"more", true}});
    fake->answer("DELETE", "/api/v1/progress/tt1", 204);
    History history(core.get());
    history.more();
    QTRY_COMPARE(history.rowCount(), 2);

    history.setUndoTime(60000);
    history.remove(0);
    QCOMPARE(history.rowCount(), 1);
    QVERIFY(history.removing());
    history.undo();
    QCOMPARE(history.rowCount(), 2);
    QCOMPARE(history.data(history.index(0), History::EntryRole).toMap()["episode"].toInt(), 2);

    history.setUndoTime(0);
    history.remove(0);
    QTRY_COMPARE(forgotten(*fake), QStringList{"DELETE /api/v1/progress/tt1?season=1&episode=2"});
    QVERIFY(!history.removing());
    history.more();
    QTRY_VERIFY(fake->requests().last().startsWith("GET /api/v1/history?limit=50&offset=1"));
  }

  void aLineTheCoreWouldNotForgetComesBack() {
    fake->answer("GET", "/api/v1/history", 200,
                 QJsonObject{{"entries", QJsonArray{line(2), line(1)}}, {"more", false}});
    fake->answer("DELETE", "/api/v1/progress/tt1", 500);
    History history(core.get());
    QSignalSpy refused(&history, &History::refused);
    history.more();
    QTRY_COMPARE(history.rowCount(), 2);
    history.setUndoTime(0);
    history.remove(1);
    QTRY_COMPARE(refused.size(), 1);
    QCOMPARE(refused.first().first().toString(), "remove");
    QCOMPARE(history.rowCount(), 2);
    QCOMPARE(history.data(history.index(1), History::EntryRole).toMap()["episode"].toInt(), 1);
  }
};

QTEST_GUILESS_MAIN(LibraryTest)
#include "library_test.moc"
