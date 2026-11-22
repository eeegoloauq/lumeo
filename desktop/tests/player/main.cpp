#include "artwork.h"
#include "fakecore.h"
#include "fonts.h"
#include "glyphs.h"
#include "language.h"
#include "mpvitem.h"
#include "pins.h"

#ifdef Q_OS_LINUX
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusVariant>
#endif
#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonArray>
#include <QJsonObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QSslCertificate>
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

#ifdef Q_OS_LINUX
class MediaControls : public QObject {
  Q_OBJECT

public:
  explicit MediaControls(QQmlEngine *engine)
      : QObject(engine), m_engine(engine),
        m_bus(QDBusConnection::connectToBus(QDBusConnection::SessionBus, "player-test-client")) {}

  Q_INVOKABLE void get(const QString &property, const QJSValue &callback) {
    auto message = request("org.freedesktop.DBus.Properties", "Get");
    message << QString(playerInterface) << property;
    send(message, callback);
  }

  Q_INVOKABLE void command(const QString &method, const QJSValue &callback) {
    send(request(playerInterface, method), callback);
  }

  Q_INVOKABLE void seek(qlonglong offset, const QJSValue &callback) {
    auto message = request(playerInterface, "Seek");
    message << offset;
    send(message, callback);
  }

private:
  static constexpr auto playerInterface = "org.mpris.MediaPlayer2.Player";

  static QDBusMessage request(const QString &interface, const QString &method) {
    return QDBusMessage::createMethodCall("org.mpris.MediaPlayer2.lumeo", "/org/mpris/MediaPlayer2",
                                          interface, method);
  }

  void send(const QDBusMessage &message, const QJSValue &callback) {
    auto *watcher = new QDBusPendingCallWatcher(m_bus.asyncCall(message), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, callback](QDBusPendingCallWatcher *finished) {
      const auto reply = finished->reply();
      finished->deleteLater();
      QVariant value = reply.arguments().value(0).value<QDBusVariant>().variant();
      if (value.metaType() == QMetaType::fromType<QDBusArgument>())
        value = qdbus_cast<QVariantMap>(value.value<QDBusArgument>());
      callback.call({QJSValue(reply.type() == QDBusMessage::ReplyMessage),
                     m_engine->toScriptValue(value)});
    });
  }

  QQmlEngine *m_engine;
  QDBusConnection m_bus;
};
#endif

// What only a real libmpv can show, on headless Weston: tool/player-test.sh
// runs it with the clips it makes, which the fake core streams as downloads:
// d1 a test card in two chapters, dt one with tracks, e1 an episode with a
// named ending (decisions/testing.md, Player tests).
class Setup : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;
  // A core serving its own certificate, pinned as pairing pins it.
  std::unique_ptr<FakeCore> own;
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
    qputenv("XDG_CACHE_HOME", config.filePath("cache").toUtf8());
    qputenv("XDG_STATE_HOME", config.filePath("state").toUtf8());
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
    // A trailer: a link from outside the core, as YouTube's is.
    QFile trailer(qEnvironmentVariable("LUMEO_TEST_CLIP"));
    const QByteArray trailerClip = trailer.open(QIODevice::ReadOnly) ? trailer.readAll() : QByteArray();
    fake->file("/trailer", trailerClip, "video/x-matroska");
    QFile upright(qEnvironmentVariable("LUMEO_TEST_UPRIGHT"));
    if (upright.open(QIODevice::ReadOnly))
      fake->file("/trailer-upright", upright.readAll(), "video/x-matroska");
    own = std::make_unique<FakeCore>();
    if (!own->listenTLS(LUMEO_TEST_TLS))
      qFatal("the fake core with its own certificate could not listen");
    own->file("/trailer", trailerClip, "video/x-matroska");
    QFile identity(LUMEO_TEST_TLS);
    if (!identity.open(QIODevice::ReadOnly))
      qFatal("no test certificate");
    Pins::add(own->address(), QSslCertificate(identity.readAll()));
    // A subtitle as the core serves one from the database, converted.
    fake->file("/api/v1/subtitles/ru", "1\n00:00:00,000 --> 00:00:20,000\nRussian\n", "text/plain");
    installTranslations(QLocale(QLocale::English));
    loadFonts();
  }

  void qmlEngineAvailable(QQmlEngine *engine) {
    engine->rootContext()->setContextProperty("fakeCore", fake.get());
    engine->rootContext()->setContextProperty("ownCore", own.get());
    engine->rootContext()->setContextProperty("screenshots", config.filePath("shots"));
    engine->rootContext()->setContextProperty("disk", &disk);
#ifdef Q_OS_LINUX
    engine->rootContext()->setContextProperty("mediaControls", new MediaControls(engine));
#endif
    Artwork::install(engine);
    Glyphs::install(engine);
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
