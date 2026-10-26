#include "core.h"
#include "downloads.h"
#include "fakecore.h"
#include "mine.h"
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
      Title title(core.get(), downloads.get(), "tt1");
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
    Title title(core.get(), downloads.get(), "tt1");
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

  // The pick is recorded first, and the list asked again follows it, past
  // the copy already on disk.
  void aCopyChosenIsRecordedAndFollowed() {
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{QJsonObject{
                                               {"id", "here"}, {"itemId", "tt1"}, {"state", "done"}}}}});
    downloads->refresh();
    QTRY_COMPARE(downloads->all().size(), 1);
    fake->answer("PATCH", "/api/v1/choices/tt1", 200, QJsonObject());
    auto c = choice();
    c->load();
    QTRY_VERIFY(c->listed());
    QJsonArray sources = copies();
    QJsonObject second = sources[1].toObject();
    second["lastUsed"] = true;
    sources[1] = second;
    fake->answer("GET", "/api/v1/sources", 200, listed(sources));
    QSignalSpy started(c.get(), &SourceChoice::started);
    c->choose(1, true);
    QTRY_COMPARE(started.size(), 1);
    QCOMPARE(started.first().first().toString(), "d1");
    const QStringList patches = fake->requests().filter("PATCH /api/v1/choices/tt1");
    QCOMPARE(patches.size(), 1);
    QVERIFY(patches.first().contains("1080p"));
    QVERIFY(fake->requests().filter("POST /api/v1/downloads").last().contains("1080p"));
  }

  void aFolderWithNothingOfTheTitleIsRefusedInTheCoresWords() {
    fake->answer("POST", "/api/v1/items/tt1/folders", 422,
                 QJsonObject{{"error", "no episodes of this series there"}});
    auto c = choice();
    QSignalSpy refused(c.get(), &SourceChoice::refused);
    c->link("/home/someone/Videos");
    QTRY_COMPARE(refused.size(), 1);
    QCOMPARE(refused.first().at(1).toInt(), 422);
    QVERIFY(fake->requests().last().contains(R"({"path":"/home/someone/Videos"})"));
  }

  // One episode at a time, those already downloading passed over: a
  // provider asked for seventeen lists at once answers 403.
  void aSeasonIsDownloadedOneEpisodeAtATime() {
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{QJsonObject{
                                               {"id", "e1"}, {"itemId", "tt1"}, {"season", 1},
                                               {"episode", 1}, {"state", "done"}}}}});
    downloads->refresh();
    QTRY_COMPARE(downloads->all().size(), 1);
    fake->answer("GET", "/api/v1/items/tt1", 200, QJsonObject{{"id", "tt1"}});
    fake->answer("GET", "/api/v1/progress/tt1", 200, QJsonObject());
    Title title(core.get(), downloads.get(), "tt1");
    QTRY_COMPARE(title.status(), Title::Ready);
    QVariantList season;
    for (int n = 1; n <= 3; ++n)
      season.append(QVariantMap{{"season", 1}, {"number", n}});
    title.downloadSeason(season);
    QVERIFY(title.queueing());
    QTRY_VERIFY(!title.queueing());
    const QStringList asked = fake->requests().filter(QRegularExpression("sources|POST"));
    QCOMPARE(asked.size(), 4);
    QVERIFY(asked[0].contains("episode=2") && asked[1].startsWith("POST"));
    QVERIFY(asked[2].contains("episode=3") && asked[3].startsWith("POST"));
  }

  // The core not answering, or a provider refusing while it listed nothing:
  // the rest would fail the same way.
  void aSeasonStopsWhereAProviderRefuses() {
    fake->answer("GET", "/api/v1/sources", 200,
                 listed({}, 1, {QJsonObject{{"provider", "torrentio"}, {"reason", "403 Forbidden"}}}));
    fake->answer("GET", "/api/v1/items/tt1", 200, QJsonObject{{"id", "tt1"}});
    fake->answer("GET", "/api/v1/progress/tt1", 200, QJsonObject());
    Title title(core.get(), downloads.get(), "tt1");
    QTRY_COMPARE(title.status(), Title::Ready);
    QSignalSpy failed(&title, &Title::seasonFailed);
    title.downloadSeason({QVariantMap{{"season", 1}, {"number", 1}},
                          QVariantMap{{"season", 1}, {"number", 2}}});
    QTRY_COMPARE(failed.size(), 1);
    QCOMPARE(failed.first().first().toString(), "torrentio: 403 Forbidden");
    QCOMPARE(fake->requests().filter("/api/v1/sources").size(), 1);
  }

  // A shared link names the title by IMDb id, the same on every machine,
  // then by words, which the page shows when it cannot reach the catalogue.
  void aTitleIsSharedByItsImdbIdAndItsWords() {
    fake->answer("GET", "/api/v1/items/tt1", 200,
                 QJsonObject{{"id", "tt1"}, {"kind", "movie"}, {"title", "Night of the Living Dead"},
                             {"year", 1968}, {"externalIds", QJsonObject{{"imdb", "tt0063350"}}}});
    fake->answer("GET", "/api/v1/progress/tt1", 200, QJsonObject());
    Title title(core.get(), downloads.get(), "tt1");
    QTRY_COMPARE(title.status(), Title::Ready);
    QCOMPARE(title.link(), Title::sharePage + "/movie/?tt0063350-Night-of-the-Living-Dead-1968");
  }

  // Two clicks in flight could land in either order and leave the core on
  // the opposite of what the button shows.
  void myListIsSentOneClickAtATimeAndEndsWhereTheButtonDoes() {
    fake->answer("GET", "/api/v1/list/tt1", 200, QJsonObject{{"inList", false}});
    fake->answer("GET", "/api/v1/ratings/tt1", 200, QJsonObject{{"ratings", QJsonArray()}});
    fake->answer("PUT", "/api/v1/list/tt1", 200, QJsonObject{{"inList", true}});
    fake->answer("DELETE", "/api/v1/list/tt1", 204);
    Mine mine(core.get(), "tt1");
    QTRY_VERIFY(mine.known());
    fake->hold("PUT", "/api/v1/list/tt1");
    mine.toggle();
    mine.toggle();
    mine.toggle();
    QVERIFY(mine.inList());
    QTRY_COMPARE(fake->requests().filter("/api/v1/list/tt1").size(), 2);
    fake->release();
    QTest::qWait(50);
    QCOMPARE(fake->requests().filter(QRegularExpression("^(PUT|DELETE) /api/v1/list")).size(), 1);
  }

  void aRefusedChangeIsPutBackAndSaid() {
    fake->answer("GET", "/api/v1/list/tt1", 200, QJsonObject{{"inList", false}});
    fake->answer("GET", "/api/v1/ratings/tt1", 200,
                 QJsonObject{{"ratings", QJsonArray{QJsonObject{{"season", 0}, {"episode", 0}, {"rating", 7}}}}});
    fake->answer("PUT", "/api/v1/ratings/tt1", 500);
    Mine mine(core.get(), "tt1");
    QTRY_VERIFY(mine.known());
    QCOMPARE(mine.score(), 7);
    QSignalSpy refused(&mine, &Mine::refused);
    mine.rate(9);
    QCOMPARE(mine.score(), 9);
    QTRY_COMPARE(refused.size(), 1);
    QCOMPARE(refused.first().first().toString(), "rate");
    QCOMPARE(mine.score(), 7);
  }

  // The core puts a title scored before it was ever played on My list.
  void aScoreGivenOffTheListIsReadBackOntoIt() {
    fake->answer("GET", "/api/v1/list/tt1", 200, QJsonObject{{"inList", false}});
    fake->answer("GET", "/api/v1/ratings/tt1", 200, QJsonObject{{"ratings", QJsonArray()}});
    fake->answer("PUT", "/api/v1/ratings/tt1", 200, QJsonObject{{"rating", 8}});
    Mine mine(core.get(), "tt1");
    QTRY_VERIFY(mine.known());
    fake->answer("GET", "/api/v1/list/tt1", 200, QJsonObject{{"inList", true}});
    mine.rate(8);
    QTRY_VERIFY(mine.inList());
  }
};

QTEST_GUILESS_MAIN(TitleTest)
#include "title_test.moc"
