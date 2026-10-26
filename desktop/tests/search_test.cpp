#include "core.h"
#include "fakecore.h"
#include "home.h"
#include "search.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QSignalSpy>
#include <QtTest>

namespace {

QJsonObject film(const QString &title, int year = 2000) {
  return {{"id", title + "/movie/" + QString::number(year)}, {"kind", "movie"}, {"title", title},
          {"year", year}};
}

QJsonObject series(const QString &title, int year = 2000) {
  return {{"id", title + "/series/" + QString::number(year)}, {"kind", "series"},
          {"title", title}, {"year", year}};
}

QStringList titles(const QJsonArray &items) {
  QStringList titles;
  for (const QJsonValue &item : items)
    titles.append(item["title"].toString());
  return titles;
}

QStringList titles(const QVariantList &items) {
  QStringList titles;
  for (const QVariant &item : items)
    titles.append(item.toMap()["title"].toString());
  return titles;
}

QStringList searches(const FakeCore &fake) {
  return fake.requests().filter("GET /api/v1/search?");
}

} // namespace

class SearchTest : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  std::unique_ptr<Core> core;
  std::unique_ptr<Search> search;

  // Each kind answers with the titles that contain the word.
  void catalogue(const QJsonArray &films, const QJsonArray &shows) {
    fake->onQuery("GET", "/api/v1/search", [films, shows](const QUrlQuery &query) {
      const QString word = query.queryItemValue("q").toLower();
      QJsonArray items;
      for (const QJsonValue &item : query.queryItemValue("kind") == "series" ? shows : films)
        if (item["title"].toString().toLower().contains(word))
          items.append(item);
      return std::pair{200, QJsonValue(QJsonObject{{"items", items}})};
    });
  }

private slots:
  void init() {
    fake = std::make_unique<FakeCore>();
    QVERIFY(fake->listen());
    core = std::make_unique<Core>(fake->address(), QString());
    search = std::make_unique<Search>(core.get());
    search->setWait(0);
    catalogue({film("Night of the Living Dead", 1968), film("The Night of the Hunter", 1955)},
              {series("Night Gallery", 1969)});
  }

  // Which titles, and in what order, is the whole difference between
  // "matrix" showing The Matrix and a 1993 series nobody was looking for,
  // both of which the Flutter client did: the name that is the word first
  // whatever its kind, the kinds not taken in turns, a title the word is
  // buried in last, and a tie to the film.
  void titlesAreRankedByHowMuchOfTheNameTheWordIs() {
    QCOMPARE(titles(Search::rank("matrix", {film("The Matrix"), film("The Matrix Reloaded")},
                                 {series("Matrix"), series("Threat Matrix")})),
             (QStringList{"The Matrix", "Matrix", "The Matrix Reloaded", "Threat Matrix"}));
    QCOMPARE(titles(Search::rank("breaking bad", {film("Breaking Bad Movie"), film("Bad")},
                                 {series("Breaking Bad")})),
             (QStringList{"Breaking Bad", "Breaking Bad Movie", "Bad"}));
    QCOMPARE(titles(Search::rank("dune", {film("Verdunes"), film("Dune"), film("Children of Dunes")}, {})),
             (QStringList{"Dune", "Children of Dunes", "Verdunes"}));
    QCOMPARE(Search::rank("fargo", {film("Fargo")}, {series("Fargo")}).at(0)["kind"].toString(), "movie");
  }

  // A keystroke is two requests to the core.
  void aWordTypedQuicklyIsOneSearch() {
    search->setQuery("n");
    search->setQuery("ni");
    search->setQuery("night");
    QTRY_COMPARE(search->status(), Search::Ready);
    QCOMPARE(searches(*fake).size(), 2);
    QVERIFY(searches(*fake).first().contains("q=night"));
    QCOMPARE(titles(search->results()),
             (QStringList{"Night of the Living Dead", "Night Gallery", "The Night of the Hunter"}));
    QCOMPARE(search->films(), 2);
    QCOMPARE(search->series(), 1);
  }

  void anAnswerToAWordNoLongerInTheFieldIsDropped() {
    fake->hold("GET", "/api/v1/search");
    search->setQuery("hunter");
    QTRY_COMPARE(searches(*fake).size(), 2);
    search->setQuery("gallery");
    QTRY_COMPARE(searches(*fake).size(), 4);
    fake->release();
    QTRY_COMPARE(search->status(), Search::Ready);
    QCOMPARE(search->answered(), "gallery");
    QCOMPARE(titles(search->results()), QStringList{"Night Gallery"});
  }

  // Deleting back to a word asked for before answers at once.
  void aWordAlreadyAnsweredIsNotAskedAgain() {
    search->setQuery("night");
    QTRY_COMPARE(search->status(), Search::Ready);
    search->setQuery("nigh");
    QTRY_COMPARE(search->answered(), "nigh");
    search->setQuery("NIGHT");
    QCOMPARE(search->answered(), "NIGHT");
    QCOMPARE(search->results().size(), 3);
    QCOMPARE(searches(*fake).size(), 4);
  }

  // Waiting for both once let a film provider's timeout hide the series.
  void oneKindFailingKeepsTheOtherAndIsAskedAgain() {
    fake->onQuery("GET", "/api/v1/search", [](const QUrlQuery &query) {
      if (query.queryItemValue("kind") == "movie")
        return std::pair{502, QJsonValue(QJsonObject{{"error", "timeout"}})};
      return std::pair{200, QJsonValue(QJsonObject{{"items", QJsonArray{series("Night Gallery")}}})};
    });
    search->setQuery("night");
    QTRY_COMPARE(search->status(), Search::Ready);
    QCOMPARE(titles(search->results()), QStringList{"Night Gallery"});

    search->setQuery("nigh");
    QTRY_COMPARE(search->answered(), "nigh");
    search->setQuery("night");
    QTRY_COMPARE(searches(*fake).size(), 6);
  }

  // Enter typed faster than the answer opens the best match once it is here,
  // and the word is remembered.
  void enterBeforeTheAnswerPicksTheBestMatchWhenItComes() {
    fake->answer("POST", "/api/v1/searches", 204);
    search->setWait(60000);
    QSignalSpy picked(search.get(), &Search::picked);
    search->setQuery("hunter");
    search->submit();
    QTRY_COMPARE(picked.size(), 1);
    QCOMPARE(picked.first().first().toMap()["title"].toString(), "The Night of the Hunter");
    QCOMPARE(search->recent(), QStringList{"hunter"});
    QTRY_VERIFY(fake->requests().contains(R"(POST /api/v1/searches {"query":"hunter"})"));

    search->submit();
    QCOMPARE(picked.size(), 2);
  }

  // Opening search empties the field and asks for the searches from before;
  // the popular shelf is asked for once.
  void openingOffersTheSearchesFromBeforeAndThePopularFilms() {
    fake->answer("GET", "/api/v1/searches", 200,
                 QJsonObject{{"searches", QJsonArray{"metropolis", "nosferatu"}}});
    fake->answer("GET", "/api/v1/catalogs", 200,
                 QJsonObject{{"catalogs", FakeCore::fixture("catalogs.json")}});
    search->setQuery("night");
    search->open();
    QCOMPARE(search->query(), "");
    QCOMPARE(search->status(), Search::Idle);
    QTRY_COMPARE(search->recent(), (QStringList{"metropolis", "nosferatu"}));
    QTRY_VERIFY(search->popular() != nullptr);
    QCOMPARE(search->popular()->kind(), "movie");
    QCOMPARE(search->popular()->catalog(), "top");

    search->open();
    QTRY_COMPARE(fake->requests().filter("/api/v1/searches").size(), 2);
    QCOMPARE(fake->requests().filter("/api/v1/catalogs").size(), 1);
  }

  void aSearchIsForgottenAloneOrWithTheRest() {
    fake->answer("GET", "/api/v1/searches", 200,
                 QJsonObject{{"searches", QJsonArray{"metropolis", "nosferatu"}}});
    fake->answer("DELETE", "/api/v1/searches", 204);
    search->open();
    QTRY_COMPARE(search->recent().size(), 2);
    search->forget("metropolis");
    QCOMPARE(search->recent(), QStringList{"nosferatu"});
    search->forget("");
    QVERIFY(search->recent().isEmpty());
    QTRY_COMPARE(fake->requests().filter("DELETE").size(), 2);
    QVERIFY(fake->requests().filter("DELETE")[0].endsWith("?q=metropolis"));
    QVERIFY(fake->requests().filter("DELETE")[1].endsWith("/api/v1/searches"));
  }
};

QTEST_GUILESS_MAIN(SearchTest)
#include "search_test.moc"
