#include "artwork.h"
#include "fakecore.h"
#include "fonts.h"
#include "language.h"
#include "mpvfacts.h"

#include <QJsonObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QTemporaryDir>
#include <QtQml/QQmlExtensionPlugin>
#include <QtQuickTest>

Q_IMPORT_QML_PLUGIN(LumeoPlugin)

// The whole app over the fake core: a test drives Shell as the window holds
// it, presses the keys rather than calling the handlers, and reads what
// reached the core from fakeCore (decisions/testing.md, App tests).
class Setup : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  // What the app writes to its folders goes here, not to the machine's.
  QTemporaryDir folders;

public slots:
  void applicationAvailable() {
    qputenv("XDG_CONFIG_HOME", folders.filePath("config").toUtf8());
    qputenv("XDG_CACHE_HOME", folders.filePath("cache").toUtf8());
    qputenv("XDG_STATE_HOME", folders.filePath("state").toUtf8());
    // Made here: a QObject's timers need the application's event loop.
    fake = std::make_unique<FakeCore>();
    if (!fake->listen())
      qFatal("the fake core could not listen");
    // Read by Core when the first screen asks for it; a core named by
    // address is sent no token.
    qputenv("LUMEO_CORE", fake->address().toString().toUtf8());
    fake->answer("GET", "/api/v1/preferences", 200, FakeCore::fixture("preferences.json"));
    fake->answer("GET", "/api/v1/preferences/languages", 200,
                QJsonObject{{"languages", FakeCore::fixture("languages.json")}});
    fake->answer("GET", "/api/v1/downloads", 200, QJsonObject{{"downloads", QJsonArray()}});
    fake->answer("GET", "/api/v1/catalogs", 200,
                 QJsonObject{{"catalogs", FakeCore::fixture("catalogs.json")}});
    fake->answer("GET", "/api/v1/catalog", 200, QJsonObject{{"items", FakeCore::fixture("items.json")}});
    fake->answer("GET", "/api/v1/continue", 200, QJsonArray());
    // Nothing here reaches YouTube: a test that wants a trailer says yt-dlp
    // is there.
    MpvFacts::instance()->setProperty("ytdl", false);
    installTranslations(QLocale(QLocale::English));
    loadFonts();
  }

  void qmlEngineAvailable(QQmlEngine *engine) {
    engine->rootContext()->setContextProperty("fakeCore", fake.get());
    Artwork::install(engine);
  }
};

QUICK_TEST_MAIN_WITH_SETUP(app, Setup)
#include "main.moc"
