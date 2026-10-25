#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <clocale>

int main(int argc, char *argv[]) {
  // mpv draws through its render API in desktop GL, so the scene graph has
  // to be GL too rather than Vulkan.
  QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
  QGuiApplication app(argc, argv);
  QGuiApplication::setApplicationName("lumeo");
  QGuiApplication::setApplicationDisplayName("Lumeo");
  QGuiApplication::setDesktopFileName("dev.lumeo.lumeo");
  // libmpv refuses to start under a locale that writes 1,5 for 1.5, and Qt
  // has just set the one from the environment.
  std::setlocale(LC_NUMERIC, "C");
  // The controls are drawn the app's way; Basic is the style meant for that.
  QQuickStyle::setStyle("Basic");

  QQmlApplicationEngine engine;
  const QStringList args = app.arguments();
  engine.setInitialProperties({{"toOpen", args.size() > 1 ? args.at(1) : QString()}});
  QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                   [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
  engine.loadFromModule("Lumeo", "Main");
  return app.exec();
}
