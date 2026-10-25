#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickWindow>
#include <QSurfaceFormat>
#include <QtQml/QQmlExtensionPlugin>
#include <QtQuickTest>
#include <clocale>

Q_IMPORT_QML_PLUGIN(LumeoPlugin)

// What only a real libmpv can show, on headless Weston: tool/player-test.sh
// runs it with the clip it makes (decisions/testing.md, Player tests).
class Setup : public QObject {
  Q_OBJECT

public slots:
  void applicationAvailable() {
    // As main() sets them: mpv draws in desktop GL and needs C numbers.
    std::setlocale(LC_NUMERIC, "C");
  }

  void qmlEngineAvailable(QQmlEngine *engine) {
    engine->rootContext()->setContextProperty("testClip", qEnvironmentVariable("LUMEO_TEST_CLIP"));
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
