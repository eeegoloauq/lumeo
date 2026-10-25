#include "fonts.h"

#include <QDirIterator>
#include <QFontDatabase>
#include <QGuiApplication>

void loadFonts() {
  QDirIterator files(":/qt/qml/Lumeo/fonts", {"*.ttf", "*.otf"});
  while (files.hasNext())
    QFontDatabase::addApplicationFont(files.next());
  QFont sans("IBM Plex Sans");
  sans.setPixelSize(15);
  QGuiApplication::setFont(sans);
}
