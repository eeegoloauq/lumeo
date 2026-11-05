#include "core.h"
#include "fakecore.h"
#include "releases.h"
#include "settings.h"

#include <QJsonObject>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QtTest>

namespace {

// The items alone, for what is not about the headings.
QStringList items(const QVariantList &groups) {
  QStringList all;
  for (const QVariant &group : groups)
    all += group.toMap().value("items").toStringList();
  return all;
}

} // namespace

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
    QCOMPARE(items(Releases::between(source, {}, "1.2.3", "ru")), (QStringList{"Русский пункт", "Ещё один"}));
    QCOMPARE(items(Releases::between(source, {}, "1.2.3", "en")), QStringList{"Default item"});
    QCOMPARE(items(Releases::between(source, {}, "1.2.4", "ru")), QStringList{"Next release"});
    QCOMPARE(items(Releases::between(source, {}, "1.2.5", "en")), QStringList());
  }

  void skippedReleasesAreToldTogetherNewestFirst() {
    const QString source = R"(<component><releases>
      <release version="0.2.1"><description><ul><li>Newest</li></ul></description></release>
      <release version="0.2.0"><description><ul><li>Middle</li></ul></description></release>
      <release version="0.1.9"><description><ul><li>Seen</li></ul></description></release>
    </releases></component>)";
    QCOMPARE(items(Releases::between(source, "0.1.9", "0.2.1", "en")), (QStringList{"Newest", "Middle"}));
    QCOMPARE(items(Releases::between(source, "0.1.9", "0.2.0", "en")), QStringList{"Middle"});
    // Updated from a copy that kept no version: only this release is news.
    QCOMPARE(items(Releases::between(source, "", "0.2.1", "en")), QStringList{"Newest"});
  }

  void betasTellTheirOwnChangesAndTheReleaseSumsThemUp() {
    const QString source = R"(<component><releases>
      <release version="0.2.0"><description><ul><li>Sum</li></ul></description></release>
      <release version="0.2.0~beta.2" type="development"><description><ul><li>Second</li></ul></description></release>
      <release version="0.2.0~beta.1" type="development"><description><ul><li>First</li></ul></description></release>
      <release version="0.1.9"><description><ul><li>Out</li></ul></description></release>
    </releases></component>)";
    QCOMPARE(items(Releases::between(source, {}, "0.2.0-beta.2", "en")), QStringList{"Second"});
    QCOMPARE(items(Releases::between(source, "0.2.0-beta.1", "0.2.0-beta.2", "en")), QStringList{"Second"});
    QCOMPARE(items(Releases::between(source, "0.1.9", "0.2.0-beta.2", "en")), (QStringList{"Second", "First"}));
    QCOMPARE(items(Releases::between(source, "0.1.9", "0.2.0", "en")), QStringList{"Sum"});
    QCOMPARE(items(Releases::between(source, "0.2.0-beta.2", "0.2.0", "en")), QStringList{"Sum"});
    QVERIFY(Releases::toldInBetas("0.2.0-beta.2", "0.2.0"));
    QVERIFY(!Releases::toldInBetas("0.1.9", "0.2.0"));
    QVERIFY(!Releases::toldInBetas("0.2.0-beta.1", "0.2.0-beta.2"));
  }

  // Each release's items go under their heading, translated with them, in
  // the order Added, Improved, Fixed, Removed whatever order a release used.
  void notesAreGroupedUnderTheirHeadings() {
    const QString source = R"(<component><releases>
      <release version="0.2.0~beta.2"><description>
        <p>Fixed</p><p xml:lang="ru">Исправлено</p>
        <ul><li>Second fix</li><li xml:lang="ru">Второе исправление</li></ul>
        <p>Added</p><p xml:lang="ru">Добавлено</p>
        <ul><li>Second thing</li><li xml:lang="ru">Вторая вещь</li></ul>
      </description></release>
      <release version="0.2.0~beta.1"><description>
        <p>Fixed</p><p xml:lang="ru">Исправлено</p>
        <ul><li>First fix</li><li xml:lang="ru">Первое исправление</li></ul>
      </description></release>
      <release version="0.1.9"><description><ul><li>Before headings</li></ul></description></release>
    </releases></component>)";
    const auto group = [](const QString &title, const QStringList &items) {
      return QVariant(QVariantMap{{"title", title}, {"items", items}});
    };
    QCOMPARE(Releases::between(source, "0.1.9", "0.2.0-beta.2", "en"),
             (QVariantList{group("Added", {"Second thing"}), group("Fixed", {"Second fix", "First fix"})}));
    QCOMPARE(Releases::between(source, "0.1.9", "0.2.0-beta.2", "ru"),
             (QVariantList{group("Добавлено", {"Вторая вещь"}),
                           group("Исправлено", {"Второе исправление", "Первое исправление"})}));
    QCOMPARE(Releases::between(source, "0.1.8", "0.2.0-beta.1", "en"),
             (QVariantList{group("", {"Before headings"}), group("Fixed", {"First fix"})}));
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
    QCOMPARE(items(releases.updateNotes()), QStringList{"Episodes remember their subtitle track."});

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
