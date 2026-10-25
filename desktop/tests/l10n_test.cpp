#include "language.h"

#include <QDirIterator>
#include <QRegularExpression>
#include <QtTest>

class L10nTest : public QObject {
  Q_OBJECT

private slots:
  void russianCountsTakeAllThreeOfItsPluralForms() {
    installTranslations(QLocale(QLocale::Russian));
    QCOMPARE(qtTrId("settingsEpisodeCount", 1), "1 серия");
    QCOMPARE(qtTrId("settingsEpisodeCount", 3), "3 серии");
    QCOMPARE(qtTrId("settingsEpisodeCount", 5), "5 серий");
    QCOMPARE(qtTrId("settingsEpisodeCount", 21), "21 серия");
  }

  void aLanguageWithNoTranslationGetsEnglish() {
    for (QTranslator *t : QCoreApplication::instance()->findChildren<QTranslator *>())
      QCoreApplication::removeTranslator(t);
    installTranslations(QLocale(QLocale::Japanese));
    QCOMPARE(qtTrId("settingsEpisodeCount", 21), "21 episodes");
  }

  // qsTrId answers an id it does not know with the id itself, on screen.
  void everyIdTheInterfaceAsksForIsInEnglish() {
    installTranslations(QLocale(QLocale::English));
    QStringList missing;
    const QRegularExpression call("qsTrId\\(\\s*\"([^\"]+)\"");
    QDirIterator files(LUMEO_QML, {"*.qml"}, QDir::Files, QDirIterator::Subdirectories);
    while (files.hasNext()) {
      QFile file(files.next());
      QVERIFY(file.open(QIODevice::ReadOnly));
      for (const auto &match : call.globalMatch(QString::fromUtf8(file.readAll())))
        if (qtTrId(match.captured(1).toUtf8()) == match.captured(1))
          missing.append(match.captured(1));
    }
    QVERIFY2(missing.isEmpty(), qPrintable(missing.join(", ")));
  }
};

QTEST_GUILESS_MAIN(L10nTest)
#include "l10n_test.moc"
