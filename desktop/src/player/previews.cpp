#include "previews.h"

#include "framegrabber.h"

#include <QQuickWindow>
#include <QSGImageNode>

Previews::Previews(const QString &url, const QStringList &headers, QObject *parent)
    : QObject(parent), m_url(url), m_headers(headers) {}

Previews::~Previews() = default;

void Previews::show(double seconds) {
  m_shown = true;
  m_wanted = seconds;
  if (!m_grabber) {
    m_grabber = new FrameGrabber(m_url, m_headers, this);
    connect(m_grabber, &FrameGrabber::opened, this, [this] {
      m_busy = false;
      next();
    });
  }
  next();
}

void Previews::hide() {
  m_shown = false;
  m_wanted.reset();
  if (m_frame.isNull())
    return;
  m_frame = {};
  emit frameChanged();
}

void Previews::next() {
  if (m_busy || !m_wanted)
    return;
  const double at = *std::exchange(m_wanted, std::nullopt);
  m_busy = true;
  m_grabber->frame(at, "absolute+keyframes", [this](const QImage &image) {
    m_busy = false;
    if (!image.isNull() && m_shown) {
      m_frame = image;
      emit frameChanged();
    }
    next();
  });
}

FrameView::FrameView(QQuickItem *parent) : QQuickItem(parent) {
  setFlag(ItemHasContents);
}

void FrameView::setImage(const QImage &image) {
  m_image = image;
  m_changed = true;
  emit imageChanged();
  update();
}

QSGNode *FrameView::updatePaintNode(QSGNode *old, UpdatePaintNodeData *) {
  auto *node = static_cast<QSGImageNode *>(old);
  if (m_image.isNull()) {
    delete node;
    return nullptr;
  }
  if (!node) {
    node = window()->createImageNode();
    node->setOwnsTexture(true);
    node->setFiltering(QSGTexture::Linear);
    m_changed = true;
  }
  if (std::exchange(m_changed, false))
    node->setTexture(window()->createTextureFromImage(m_image));
  node->setRect(boundingRect());
  return node;
}
