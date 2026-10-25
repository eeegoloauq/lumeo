#include "artwork.h"
#include "fakecore.h"

#include <QBuffer>
#include <QQuickTextureFactory>
#include <QSignalSpy>
#include <QtTest>

namespace {

QByteArray png(const QSize &size, const QColor &color, const char *format = "PNG") {
  QImage image(size, QImage::Format_ARGB32);
  image.fill(color);
  QBuffer buffer;
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, format);
  return buffer.data();
}

struct Fetched {
  QImage image;
  QString error;
};

Fetched fetch(Artwork &provider, const QUrl &url, const QSize &size = {}) {
  std::unique_ptr<QQuickImageResponse> response(
      provider.requestImageResponse(QUrl::toPercentEncoding(url.toString()), size));
  QSignalSpy finished(response.get(), &QQuickImageResponse::finished);
  if (!finished.wait(5000))
    return {QImage(), "no answer"};
  std::unique_ptr<QQuickTextureFactory> texture(response->textureFactory());
  return {texture ? texture->image() : QImage(), response->errorString()};
}

} // namespace

class ArtworkTest : public QObject {
  Q_OBJECT

  std::unique_ptr<FakeCore> fake;

  QUrl at(const QString &path) const { return fake->address().resolved(QUrl(path)); }

private slots:
  void init() {
    fake = std::make_unique<FakeCore>();
    QVERIFY(fake->listen());
    Artwork::retryDelays = {20, 20, 20};
  }

  // Posters arrive about 660 px wide and are drawn at 160; at full size a
  // page of shelves holds hundreds of megabytes.
  void artworkIsDecodedAtTheSizeItIsDrawn() {
    // As the core serves most of it.
    fake->file("/art/poster", png({300, 450}, Qt::red, "JPEG"), "image/jpeg");
    Artwork provider(false);
    QCOMPARE(fetch(provider, at("/art/poster"), {176, 0}).image.size(), QSize(176, 264));
    QCOMPARE(fetch(provider, at("/art/poster"), {}).image.size(), QSize(300, 450));
    QCOMPARE(fetch(provider, at("/art/poster"), {600, 0}).image.size(), QSize(300, 450));
  }

  // Seen 2026-10-25: posters in WebP stayed blank cards where Qt had no
  // plugin for it.
  void artworkInWebPIsDecoded() {
    fake->file("/art/webp", png({30, 45}, Qt::red, "WEBP"), "image/webp");
    Artwork provider(false);
    QCOMPARE(fetch(provider, at("/art/webp")).image.size(), QSize(30, 45));
  }

  void anImageTheCoreCouldNotFetchIsAskedForAgain() {
    fake->answer("GET", "/art/slow", 503);
    // Once the first request has had its 503.
    connect(fake.get(), &FakeCore::requested, this, [this] {
      QTimer::singleShot(0, this, [this] {
        fake->file("/art/slow", png({30, 45}, Qt::red), "image/png");
      });
    });
    Artwork provider(false);
    const Fetched fetched = fetch(provider, at("/art/slow"));
    QCOMPARE(fetched.image.size(), QSize(30, 45));
    QCOMPARE(fake->requests().size(), 2);
  }

  void aMissingImageIsFinal() {
    fake->answer("GET", "/art/missing", 404);
    Artwork provider(false);
    QVERIFY(!fetch(provider, at("/art/missing")).error.isEmpty());
    QTest::qWait(60);
    QCOMPARE(fake->requests().size(), 1);
  }

  void theRetriesStop() {
    fake->answer("GET", "/art/down", 502);
    Artwork provider(false);
    QVERIFY(!fetch(provider, at("/art/down")).error.isEmpty());
    QCOMPARE(fake->requests().size(), 1 + Artwork::retryDelays.size());
  }

  // Some titles ship a card drawn dark for a light poster, which disappears
  // on our ground; the shape is the design, only the ink changes.
  void aBlackTitleCardComesBackWhite() {
    fake->file("/art/logo", png({40, 20}, Qt::black), "image/png");
    Artwork provider(true);
    const QImage logo = fetch(provider, at("/art/logo")).image;
    QCOMPARE(logo.pixelColor(10, 10), QColor(Qt::white));
  }

  void whiteLetteringAndADarkButColouredMarkKeepTheirColours() {
    QImage image({40, 20}, QImage::Format_ARGB32);
    image.fill(Qt::white);
    QVERIFY(!Artwork::needsInk(image));
    // Masters of the Universe's card measures 0.28.
    image.fill(QColor(110, 60, 20));
    QVERIFY(!Artwork::needsInk(image));
    image.fill(QColor(20, 20, 20));
    QVERIFY(Artwork::needsInk(image));
  }

  void transparentPixelsAreNotPartOfTheMark() {
    QImage image({40, 20}, QImage::Format_ARGB32);
    image.fill(QColor(0, 0, 0, 0));
    for (int x = 0; x < 40; ++x)
      image.setPixelColor(x, 10, Qt::white);
    QVERIFY(!Artwork::needsInk(image));
  }
};

QTEST_MAIN(ArtworkTest)
#include "artwork_test.moc"
