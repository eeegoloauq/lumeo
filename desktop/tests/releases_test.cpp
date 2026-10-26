#include "core.h"
#include "fakecore.h"
#include "releases.h"
#include "settings.h"

#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

class ReleasesTest : public QObject {
  Q_OBJECT

  QTemporaryDir dir;

private slots:
  void notesAreInTheInterfaceLanguageOrUntagged() {
    const QString source = R"(<component><releases>
      <release version="1.2.3"><description><ul>
        <li>Default  item</li><li xml:lang="ru">Русский пункт</li>
        <li xml:lang="ru">Ещё один</li>
      </ul></description></release>
      <release version="1.2.4"><description><ul><li>Next release</li></ul></description></release>
    </releases></component>)";
    QCOMPARE(Releases::between(source, {}, "1.2.3", "ru"), (QStringList{"Русский пункт", "Ещё один"}));
    QCOMPARE(Releases::between(source, {}, "1.2.3", "en"), QStringList{"Default item"});
    QCOMPARE(Releases::between(source, {}, "1.2.4", "ru"), QStringList{"Next release"});
    QCOMPARE(Releases::between(source, {}, "1.2.5", "en"), QStringList());
  }

  void skippedReleasesAreToldTogetherNewestFirst() {
    const QString source = R"(<component><releases>
      <release version="0.2.1"><description><ul><li>Newest</li></ul></description></release>
      <release version="0.2.0"><description><ul><li>Middle</li></ul></description></release>
      <release version="0.1.9"><description><ul><li>Seen</li></ul></description></release>
    </releases></component>)";
    QCOMPARE(Releases::between(source, "0.1.9", "0.2.1", "en"), (QStringList{"Newest", "Middle"}));
    QCOMPARE(Releases::between(source, "0.1.9", "0.2.0", "en"), QStringList{"Middle"});
    // Updated from a copy that kept no version: only this release is news.
    QCOMPARE(Releases::between(source, "", "0.2.1", "en"), QStringList{"Newest"});
  }

  void betasTellTheirOwnChangesAndTheReleaseSumsThemUp() {
    const QString source = R"(<component><releases>
      <release version="0.2.0"><description><ul><li>Sum</li></ul></description></release>
      <release version="0.2.0~beta.2" type="development"><description><ul><li>Second</li></ul></description></release>
      <release version="0.2.0~beta.1" type="development"><description><ul><li>First</li></ul></description></release>
      <release version="0.1.9"><description><ul><li>Out</li></ul></description></release>
    </releases></component>)";
    QCOMPARE(Releases::between(source, {}, "0.2.0-beta.2", "en"), QStringList{"Second"});
    QCOMPARE(Releases::between(source, "0.2.0-beta.1", "0.2.0-beta.2", "en"), QStringList{"Second"});
    QCOMPARE(Releases::between(source, "0.1.9", "0.2.0-beta.2", "en"), (QStringList{"Second", "First"}));
    QCOMPARE(Releases::between(source, "0.1.9", "0.2.0", "en"), QStringList{"Sum"});
    QCOMPARE(Releases::between(source, "0.2.0-beta.2", "0.2.0", "en"), QStringList{"Sum"});
    QVERIFY(Releases::toldInBetas("0.2.0-beta.2", "0.2.0"));
    QVERIFY(!Releases::toldInBetas("0.1.9", "0.2.0"));
    QVERIFY(!Releases::toldInBetas("0.2.0-beta.1", "0.2.0-beta.2"));
  }

  // A closed notice keeps that version quiet, and any other for a week.
  void aClosedNoticeKeepsTheNextOnesQuiet() {
    FakeCore fake;
    QVERIFY(fake.listen());
    fake.answer("GET", "/api/v1/update", 200, FakeCore::fixture("update.json"));
    Core core(fake.address(), QString());
    const QString path = dir.filePath("client.json");
    LocalSettings settings(path);
    Releases releases(&core, &settings, "0.2.0", {});
    QSignalSpy changed(&releases, &Releases::changed);
    releases.check();
    QVERIFY(changed.wait());
    QCOMPARE(releases.update(), "0.2.1");
    QCOMPARE(releases.updateNotes(), QStringList{"Episodes remember their subtitle track."});

    releases.dismissUpdate();
    QCOMPARE(releases.update(), QString());
    fake.answer("GET", "/api/v1/update", 200,
                QJsonObject{{"version", "0.2.2"}, {"url", ""}, {"notes", ""}});
    releases.check();
    QTRY_COMPARE(fake.requests().filter("/api/v1/update").size(), 2);
    QTest::qWait(50);
    QCOMPARE(releases.update(), QString());
  }
};

QTEST_GUILESS_MAIN(ReleasesTest)
#include "releases_test.moc"
