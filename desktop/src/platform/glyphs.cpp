#include "glyphs.h"

#include <QPainter>
#include <QQmlEngine>
#include <QSvgRenderer>

Glyphs::Glyphs() : QQuickImageProvider(QQuickImageProvider::Image) {}

void Glyphs::install(QQmlEngine *engine) { engine->addImageProvider("glyph", new Glyphs); }

QImage Glyphs::requestImage(const QString &id, QSize *size, const QSize &requestedSize) {
  QSvgRenderer svg(QStringLiteral(":/qt/qml/Lumeo/icons/%1.svg").arg(id.section('/', 0, 0)));
  const QColor color(u'#' + id.section('/', 1));
  if (!svg.isValid() || !color.isValid())
    return {};
  // The icons are square: a side left out follows the other.
  QSize at = requestedSize;
  if (at.width() <= 0 && at.height() <= 0)
    at = svg.defaultSize();
  else if (at.width() <= 0)
    at.setWidth(at.height());
  else if (at.height() <= 0)
    at.setHeight(at.width());
  QImage image(at, QImage::Format_ARGB32_Premultiplied);
  image.fill(Qt::transparent);
  QPainter painter(&image);
  svg.render(&painter);
  painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
  painter.fillRect(image.rect(), color);
  painter.end();
  *size = image.size();
  return image;
}
