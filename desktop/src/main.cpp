#include "artwork.h"
#include "background.h"
#include "fonts.h"
#include "instance.h"
#include "language.h"
#include "mpvfacts.h"
#include "releases.h"
#include "settings.h"

#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <QtQml/QQmlExtensionPlugin>
#include <clocale>

// The module is a static library, shared with the tests.
Q_IMPORT_QML_PLUGIN(LumeoPlugin)

int main(int argc, char *argv[]) {
  // mpv draws through its render API in desktop GL, so the scene graph has
  // to be GL too rather than Vulkan.
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
  // And desktop GL rather than GLES, which Qt picks on Wayland with NVIDIA's
  // driver: there mpv declares mediump textures and NVIDIA reads them at
  // that precision (Anime4K's orange came out green under Flutter).
  QSurfaceFormat format = QSurfaceFormat::defaultFormat();
  format.setRenderableType(QSurfaceFormat::OpenGL);
  QSurfaceFormat::setDefaultFormat(format);
  // The text size scales the whole interface through Qt's own factor, which
  // Qt reads only here; on top of one the environment set. Put back after:
  // a folder or a link this app opens would be drawn at it too.
  const QByteArray outerScale = qgetenv("QT_SCALE_FACTOR");
  const double scale = LocalSettings::scaleIn(LocalSettings::file());
  bool outerSet = false;
  const double outer = outerScale.toDouble(&outerSet);
  if (scale != 1)
    qputenv("QT_SCALE_FACTOR", QByteArray::number(scale * (outerSet ? outer : 1)));
  // QApplication rather than QGuiApplication for the tray's menu, which is a
  // QMenu where the system has no menus of its own to offer.
  QApplication app(argc, argv);
  if (outerScale.isEmpty())
    qunsetenv("QT_SCALE_FACTOR");
  else
    qputenv("QT_SCALE_FACTOR", outerScale);
  QGuiApplication::setApplicationName("lumeo");
  QGuiApplication::setApplicationDisplayName("Lumeo");
  QGuiApplication::setApplicationVersion(LUMEO_VERSION);
  QGuiApplication::setDesktopFileName("dev.lumeo.lumeo");
  Instance instance(app.arguments());
  if (!instance.start())
    return 0;
  // Closing the window may only hide it; Main says when the app ends.
  QGuiApplication::setQuitOnLastWindowClosed(false);
  loadFonts();
  // libmpv refuses to start under a locale that writes 1,5 for 1.5, and Qt
  // has just set the one from the environment.
  std::setlocale(LC_NUMERIC, "C");

  // Asked now: a title page needs to know what this machine decodes before
  // anything plays.
  MpvFacts::instance();
  MpvFacts::updateYtdl();

  QQmlApplicationEngine engine;
  // The chosen language from the first frame, and every text again when
  // another is chosen.
  auto *settings = engine.singletonInstance<LocalSettings *>("Lumeo", "LocalSettings");
  Background background(settings, instance.ownsCore());
  auto *releases = engine.singletonInstance<Releases *>("Lumeo", "Releases");
  const auto speak = [&engine, &background, settings, releases] {
    QLocale::setDefault(settings->locale());
    installTranslations(settings->locale());
    engine.retranslate();
    background.retranslate();
    releases->setLanguage(settings->locale().name().section('_', 0, 0));
  };
  speak();
  QObject::connect(settings, &LocalSettings::languageChanged, &engine, speak);
  Artwork::install(&engine);
  QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                   [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
  engine.loadFromModule("Lumeo", "Main");
  return app.exec();
}
