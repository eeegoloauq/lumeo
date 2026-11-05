#pragma once

#include <QQuickImageProvider>

class QQmlEngine;

// The icons of icons/ in a colour, as image://glyph/<name>/<colour>, the
// colour as QML writes it without the "#" (f3f5f9, 80ffffff). The SVGs are
// drawn black; each is painted in its colour once, at the size asked, and
// every Image of the same address shares that texture. An effect on each
// icon cost a layer and a render pass for every one shown
// (decisions/performance.md).
class Glyphs : public QQuickImageProvider {
public:
  Glyphs();

  static void install(QQmlEngine *engine);

  QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;
};
