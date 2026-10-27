#include "settings.h"

#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QtTest>

namespace {

QJsonObject read(const QString &path) {
  QFile file(path);
  return file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll()).object()
                                        : QJsonObject();
}

void write(const QString &path, const QJsonObject &values) {
  QFile file(path);
  QVERIFY(file.open(QIODevice::WriteOnly));
  file.write(QJsonDocument(values).toJson());
}

} // namespace

class SettingsTest : public QObject {
  Q_OBJECT

  QTemporaryDir dir;
  QString path;

private slots:
  void init() { path = dir.filePath("client.json"); QFile::remove(path); }

  // A file an earlier version wrote: what this one does not read stays.
  void keysItDoesNotReadAreKept() {
    write(path, {{"volume", 40}, {"listSort", "title"}, {"lastSeenVersion", "0.1.79"}});
    {
      LocalSettings settings(path);
      QCOMPARE(settings.volume(), 40.0);
      settings.setVolume(55);
    }
    const QJsonObject kept = read(path);
    QCOMPARE(kept["volume"].toDouble(), 55.0);
    QCOMPARE(kept["listSort"].toString(), "title");
    QCOMPARE(kept["lastSeenVersion"].toString(), "0.1.79");
  }

  // A film mixed loud is turned up past 100 on purpose, not every time.
  void theVolumeComesBackAtMostFull() {
    write(path, {{"volume", 140}});
    QCOMPARE(LocalSettings(path).volume(), 100.0);
  }

  // A login launch has no window to close, so it needs the background.
  void startingAtLoginAndTheBackgroundCarryEachOther() {
    LocalSettings settings(path);
    settings.setAutostart(true);
    QVERIFY(settings.background());
    settings.setBackground(false);
    QVERIFY(!settings.autostart());
    settings.setBackground(true);
    QVERIFY(!settings.autostart());
  }

  void noFileIsTheDefaults() { QCOMPARE(LocalSettings(path).volume(), 100.0); }

  // Qt takes the scale as the application starts, so a new one waits for
  // the next run, which reads it from the file.
  void aTextSizeWaitsForTheNextStart() {
    QCOMPARE(LocalSettings::scaleIn(path), 1.0);
    {
      LocalSettings settings(path);
      settings.setTextScale("huge");
      QVERIFY(!settings.textScaleWaits());
      settings.setTextScale("large");
      QVERIFY(settings.textScaleWaits());
    }
    QCOMPARE(LocalSettings::scaleIn(path), 1.15);
    LocalSettings next(path);
    QVERIFY(!next.textScaleWaits());
    next.resetChoices();
    QCOMPARE(next.textScale(), "default");
  }
};

QTEST_GUILESS_MAIN(SettingsTest)
#include "settings_test.moc"
