#include "core.h"
#include "fakecore.h"
#include "home.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QtTest>

namespace {

QJsonObject progress(const QString &itemId) {
  return {{"item", QJsonObject{{"id", itemId}, {"kind", "movie"}, {"title", "Nosferatu"}}},
          {"next", QJsonObject{{"season", 0}, {"episode", 0}, {"position", 900.0},
                               {"duration", 5700.0}, {"watched", false}}},
          {"updatedAt", "2026-09-20T12:00:00Z"}};
}

QStringList ids(const Shelf *shelf) {
  QStringList ids;
  for (int i = 0; i < shelf->rowCount(); ++i)
    ids.append(shelf->data(shelf->index(i), Shelf::ItemRole).toMap()["id"].toString());
  return ids;
}

QStringList names(const QList<Shelf *> &shelves) {
  QStringList names;
  for (const Shelf *shelf : shelves)
    names.append(shelf->kind() + "/" + shelf->catalog() + "/" + shelf->genre());
  return names;
}

QJsonObject items(const QJsonArray &items) { return {{"items", items}}; }

QJsonObject film(const QString &id) { return {{"id", id}, {"kind", "movie"}, {"title", id}}; }

} // namespace

class HomeTest : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  std::unique_ptr<Core> core;

  QJsonObject movieTop() const { return FakeCore::fixture("catalogs.json")[0].toObject(); }

private slots:
  void init() {
    fake = std::make_unique<FakeCore>();
    QVERIFY(fake->listen());
    core = std::make_unique<Core>(fake->address(), QString());
    fake->answer("GET", "/api/v1/catalogs", 200,
                 QJsonObject{{"catalogs", FakeCore::fixture("catalogs.json")}});
    fake->answer("GET", "/api/v1/catalog", 200, items(FakeCore::fixture("items.json").toArray()));
    fake->answer("GET", "/api/v1/continue", 200, QJsonArray());
  }

  // The same poster twice in a row reads as a bug even when it is not one.
  // And the banner draws from the catalogue row: asking for the title's
  // details waited, without a network, for the provider's whole timeout.
  void theHeroComesFromTheFirstShelfAndIsNotInTheShelfUnderIt() {
    Home home(core.get());
    QTRY_COMPARE(home.status(), Home::Ready);
    const QString hero = home.hero()["id"].toString();
    QVERIFY(hero == "tt0110912" || hero == "tt0903747");
    QCOMPARE(home.lead()->catalog(), "top");
    QCOMPARE(home.lead()->rowCount(), 2);
    QVERIFY(!ids(home.lead()).contains(hero));
    QCOMPARE(ids(home.lead()).first(), "tt0063350");
    QCOMPARE(names(home.shelves()),
             (QStringList{"series/top/", "movie/top/Comedy", "movie/top/Drama", "series/top/Comedy"}));
    for (const QString &request : fake->requests())
      QVERIFY2(!request.contains("/api/v1/items/"), qPrintable(request));
  }

  void watchProgressIsTheShelfOverTheHeroOnlyWhenThereIsAny() {
    fake->answer("GET", "/api/v1/continue", 200, QJsonArray{progress("tt0013442")});
    Home home(core.get());
    QTRY_COMPARE(home.status(), Home::Ready);
    QCOMPARE(home.lead()->catalog(), "continue");
    QCOMPARE(ids(home.lead()), QStringList{"tt0013442"});
    const QModelIndex card = home.lead()->index(0);
    QCOMPARE(home.lead()->data(card, Shelf::WatchedRole).toDouble(), 900.0 / 5700);
    QCOMPARE(home.lead()->data(card, Shelf::RemainingRole).toDouble(), 5700.0 - 900);
    QCOMPARE(names(home.shelves()).first(), "movie/top/");
  }

  void watchProgressStaysWhenTheCatalogueCannotBeFetched() {
    fake->answer("GET", "/api/v1/catalog", 502, QJsonObject{{"error", "provider down"}});
    fake->answer("GET", "/api/v1/continue", 200, QJsonArray{progress("tt0013442")});
    Home home(core.get());
    QTRY_COMPARE(home.status(), Home::Ready);
    QVERIFY(home.hero().isEmpty());
    QCOMPARE(home.lead(), nullptr);
    QCOMPARE(home.shelves().first()->catalog(), "continue");
  }

  void progressThatFailsTakesNothingWithIt() {
    fake->answer("GET", "/api/v1/continue", 500);
    Home home(core.get());
    QTRY_COMPARE(home.status(), Home::Ready);
    QVERIFY(!home.hero().isEmpty());
  }

  void cataloguesThatCannotBeListedAreSaidAndAskedForAgain() {
    fake->answer("GET", "/api/v1/catalogs", 502, QJsonObject{{"error", "cinemeta is down"}});
    Home home(core.get());
    QTRY_COMPARE(home.status(), Home::Failed);
    QCOMPARE(home.error(), "cinemeta is down");

    fake->answer("GET", "/api/v1/catalogs", 200,
                 QJsonObject{{"catalogs", FakeCore::fixture("catalogs.json")}});
    home.load();
    QTRY_COMPARE(home.status(), Home::Ready);
  }

  void nothingToShowIsNotAFailure() {
    fake->answer("GET", "/api/v1/catalogs", 200, QJsonObject{{"catalogs", QJsonArray()}});
    Home home(core.get());
    QTRY_COMPARE(home.status(), Home::Empty);
  }

  // Providers repeat their last page once they run out.
  void aShelfPagesUntilAPageAddsNothingNew() {
    fake->onQuery("GET", "/api/v1/catalog", [](const QUrlQuery &query) {
      const int skip = query.queryItemValue("skip").toInt();
      return std::pair{200, QJsonValue(items(skip == 0 ? QJsonArray{film("a"), film("b")}
                                                       : QJsonArray{film("b"), film("c")}))};
    });
    Shelf shelf(core.get(), movieTop(), "Comedy", {}, nullptr);
    shelf.more();
    QTRY_COMPARE(ids(&shelf), (QStringList{"a", "b"}));
    shelf.more();
    QTRY_COMPARE(ids(&shelf), (QStringList{"a", "b", "c"}));
    shelf.more();
    QTRY_COMPARE(fake->requests().size(), 3);
    shelf.more();
    QTest::qWait(50);
    QCOMPARE(fake->requests().size(), 3);
    QVERIFY(fake->requests().first().contains("genre=Comedy"));
    QVERIFY(fake->requests().last().contains("skip=3"));
    QVERIFY(!shelf.empty());
  }

  // A dead genre steps aside rather than pulsing forever; a shelf with
  // posters on it asks again on the next scroll.
  void aShelfWithNothingStepsAsideAndAFailedPageIsNotTheEnd() {
    fake->answer("GET", "/api/v1/catalog", 502);
    Shelf dead(core.get(), movieTop(), "Western", {}, nullptr);
    dead.more();
    QTRY_VERIFY(dead.empty());

    Shelf going(core.get(), movieTop(), "", QJsonArray{film("a")}, nullptr);
    going.more();
    QTRY_COMPARE(fake->requests().size(), 2);
    QVERIFY(!going.empty());
    fake->answer("GET", "/api/v1/catalog", 200, items(QJsonArray{film("b")}));
    going.more();
    QTRY_COMPARE(ids(&going), (QStringList{"a", "b"}));
  }
};

QTEST_GUILESS_MAIN(HomeTest)
#include "home_test.moc"
