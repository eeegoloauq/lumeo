#include "artwork.h"
#include "pins.h"

#include <QBasicTimer>
#include <QBuffer>
#include <QCoreApplication>
#include <QFile>
#include <QImageReader>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPainter>
#include <QQmlEngine>
#include <QTimerEvent>
#include <QtConcurrent>

#include <algorithm>
#include <vector>

QList<int> Artwork::retryDelays{2000, 6000, 20000};
int Artwork::againEvery = 60000;

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

// One pass of a box blur along [count] pixels [step] apart, the edge
// pixels standing in for those past them. Premultiplied, so a soft edge
// averages without darkening.
void boxPass(QRgb *first, int count, qsizetype step, int radius, std::vector<QRgb> &line) {
  line.resize(count);
  for (int i = 0; i < count; ++i)
    line[i] = first[i * step];
  const auto at = [&line, count](int i) { return line[std::clamp(i, 0, count - 1)]; };
  int a = 0, r = 0, g = 0, b = 0;
  for (int i = -radius; i <= radius; ++i) {
    const QRgb pixel = at(i);
    a += qAlpha(pixel), r += qRed(pixel), g += qGreen(pixel), b += qBlue(pixel);
  }
  const int width = 2 * radius + 1;
  const auto mean = [width](int sum) { return (sum + width / 2) / width; };
  for (int i = 0; i < count; ++i) {
    first[i * step] = qRgba(mean(r), mean(g), mean(b), mean(a));
    const QRgb out = at(i - radius), in = at(i + radius + 1);
    a += qAlpha(in) - qAlpha(out), r += qRed(in) - qRed(out);
    g += qGreen(in) - qGreen(out), b += qBlue(in) - qBlue(out);
  }
}

// Three box passes each way, close to a Gaussian, with a radius in
// proportion to the width: the same blur at every size a still is drawn.
QImage blurred(const QImage &source) {
  QImage image = source.convertToFormat(QImage::Format_ARGB32_Premultiplied);
  const int radius = std::max(1, image.width() / 40);
  auto *pixels = reinterpret_cast<QRgb *>(image.bits());
  const qsizetype stride = image.bytesPerLine() / sizeof(QRgb);
  std::vector<QRgb> line;
  for (int pass = 0; pass < 3; ++pass) {
    for (int y = 0; y < image.height(); ++y)
      boxPass(pixels + y * stride, image.width(), 1, radius, line);
    for (int x = 0; x < image.width(); ++x)
      boxPass(pixels + x, image.height(), stride, radius, line);
  }
  return image;
}

QImage decode(const QByteArray &bytes, const QSize &requested, bool ink, bool blur) {
  QBuffer buffer;
  buffer.setData(bytes);
  QImageReader reader(&buffer);
  reader.setAutoTransform(true);
  reader.setScaledSize(fitted(reader.size(), requested));
  QImage image = reader.read();
  if (blur && !image.isNull())
    return blurred(image);
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
  Response(QNetworkAccessManager *network, const QUrl &url, const QSize &requested, bool ink,
           bool patient, bool blur)
      : m_network(network), m_url(url), m_requested(requested), m_ink(ink), m_patient(patient),
        m_blur(blur) {}

  void fetch() {
    if (m_url.isLocalFile()) {
      QtConcurrent::run([path = m_url.toLocalFile()] {
        QFile file(path);
        return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
      }).then(this, [this](const QByteArray &bytes) { decodeAndFinish(bytes); });
      return;
    }
    if (!m_network) {
      fail("no network");
      return;
    }
    m_reply = m_network->get(QNetworkRequest(m_url));
    Pins::guard(m_reply);
    connect(m_reply, &QNetworkReply::finished, this, &Response::fetched);
  }

  QQuickTextureFactory *textureFactory() const override {
    return QQuickTextureFactory::textureFactoryForImage(m_image);
  }
  QString errorString() const override { return m_error; }

  // Qt deletes a response only once it has emitted finished, cancelled or
  // not, so every way out of a cancel ends in finished.
  void cancel() override {
    QMetaObject::invokeMethod(this, [this] {
      m_cancelled = true;
      if (m_reply) {
        m_reply->abort(); // fetched() finishes
      } else if (m_pause.isActive()) {
        m_pause.stop();
        fail("cancelled");
      }
      // Otherwise it is decoding, and finishes when that is done, or it has
      // finished already.
    }, Qt::QueuedConnection);
  }

protected:
  void timerEvent(QTimerEvent *event) override {
    if (event->id() != m_pause.id())
      return QQuickImageResponse::timerEvent(event);
    m_pause.stop();
    fetch();
  }

private:
  void fetched() {
    // Cleared now, not when it is deleted: cancel() tells a request in
    // flight by it.
    QNetworkReply *reply = m_reply;
    m_reply = nullptr;
    reply->deleteLater();
    if (m_cancelled) {
      fail("cancelled");
      return;
    }
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status == 200) {
      decodeAndFinish(reply->readAll());
      return;
    }
    const bool again = status == 0 || status >= 500;
    const bool retried = m_attempt == Artwork::retryDelays.size();
    if (!again || (retried && !m_patient)) {
      fail(status ? QString("HTTP %1").arg(status) : reply->errorString());
      return;
    }
    // Cancelled when no Image wants it any more, which ends this.
    const int pause = retried ? Artwork::againEvery : Artwork::retryDelays.at(m_attempt++);
    m_pause.start(std::chrono::milliseconds(pause), this);
  }

  void decodeAndFinish(const QByteArray &bytes) {
    // Continued here only while this response is alive, which a test
    // holding one of its own may end first.
    QtConcurrent::run(decode, bytes, m_requested, m_ink, m_blur)
        .then(this, [this](const QImage &image) {
          if (image.isNull()) {
            fail("not an image");
            return;
          }
          m_image = image;
          emit finished();
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
  bool m_patient;
  bool m_blur;
  QPointer<QNetworkReply> m_reply;
  QBasicTimer m_pause;
  int m_attempt = 0;
  bool m_cancelled = false;
  QImage m_image;
  QString m_error;
};

} // namespace

Artwork::Artwork(bool ink, bool patient)
    : m_ink(ink), m_patient(patient),
      m_network(new QNetworkAccessManager(QCoreApplication::instance())) {}

void Artwork::install(QQmlEngine *engine) {
  engine->addImageProvider("artwork", new Artwork(false, true));
  engine->addImageProvider("logo", new Artwork(true, true));
  engine->addImageProvider("still", new Artwork(false, false));
}

QQuickImageResponse *Artwork::requestImageResponse(const QString &id, const QSize &requestedSize) {
  // The address is percent-encoded, so a "/" before it is ours.
  const bool blur = id.startsWith("blur/");
  const QString address = blur ? id.mid(5) : id;
  auto *response = new Response(m_network, QUrl(QUrl::fromPercentEncoding(address.toUtf8())),
                                requestedSize, m_ink, m_patient, blur);
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
