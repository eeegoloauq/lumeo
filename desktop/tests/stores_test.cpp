#include "addons.h"
#include "core.h"
#include "downloads.h"
#include "fakecore.h"
#include "preferences.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QtTest>

namespace {

QJsonObject download(const QString &id, const QString &state = "active") {
  return {{"id", id},
          {"itemId", "tt1"},
          {"name", "Film"},
          {"state", state},
          {"progress", QJsonObject{{"total", 100}}}};
}

QStringList ids(const Downloads &store) {
  QStringList ids;
  for (const QVariant &d : store.all())
    ids.append(d.toMap()["id"].toString() + " " + d.toMap()["state"].toString());
  return ids;
}

} // namespace

class StoresTest : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  std::unique_ptr<Core> core;

private slots:
  void init() {
    fake = std::make_unique<FakeCore>();
    QVERIFY(fake->listen());
    core = std::make_unique<Core>(fake->address(), QString());
  }

  void aDownloadStartedHereIsListedBeforeTheNextPoll() {
    // The first poll is still in flight when the download starts, and it
    // answers without it.
    fake->hold("GET", "/api/v1/downloads");
    fake->answer("GET", "/api/v1/downloads", 200, QJsonObject{{"downloads", QJsonArray()}});
    fake->answer("POST", "/api/v1/downloads", 201, download("new"));
    Downloads store(core.get());
    bool answered = false;
    store.start("tt1", QJsonObject{{"name", "Film"}}, 0, 0, false, this,
                [&](const QJsonObject &, int status) { answered = status == 201; });
    QTRY_VERIFY(answered);
    QCOMPARE(ids(store), QStringList{"new active"});

    fake->release();
    QTRY_COMPARE(fake->requests().count("GET /api/v1/downloads"), 1);
    QTest::qWait(50);
    QCOMPARE(ids(store), QStringList{"new active"});
  }

  void aDownloadTheCoreAlreadyHadIsUpdatedWhereItIs() {
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{download("new"), download("old")}}});
    fake->answer("POST", "/api/v1/downloads", 201, download("old", "done"));
    Downloads store(core.get());
    QTRY_COMPARE(store.all().size(), 2);
    store.start("tt1", {}, 0, 0, false, this, [](const QJsonObject &, int) {});
    QTRY_COMPARE(ids(store), (QStringList{"new active", "old done"}));
  }

  void pauseAndResumeChangeTheRowAtOnceWithTheCoresAnswer() {
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{download("d")}}});
    fake->on("PATCH", "/api/v1/downloads/d", [](const QJsonValue &body) {
      const bool paused = body["paused"].toBool();
      QJsonObject answer = download("d", paused ? "paused" : "active");
      answer["pausedByUser"] = paused;
      return std::pair{200, QJsonValue(answer)};
    });
    Downloads store(core.get());
    QTRY_COMPARE(store.all().size(), 1);

    store.pause("d");
    QTRY_COMPARE(ids(store), QStringList{"d paused"});
    QVERIFY(fake->requests().contains(R"(PATCH /api/v1/downloads/d {"paused":true})"));
    QCOMPARE(store.all().first().toMap()["pausedByUser"], true);

    store.resume("d");
    QTRY_COMPARE(ids(store), QStringList{"d active"});
  }

  void aPauseTheCoreRefusesLeavesTheRowAsItWas() {
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{download("d")}}});
    fake->answer("PATCH", "/api/v1/downloads/d", 400, QJsonObject{{"error", "done"}});
    Downloads store(core.get());
    QTRY_COMPARE(store.all().size(), 1);
    store.pause("d");
    QTRY_VERIFY(fake->requests().last().startsWith("PATCH"));
    QTest::qWait(50);
    QCOMPARE(ids(store), QStringList{"d active"});
  }

  void aResetAsksTheCoreAndKeepsTheDocumentItAnswersWith() {
    fake->answer("PATCH", "/api/v1/preferences", 200, QJsonObject{{"accent", "red"}});
    fake->answer("DELETE", "/api/v1/preferences", 200, QJsonObject{{"accent", "white"}});
    Preferences store(core.get());
    store.patch({{"accent", "red"}});
    QTRY_COMPARE(store.current()["accent"], "red");
    store.reset();
    QTRY_COMPARE(store.current()["accent"], "white");
    QVERIFY(store.error().isEmpty());
  }

  void aResetWaitsForAPatchAlreadyOnItsWay() {
    fake->hold("PATCH", "/api/v1/preferences");
    fake->answer("PATCH", "/api/v1/preferences", 200, QJsonObject{{"accent", "red"}});
    fake->answer("DELETE", "/api/v1/preferences", 200, QJsonObject{{"accent", "white"}});
    Preferences store(core.get());
    store.patch({{"accent", "red"}});
    store.reset();
    QTRY_COMPARE(fake->requests().size(), 1);
    QTest::qWait(50);
    QCOMPARE(fake->requests().size(), 1);

    fake->release();
    QTRY_COMPARE(fake->requests().size(), 2);
    QVERIFY(fake->requests().last().startsWith("DELETE"));
    QTRY_COMPARE(store.current()["accent"], "white");
  }

  void aBurstOfOneKeyIsOnePatchAndResetDropsIt() {
    fake->on("PATCH", "/api/v1/preferences",
             [](const QJsonValue &body) { return std::pair{200, body}; });
    fake->answer("DELETE", "/api/v1/preferences", 200, QJsonObject{});
    Preferences store(core.get());
    store.rememberDelay = 20;
    for (const double speed : {1.25, 1.5, 1.75})
      store.remember("speed", speed);
    QTRY_COMPARE(store.current()["speed"], 1.75);
    QCOMPARE(fake->requests(), QStringList{R"(PATCH /api/v1/preferences {"speed":1.75})"});

    store.remember("speed", 2.0);
    store.reset();
    QTRY_COMPARE(fake->requests().size(), 2);
    QTest::qWait(50);
    QCOMPARE(fake->requests().last(), "DELETE /api/v1/preferences");
  }

  void aRefusedAddressStaysAtTheFieldAndTheListDoesNotMove() {
    fake->answer("GET", "/api/v1/addons", 200, QJsonObject{{"addons", FakeCore::fixture("addons.json")}});
    fake->answer("POST", "/api/v1/addons", 400, QJsonObject{{"error", "no manifest there"}});
    Addons store(core.get());
    store.load();
    QTRY_VERIFY(store.loaded());
    const QVariantList before = store.current();
    store.add("https://example.invalid/manifest.json");
    QVERIFY(store.adding());
    QTRY_VERIFY(!store.adding());
    QCOMPARE(store.addError(), "no manifest there");
    QCOMPARE(store.current(), before);
  }

  void anAddonAlreadyGoneIsTakenOffTheList() {
    const QJsonArray addons = FakeCore::fixture("addons.json").toArray();
    fake->answer("GET", "/api/v1/addons", 200, QJsonObject{{"addons", FakeCore::fixture("addons.json")}});
    const QString id = addons.first()["id"].toString();
    fake->answer("DELETE", "/api/v1/addons/" + id, 404, QJsonObject{{"error", "no such addon"}});
    Addons store(core.get());
    store.load();
    QTRY_VERIFY(store.loaded());
    store.remove(id);
    QTRY_COMPARE(store.current().size(), addons.size() - 1);
    QVERIFY(store.error().isEmpty());
  }
};

QTEST_GUILESS_MAIN(StoresTest)
#include "stores_test.moc"
