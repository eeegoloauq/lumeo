#include "core.h"
#include "downloads.h"
#include "fakecore.h"
#include "opening.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QtTest>

class OpeningTest : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  std::unique_ptr<Core> core;
  std::unique_ptr<Downloads> downloads;
  std::unique_ptr<Opening> opening;

private slots:
  void init() {
    fake = std::make_unique<FakeCore>();
    QVERIFY(fake->listen());
    fake->answer("GET", "/api/v1/downloads", 200, QJsonObject{{"downloads", QJsonArray()}});
    core = std::make_unique<Core>(fake->address(), QString());
    downloads = std::make_unique<Downloads>(core.get());
    opening = std::make_unique<Opening>(core.get(), downloads.get());
  }

  void aLinkOpensItsTitle() {
    fake->answer("GET", "/api/v1/find", 200, FakeCore::fixture("items.json")[0]);
    QSignalSpy title(opening.get(), &Opening::title);
    opening->open("lumeo://title/movie/tt0063350/");
    QVERIFY(title.wait());
    QCOMPARE(title.first().first().toMap()["id"], FakeCore::fixture("items.json")[0]["id"].toVariant());
    QVERIFY(fake->requests().filter("/api/v1/find?imdb=tt0063350&kind=movie").size() == 1);
  }

  // A link from a page is only ever a title to show: one that names none, or
  // smuggles a path, asks the core nothing and says so.
  void aLinkNamingNoTitleOpensNothing() {
    QSignalSpy failed(opening.get(), &Opening::failed);
    const QStringList links{
        "lumeo://title/movie/tt0063350/../../../home/me/film.mkv",
        "lumeo://title/movie/tt0063350%2F..%2Ffilm.mkv",
        "lumeo:///home/me/film.mkv",
        "lumeo://play/movie/tt0063350",
    };
    for (const QString &link : links)
      opening->open(link);
    QCOMPARE(failed.size(), links.size());
    for (const auto &arguments : failed)
      QCOMPARE(arguments.at(1).toString(), QString());
    QTest::qWait(50);
    QCOMPARE(fake->requests().filter("/api/v1/find").size(), 0);
    QCOMPARE(fake->requests().filter("/api/v1/local").size(), 0);
  }

  // "Open with Lumeo": the file plays under the title the core found for it.
  void aFilePlaysUnderItsTitle() {
    fake->answer("POST", "/api/v1/local", 201, FakeCore::fixture("download.json"));
    fake->answer("GET", "/api/v1/items/tt0063350", 200, QJsonObject{{"title", "Night of the Living Dead"}});
    QSignalSpy play(opening.get(), &Opening::play);
    opening->open("/films/night.mkv");
    QVERIFY(play.wait());
    QCOMPARE(play.first(), (QVariantList{"d1", "Night of the Living Dead"}));
  }

  void aFileTheCoreRefusesSaysWhy() {
    fake->answer("POST", "/api/v1/local", 400, QJsonObject{{"error", "not a video file"}});
    QSignalSpy failed(opening.get(), &Opening::failed);
    opening->open("/films/notes.txt");
    QVERIFY(failed.wait());
    QCOMPARE(failed.first(), (QVariantList{"notes.txt", "not a video file"}));
  }
};

QTEST_GUILESS_MAIN(OpeningTest)
#include "opening_test.moc"
