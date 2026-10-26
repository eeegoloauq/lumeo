#include "artwork.h"
#include "background.h"
#include "fonts.h"
#include "instance.h"
#include "language.h"
#include "mpvfacts.h"
#include "settings.h"

#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
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
  // QApplication rather than QGuiApplication for the tray's menu, which is a
  // QMenu where the system has no menus of its own to offer.
  QApplication app(argc, argv);
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
  // The controls are drawn the app's way; Basic is the style meant for that.
  QQuickStyle::setStyle("Basic");

  // Asked now: a title page needs to know what this machine decodes before
  // anything plays.
  MpvFacts::instance();

  QQmlApplicationEngine engine;
  // The chosen language from the first frame, and every text again when
  // another is chosen.
  auto *settings = engine.singletonInstance<LocalSettings *>("Lumeo", "LocalSettings");
  Background background(settings, instance.ownsCore());
  const auto speak = [&engine, &background, settings] {
    QLocale::setDefault(settings->locale());
    installTranslations(settings->locale());
    engine.retranslate();
    background.retranslate();
  };
  speak();
  QObject::connect(settings, &LocalSettings::languageChanged, &engine, speak);
  Artwork::install(&engine);
  QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                   [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
  engine.loadFromModule("Lumeo", "Main");
  return app.exec();
}
