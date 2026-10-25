#include "artwork.h"

#include <QBuffer>
#include <QCoreApplication>
#include <QImageReader>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPainter>
#include <QQmlEngine>
#include <QTimer>
#include <QtConcurrent>

QList<int> Artwork::retryDelays{2000, 6000, 20000};

namespace {

// The largest size within [requested] that keeps [original]'s shape, a side
// left out following the other, and never larger than the original.
QSize fitted(const QSize &original, const QSize &requested) {
  if (!original.isValid() || (requested.width() <= 0 && requested.height() <= 0))
    return original;
  const int unbounded = 1 << 20;
  const QSize bound(requested.width() > 0 ? requested.width() : unbounded,
                    requested.height() > 0 ? requested.height() : unbounded);
  const QSize size = original.scaled(bound, Qt::KeepAspectRatio);
  return size.width() < original.width() ? size : original;
}

QImage decode(const QByteArray &bytes, const QSize &requested, bool ink) {
  QBuffer buffer;
  buffer.setData(bytes);
  QImageReader reader(&buffer);
  reader.setAutoTransform(true);
  reader.setScaledSize(fitted(reader.size(), requested));
  QImage image = reader.read();
  if (!ink || image.isNull() || !Artwork::needsInk(image))
    return image;
  // The shape is the design; only the ink changes.
  image = image.convertToFormat(QImage::Format_ARGB32_Premultiplied);
  QPainter painter(&image);
  painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
  painter.fillRect(image.rect(), Qt::white);
  return image;
}

// Fetched on the GUI thread, where the network lives, and decoded off it.
class Response : public QQuickImageResponse {
public:
  Response(QNetworkAccessManager *network, const QUrl &url, const QSize &requested, bool ink)
      : m_network(network), m_url(url), m_requested(requested), m_ink(ink) {}

  void fetch() {
    if (!m_network) {
      fail("no network");
      return;
    }
    m_reply = m_network->get(QNetworkRequest(m_url));
    connect(m_reply, &QNetworkReply::finished, this, &Response::fetched);
  }

  QQuickTextureFactory *textureFactory() const override {
    return QQuickTextureFactory::textureFactoryForImage(m_image);
  }
  QString errorString() const override { return m_error; }

  void cancel() override {
    QMetaObject::invokeMethod(this, [this] {
      m_cancelled = true;
      if (m_reply)
        m_reply->abort();
    }, Qt::QueuedConnection);
  }

private:
  void fetched() {
    m_reply->deleteLater();
    if (m_cancelled)
      return;
    const int status = m_reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status == 200) {
      // Continued here only while this response is alive: Qt deletes one it
      // gave up on.
      QtConcurrent::run(decode, m_reply->readAll(), m_requested, m_ink)
          .then(this, [this](const QImage &image) {
            if (image.isNull()) {
              fail("not an image");
              return;
            }
            m_image = image;
            emit finished();
          });
      return;
    }
    const bool again = status == 0 || status >= 500;
    if (!again || m_attempt == Artwork::retryDelays.size()) {
      fail(status ? QString("HTTP %1").arg(status) : m_reply->errorString());
      return;
    }
    QTimer::singleShot(Artwork::retryDelays.at(m_attempt++), this, [this] {
      if (!m_cancelled)
        fetch();
    });
  }

  void fail(const QString &why) {
    m_error = why;
    emit finished();
  }

  QPointer<QNetworkAccessManager> m_network;
  QUrl m_url;
  QSize m_requested;
  bool m_ink;
  QPointer<QNetworkReply> m_reply;
  int m_attempt = 0;
  bool m_cancelled = false;
  QImage m_image;
  QString m_error;
};

} // namespace

Artwork::Artwork(bool ink)
    : m_ink(ink), m_network(new QNetworkAccessManager(QCoreApplication::instance())) {}

void Artwork::install(QQmlEngine *engine) {
  engine->addImageProvider("artwork", new Artwork(false));
  engine->addImageProvider("logo", new Artwork(true));
}

QQuickImageResponse *Artwork::requestImageResponse(const QString &id, const QSize &requestedSize) {
  auto *response = new Response(m_network, QUrl(QUrl::fromPercentEncoding(id.toUtf8())),
                                requestedSize, m_ink);
  // Qt may ask from its image thread; the request is made on the GUI's.
  response->moveToThread(QCoreApplication::instance()->thread());
  QMetaObject::invokeMethod(response, [response] { response->fetch(); }, Qt::QueuedConnection);
  return response;
}

// Measured against real Cinemeta artwork: a black mark lands near 0.02, a
// dark but coloured one (Masters of the Universe) at 0.28, which must keep
// its colours, and ordinary white lettering above 0.6.
bool Artwork::needsInk(const QImage &logo) {
  // Straight alpha: premultiplied, every softened edge reads darker than it
  // is and drags the mean down.
  const QImage image = logo.convertToFormat(QImage::Format_ARGB32);
  double sum = 0;
  qint64 counted = 0;
  for (int y = 0; y < image.height(); ++y) {
    const auto *row = reinterpret_cast<const QRgb *>(image.constScanLine(y));
    // Every eighth pixel is plenty to tell white lettering from black.
    for (int x = y % 8; x < image.width(); x += 8) {
      if (qAlpha(row[x]) < 128)
        continue;
      sum += 0.2126 * qRed(row[x]) + 0.7152 * qGreen(row[x]) + 0.0722 * qBlue(row[x]);
      ++counted;
    }
  }
  return counted > 0 && sum / counted / 255 < 0.18;
}
