#include "core.h"
#include "downloads.h"
#include "fakecore.h"
#include "title.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QtTest>

namespace {

QJsonObject listed(const QJsonArray &sources, int providers = 1,
                   const QJsonArray &failed = QJsonArray()) {
  return {{"sources", sources}, {"failed", failed}, {"providers", providers}};
}

QJsonObject entry(int season, int episode, const QString &updatedAt) {
  return {{"season", season}, {"episode", episode}, {"position", 600.0},
          {"duration", 2900.0}, {"updatedAt", updatedAt}};
}

} // namespace

class TitleTest : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  std::unique_ptr<Core> core;
  std::unique_ptr<Downloads> downloads;

  QJsonArray copies() const { return FakeCore::fixture("sources.json").toArray(); }

  // A choice for the film tt1, as the page makes it.
  std::unique_ptr<SourceChoice> choice() {
    auto choice = std::make_unique<SourceChoice>(core.get(), downloads.get());
    choice->setItemId("tt1");
    return choice;
  }

private slots:
  void init() {
    fake = std::make_unique<FakeCore>();
    QVERIFY(fake->listen());
    core = std::make_unique<Core>(fake->address(), QString());
    fake->answer("GET", "/api/v1/downloads", 200, QJsonObject{{"downloads", QJsonArray()}});
    fake->answer("GET", "/api/v1/sources", 200, listed(copies()));
    fake->answer("POST", "/api/v1/downloads", 201,
                 QJsonObject{{"id", "d1"}, {"itemId", "tt1"}, {"state", "active"}});
    downloads = std::make_unique<Downloads>(core.get());
  }

  // Only a title never watched opens at its first episode.
  void thePageOpensWhereWatchingGoesOn() {
    const QJsonObject item{{"id", "tt1"}, {"kind", "series"}, {"title", "Columbo"}};
    fake->answer("GET", "/api/v1/items/tt1", 200, item);
    auto opening = [this](const QJsonObject &progress) {
      fake->answer("GET", "/api/v1/progress/tt1", 200, progress);
      Title title(core.get(), "tt1");
      if (!QTest::qWaitFor([&] { return title.status() == Title::Ready; }))
        return QVariantMap{{"failed", true}};
      return title.opening();
    };
    const QJsonArray entries{entry(1, 2, "2026-09-01T00:00:00Z"), entry(1, 5, "2026-09-03T00:00:00Z")};
    QCOMPARE(opening({{"entries", entries}, {"next", entry(1, 6, "")}}),
             (QVariantMap{{"season", 1}, {"episode", 6}}));
    QCOMPARE(opening({{"entries", entries},
                      {"upcoming", QJsonObject{{"season", 2}, {"number", 1}}}}),
             (QVariantMap{{"season", 2}, {"episode", 1}}));
    QCOMPARE(opening({{"entries", entries}}), (QVariantMap{{"season", 1}, {"episode", 5}}));
    QCOMPARE(opening({}), QVariantMap());
  }

  void progressThatFailsLeavesThePageWithoutIt() {
    fake->answer("GET", "/api/v1/items/tt1", 200, QJsonObject{{"id", "tt1"}});
    fake->answer("GET", "/api/v1/progress/tt1", 500);
    Title title(core.get(), "tt1");
    QTRY_COMPARE(title.status(), Title::Ready);
  }

  // Play on the home screen's banner, or pressed while the list is coming,
  // starts the first copy once it is here.
  void aPlayPressedBeforeTheListArrivesIsKept() {
    fake->hold("GET", "/api/v1/sources");
    auto c = choice();
    QSignalSpy started(c.get(), &SourceChoice::started);
    c->load();
    c->start();
    QVERIFY(c->pending());
    QVERIFY(c->playable());
    fake->release();
    QTRY_COMPARE(started.size(), 1);
    QCOMPARE(started.first().first().toString(), "d1");
    const QStringList posts = fake->requests().filter("POST /api/v1/downloads");
    QCOMPARE(posts.size(), 1);
    QVERIFY2(posts.first().contains("2160p"), "the copy ranked first");
    QVERIFY(!c->pending());
  }

  // Without a network the list would keep Play waiting until the providers
  // fail; a copy on disk needs none of them.
  void aCopyOnDiskPlaysWithoutWaitingForTheList() {
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{QJsonObject{
                                               {"id", "here"}, {"itemId", "tt1"}, {"state", "done"}}}}});
    downloads->refresh();
    QTRY_COMPARE(downloads->all().size(), 1);
    fake->hold("GET", "/api/v1/sources");
    auto c = choice();
    QSignalSpy started(c.get(), &SourceChoice::started);
    c->load();
    c->start();
    QCOMPARE(started.size(), 1);
    QCOMPARE(started.first().first().toString(), "here");
  }

  void aListThatFailsLetsGoOfThePressItHeld() {
    fake->answer("GET", "/api/v1/sources", 502, QJsonObject{{"error", "torrentio: timeout"}});
    auto c = choice();
    c->setProperty("startWhenReady", true);
    c->load();
    QTRY_VERIFY(!c->loading());
    QCOMPARE(c->errorStatus(), 502);
    QVERIFY(!c->pending());
    QVERIFY(!c->playable());
  }

  void anEmptyListSaysWhy() {
    auto empty = [this](const QJsonObject &answer, const QString &released = {}) {
      fake->answer("GET", "/api/v1/sources", 200, answer);
      auto c = choice();
      c->clock = QDateTime(QDate(2026, 10, 25), QTime(18, 0), QTimeZone::UTC);
      c->setReleased(released);
      c->load();
      if (!QTest::qWaitFor([&] { return c->listed(); }))
        return QString("no answer");
      return c->empty();
    };
    QCOMPARE(empty(listed({}, 0)), "addons");
    QCOMPARE(empty(listed({}, 1, {QJsonObject{{"provider", "torrentio"}, {"status", 403}}}),
                   "2026-10-25T00:00:00Z"),
             "failed");
    QCOMPARE(empty(listed({}), "2026-10-25T00:00:00Z"), "today");
    QCOMPARE(empty(listed({}), "2026-10-24T00:00:00Z"), "yesterday");
    QCOMPARE(empty(listed({}), "2026-01-01T00:00:00Z"), "none");
    QCOMPARE(empty(listed(copies())), QString());
  }

  // Nobody has a copy of what has not aired, so nobody is asked.
  void anEpisodeNotOutYetIsNotAskedFor() {
    auto c = choice();
    c->clock = QDateTime(QDate(2026, 10, 25), QTime(18, 0), QTimeZone::UTC);
    c->setReleased("2026-11-01T00:00:00Z");
    c->load();
    QTest::qWait(50);
    QVERIFY(c->upcoming());
    QVERIFY(!fake->requests().join(" ").contains("/api/v1/sources"));
  }

  // Said where the copy is named, which is also the way to a smaller one.
  void aCopyTheDiskHasNoRoomForSaysHowMuchIsFree() {
    fake->answer("POST", "/api/v1/downloads", 507,
                 QJsonObject{{"error", "no room"}, {"size", 19327352832.0}, {"free", 1073741824.0}});
    auto c = choice();
    c->load();
    QTRY_VERIFY(c->listed());
    c->start();
    QTRY_VERIFY(!c->starting());
    QCOMPARE(c->noRoom(), (QVariantMap{{"size", 19327352832.0}, {"free", 1073741824.0}}));
  }

  // The release just picked, which the core marks, over the ranking's best.
  void aListAskedAgainAfterAPickFollowsIt() {
    QJsonArray sources = copies();
    QJsonObject second = sources[1].toObject();
    second["lastUsed"] = true;
    sources[1] = second;
    fake->answer("GET", "/api/v1/sources", 200, listed(sources));
    auto c = choice();
    c->load();
    QTRY_VERIFY(c->listed());
    QCOMPARE(c->picked(), 0);
    c->load(true);
    QTRY_COMPARE(c->picked(), 1);
  }
};

QTEST_GUILESS_MAIN(TitleTest)
#include "title_test.moc"
