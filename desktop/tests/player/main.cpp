#include "fakecore.h"
#include "fonts.h"
#include "language.h"
#include "mpvitem.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <QTemporaryDir>
#include <QtQml/QQmlExtensionPlugin>
#include <QtQuickTest>
#include <clocale>

Q_IMPORT_QML_PLUGIN(LumeoPlugin)

// What a test reads off the disk.
class Disk : public QObject {
  Q_OBJECT

public:
  Q_INVOKABLE QStringList list(const QString &dir) const { return QDir(dir).entryList(QDir::Files); }
};

// What only a real libmpv can show, on headless Weston: tool/player-test.sh
// runs it with the clips it makes, which the fake core streams as downloads:
// d1 a test card in two chapters, dt one with tracks, e1 an episode with a
// named ending (decisions/testing.md, Player tests).
class Setup : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  QTemporaryDir config;
  Disk disk;

public slots:
  void applicationAvailable() {
    // As main() sets them: mpv draws in desktop GL and needs C numbers.
    std::setlocale(LC_NUMERIC, "C");
    // llvmpipe cannot draw mpv's default scalers in time.
    MpvItem::profile = "fast";
    // client.json is the test's, not the machine's, and so are the
    // screenshots it sends to a folder of their own.
    qputenv("XDG_CONFIG_HOME", config.path().toUtf8());
    QDir().mkpath(config.filePath("lumeo"));
    QFile settings(config.filePath("lumeo/client.json"));
    if (!settings.open(QIODevice::WriteOnly))
      qFatal("no client.json for the tests");
    settings.write(QJsonDocument(QJsonObject{{"screenshotsDir", config.filePath("shots")}}).toJson());
    settings.close();
    fake = std::make_unique<FakeCore>();
    if (!fake->listen())
      qFatal("the fake core could not listen");
    qputenv("LUMEO_CORE", fake->address().toString().toUtf8());
    fake->answer("GET", "/api/v1/preferences", 200, FakeCore::fixture("preferences.json"));
    fake->answer("GET", "/api/v1/preferences/languages", 200,
                 QJsonObject{{"languages", FakeCore::fixture("languages.json")}});
    fake->answer("GET", "/api/v1/downloads", 200, QJsonObject{{"downloads", QJsonArray()}});
    // The window's home, behind the film.
    fake->answer("GET", "/api/v1/catalogs", 200, QJsonObject{{"catalogs", QJsonArray()}});
    fake->answer("GET", "/api/v1/continue", 200, QJsonArray());
    for (const auto &[variable, id] : {std::pair{"LUMEO_TEST_CLIP", "d1"}, {"LUMEO_TEST_TRACKS", "dt"},
                                       {"LUMEO_TEST_EPISODE", "e1"}}) {
      QFile clip(qEnvironmentVariable(variable));
      if (!clip.open(QIODevice::ReadOnly))
        qFatal("%s names no clip: run tool/player-test.sh", variable);
      fake->file(QString("/api/v1/downloads/%1/stream").arg(id), clip.readAll(), "video/x-matroska");
    }
    // A subtitle as the core serves one from the database, converted.
    fake->file("/api/v1/subtitles/ru", "1\n00:00:00,000 --> 00:00:20,000\nRussian\n", "text/plain");
    installTranslations(QLocale(QLocale::English));
    loadFonts();
  }

  void qmlEngineAvailable(QQmlEngine *engine) {
    engine->rootContext()->setContextProperty("fakeCore", fake.get());
    engine->rootContext()->setContextProperty("screenshots", config.filePath("shots"));
    engine->rootContext()->setContextProperty("disk", &disk);
  }
};

int main(int argc, char **argv) {
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
  QSurfaceFormat format = QSurfaceFormat::defaultFormat();
  format.setRenderableType(QSurfaceFormat::OpenGL);
  QSurfaceFormat::setDefaultFormat(format);
  QTEST_SET_MAIN_SOURCE_PATH
  Setup setup;
  return quick_test_main_with_setup(argc, argv, "player", QUICK_TEST_SOURCE_DIR, &setup);
}

#include "main.moc"
