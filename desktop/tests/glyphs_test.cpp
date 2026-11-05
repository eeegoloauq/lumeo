#include "glyphs.h"

#include <QtTest>

namespace {

// The most opaque pixel of [icon], which is its ink.
QColor ink(const QImage &icon) {
  QColor most(Qt::transparent);
  for (int y = 0; y < icon.height(); ++y)
    for (int x = 0; x < icon.width(); ++x)
      if (icon.pixelColor(x, y).alpha() > most.alpha())
        most = icon.pixelColor(x, y);
  return most;
}

} // namespace

class GlyphsTest : public QObject {
  Q_OBJECT

private slots:
  // Drawn black, the icons vanished on our ground until painted over.
  void anIconComesInItsColourAtTheSizeAsked() {
    Glyphs glyphs;
    QSize size;
    const QImage icon = glyphs.requestImage("check/e5484d", &size, {36, 36});
    QCOMPARE(icon.size(), QSize(36, 36));
    QCOMPARE(size, icon.size());
    QCOMPARE(ink(icon), QColor(0xe5, 0x48, 0x4d));
    QCOMPARE(icon.pixelColor(0, 0).alpha(), 0);
    // A faint colour is a faint icon.
    QCOMPARE(ink(glyphs.requestImage("check/80ffffff", &size, {36, 36})).alpha(), 0x80);
  }

  void anUnknownIconIsNone() {
    Glyphs glyphs;
    QSize size;
    QVERIFY(glyphs.requestImage("nothing/ffffff", &size, {18, 18}).isNull());
  }
};

QTEST_MAIN(GlyphsTest)
#include "glyphs_test.moc"
