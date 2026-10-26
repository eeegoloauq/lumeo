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

  // The Flutter client's file: what this one does not read yet stays.
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

  void noFileIsTheDefaults() { QCOMPARE(LocalSettings(path).volume(), 100.0); }
};

QTEST_GUILESS_MAIN(SettingsTest)
#include "settings_test.moc"
