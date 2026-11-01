#include "addons.h"
#include "core.h"
#include "downloads.h"
#include "fakecore.h"
#include "personaldata.h"
#include "preferences.h"
#include "viewing.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
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

  // Seen 2026-11-01 on Windows CI: a poll asked after Stop and answered
  // before the core removed the download put its row back.
  void aStoppedDownloadStaysGoneWhileTheStopIsOnItsWay() {
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{download("d")}}});
    fake->hold("DELETE", "/api/v1/downloads/d");
    Downloads store(core.get());
    QTRY_COMPARE(store.all().size(), 1);
    store.stop("d");
    QVERIFY(store.all().isEmpty());
    store.refresh();
    QTRY_COMPARE(fake->requests().count("GET /api/v1/downloads"), 2);
    QTest::qWait(50);
    QVERIFY(store.all().isEmpty());
    // What was left unread meanwhile is read once the stop is done, not at
    // the next poll.
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads", QJsonArray{download("e")}}});
    fake->release();
    QTRY_COMPARE(ids(store), QStringList{"e active"});
  }

  // Seen 2026-09-30: a ring nearly full sat on a series whose episode was on
  // disk, summed with a copy left paused half way.
  void aPosterMarksWhatIsArrivingElseWhatIsOnDisk() {
    auto row = [](const QString &id, const QString &state, int episode, int got) {
      return QJsonObject{{"id", id}, {"itemId", "tt1"}, {"season", 1}, {"episode", episode},
                         {"state", state},
                         {"progress", QJsonObject{{"completed", got}, {"total", 100}}}};
    };
    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads",
                              QJsonArray{row("e1", "done", 1, 100), row("e2", "paused", 2, 50)}}});
    Downloads store(core.get());
    QTRY_VERIFY(!store.marks().isEmpty());
    QCOMPARE(store.marks()["tt1"], QVariantMap({{"done", true}}));
    QVERIFY2(!store.marks().contains("tt1/1/2"), "paused half way is not a state of the episode");
    QVERIFY(!store.marks().contains("tt2"));

    fake->answer("GET", "/api/v1/downloads", 200,
                 QJsonObject{{"downloads",
                              QJsonArray{row("e1", "done", 1, 100), row("e2", "active", 2, 50)}}});
    store.refresh();
    QTRY_COMPARE(store.marks()["tt1"], QVariantMap({{"fraction", 0.5}}));
    QCOMPARE(store.marks()["tt1/1/1"], QVariantMap({{"done", true}}));
  }

  // Each mark is one request, and changed() names the title once the core
  // has it, which is when a page reads it again.
  void marksReachTheCoreAndSayWhichTitleChanged() {
    fake->answer("PUT", "/api/v1/progress/tt1", 200, QJsonObject());
    fake->answer("POST", "/api/v1/progress/tt1/watched-through", 200, QJsonObject());
    fake->answer("DELETE", "/api/v1/continue/tt1", 204);
    Viewing viewing(core.get());
    QSignalSpy changed(&viewing, &Viewing::changed);
    viewing.mark("tt1", 1, 2, false);
    viewing.markThrough("tt1", 2, 3);
    viewing.markThrough("tt1");
    viewing.hide("tt1");
    QTRY_COMPARE(changed.size(), 4);
    QCOMPARE(changed.first().first().toString(), "tt1");
    const QStringList sent = fake->requests();
    QVERIFY(sent.contains(R"(PUT /api/v1/progress/tt1 {"episode":2,"season":1,"watched":false})"));
    QVERIFY(sent.contains(R"(POST /api/v1/progress/tt1/watched-through {"episode":3,"season":2})"));
    QVERIFY(sent.contains(R"(POST /api/v1/progress/tt1/watched-through {})"));
    QVERIFY(sent.contains("DELETE /api/v1/continue/tt1"));
  }

  // The finished titles come as a map for a poster to look up, and a mark
  // the core took reads them again: the eye follows the menu.
  void aMarkReadsTheFinishedTitlesAgain() {
    fake->answer("GET", "/api/v1/finished", 200, QJsonObject{{"items", QJsonArray{"tt1"}}});
    fake->answer("PUT", "/api/v1/progress/tt2", 200, QJsonObject());
    Viewing viewing(core.get());
    viewing.refresh();
    QTRY_COMPARE(viewing.finished(), QVariantMap({{"tt1", true}}));

    fake->answer("GET", "/api/v1/finished", 200, QJsonObject{{"items", QJsonArray{"tt1", "tt2"}}});
    viewing.mark("tt2", 0, 0, true);
    QTRY_COMPARE(viewing.finished(), QVariantMap({{"tt1", true}, {"tt2", true}}));
  }

  // A title forgotten waits for its undo before the core is told; a second
  // one forgets the first at once.
  void aTitleIsForgottenOnceItsUndoIsOver() {
    fake->answer("DELETE", "/api/v1/progress/tt1", 204);
    fake->answer("DELETE", "/api/v1/progress/tt2", 500);
    Viewing viewing(core.get());
    viewing.setUndoTime(60000);
    QSignalSpy changed(&viewing, &Viewing::changed);
    QSignalSpy refused(&viewing, &Viewing::refused);

    viewing.forget("tt1");
    QCOMPARE(viewing.forgetting(), "tt1");
    viewing.undo();
    QCOMPARE(viewing.forgetting(), QString());
    viewing.forget("tt1");
    QTest::qWait(50);
    QVERIFY(fake->requests().filter("DELETE").isEmpty());

    viewing.forget("tt2");
    QCOMPARE(viewing.forgetting(), "tt2");
    QTRY_COMPARE(changed.size(), 1);
    QCOMPARE(changed.first().first().toString(), "tt1");

    viewing.undo();
    viewing.setUndoTime(10);
    viewing.forget("tt2");
    QTRY_COMPARE(refused.size(), 1);
    QCOMPARE(refused.first().first().toString(), "forget");
    QCOMPARE(fake->requests().filter("DELETE /api/v1/progress/tt2").size(), 1);
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
  void anExportSavesWhatTheCoreWrote() {
    const QJsonObject written{{"format", "lumeo-personal"}, {"version", 1}, {"titles", QJsonArray()}};
    fake->answer("GET", "/api/v1/personal", 200, written);
    Preferences preferences(core.get());
    PersonalData data(core.get(), &preferences);
    QSignalSpy exported(&data, &PersonalData::exported);
    QTemporaryDir dir;
    const QString path = dir.filePath("lumeo.json");
    data.exportTo(path);
    QTRY_COMPARE(exported.size(), 1);
    QFile saved(path);
    QVERIFY(saved.open(QIODevice::ReadOnly));
    QCOMPARE(QJsonDocument::fromJson(saved.readAll()).object(), written);
    QVERIFY(!data.busy());
    QVERIFY(data.error().isEmpty());
  }

  void anExportTheCoreRefusesLeavesNoFile() {
    fake->answer("GET", "/api/v1/personal", 500, QJsonObject{{"error", "disk I/O error"}});
    Preferences preferences(core.get());
    PersonalData data(core.get(), &preferences);
    QTemporaryDir dir;
    const QString path = dir.filePath("lumeo.json");
    data.exportTo(path);
    QTRY_COMPARE(data.error(), "disk I/O error");
    QVERIFY(!data.busy());
    QVERIFY(!QFile::exists(path));
  }

  // The core checks the file; the client carries it as it is, and says how
  // much it changed. Preferences it changed are read again, being held here.
  void anImportSendsTheFileAsItIsAndSaysHowMuchChanged() {
    fake->answer("POST", "/api/v1/personal", 200, FakeCore::fixture("personal-counts.json"));
    fake->answer("GET", "/api/v1/preferences", 200, FakeCore::fixture("preferences.json"));
    Preferences preferences(core.get());
    PersonalData data(core.get(), &preferences);
    QSignalSpy imported(&data, &PersonalData::imported);
    QTemporaryDir dir;
    const QString path = dir.filePath("lumeo.json");
    const QByteArray file = R"({"format": "lumeo-personal", "version": 1, "titles": []})";
    {
      QFile out(path);
      QVERIFY(out.open(QIODevice::WriteOnly));
      out.write(file);
    }
    data.importFrom(path);
    QTRY_COMPARE(imported.size(), 1);
    QCOMPARE(fake->requests().first(), "POST /api/v1/personal " + QString::fromUtf8(file));
    const QJsonObject counts = FakeCore::fixture("personal-counts.json").toObject();
    int entries = 0;
    for (auto it = counts.begin(); it != counts.end(); ++it)
      entries += it.key() == "titles" ? 0 : it.value().toInt();
    QCOMPARE(imported.first().first().toInt(), entries);
    QTRY_VERIFY(fake->requests().contains("GET /api/v1/preferences"));
  }

  void anImportTheCoreRefusesSaysWhy() {
    fake->answer("POST", "/api/v1/personal", 400, QJsonObject{{"error", "tt1: rating must be between 1 and 10"}});
    Preferences preferences(core.get());
    PersonalData data(core.get(), &preferences);
    QSignalSpy imported(&data, &PersonalData::imported);
    QTemporaryDir dir;
    const QString path = dir.filePath("lumeo.json");
    {
      QFile out(path);
      QVERIFY(out.open(QIODevice::WriteOnly));
      out.write("{}");
    }
    data.importFrom(path);
    QTRY_COMPARE(data.error(), "tt1: rating must be between 1 and 10");
    QVERIFY(!data.busy());
    QCOMPARE(imported.size(), 0);
  }

  void aFileTooLargeForPersonalDataIsNotSent() {
    Preferences preferences(core.get());
    PersonalData data(core.get(), &preferences);
    QTemporaryDir dir;
    const QString path = dir.filePath("film.mkv");
    {
      QFile out(path);
      QVERIFY(out.open(QIODevice::WriteOnly));
      QVERIFY(out.resize(PersonalData::largest + 1));
    }
    data.importFrom(path);
    QCOMPARE(data.error(), qtTrId("personalTooLarge"));
    QVERIFY(!data.busy());
    // Refused before anything is sent, so nothing can still be on its way.
    QVERIFY(fake->requests().isEmpty());
  }
};

QTEST_GUILESS_MAIN(StoresTest)
#include "stores_test.moc"
