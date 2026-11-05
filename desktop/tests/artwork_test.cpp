#include "artwork.h"
#include "fakecore.h"

#include <QBuffer>
#include <QNetworkAccessManager>
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
  // The app sets no time limit on a request, so a slow runner fails this only
  // past one a person would notice. Seen 2026-11-01 on Windows CI: the first
  // request of a cold process took longer than 5 s.
  if (!finished.wait(25000))
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
    Artwork::againEvery = 20;
  }

  // Posters arrive about 660 px wide and are drawn at 160; at full size a
  // page of shelves holds hundreds of megabytes.
  void artworkIsDecodedAtTheSizeItIsDrawn() {
    // As the core serves most of it.
    fake->file("/art/poster", png({300, 450}, Qt::red, "JPEG"), "image/jpeg");
    Artwork provider(false, true);
    QCOMPARE(fetch(provider, at("/art/poster"), {176, 0}).image.size(), QSize(176, 264));
    QCOMPARE(fetch(provider, at("/art/poster"), {}).image.size(), QSize(300, 450));
    QCOMPARE(fetch(provider, at("/art/poster"), {600, 0}).image.size(), QSize(300, 450));
  }

  // Seen 2026-10-25: posters in WebP stayed blank cards where Qt had no
  // plugin for it.
  void artworkInWebPIsDecoded() {
    fake->file("/art/webp", png({30, 45}, Qt::red, "WEBP"), "image/webp");
    Artwork provider(false, true);
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
    Artwork provider(false, true);
    const Fetched fetched = fetch(provider, at("/art/slow"));
    QCOMPARE(fetched.image.size(), QSize(30, 45));
    QCOMPARE(fake->requests().size(), 2);
  }

  void aMissingImageIsFinal() {
    fake->answer("GET", "/art/missing", 404);
    Artwork provider(false, true);
    QVERIFY(!fetch(provider, at("/art/missing")).error.isEmpty());
    QTest::qWait(60);
    QCOMPARE(fake->requests().size(), 1);
  }

  // A line down for longer than the first retries left a poster blank for
  // as long as its page stayed made, Home all session.
  void anImageIsAskedForUntilTheCoreHasIt() {
    fake->answer("GET", "/art/down", 502);
    const int failing = 3 + Artwork::retryDelays.size();
    connect(fake.get(), &FakeCore::requested, this, [this, failing] {
      if (fake->requests().size() == failing)
        QTimer::singleShot(0, this, [this] {
          fake->file("/art/down", png({30, 45}, Qt::red), "image/png");
        });
    });
    Artwork provider(false, true);
    QCOMPARE(fetch(provider, at("/art/down")).image.size(), QSize(30, 45));
    QCOMPARE(fake->requests().size(), failing + 1);
  }

  void anImageNoLongerWantedIsNotAskedForAgain() {
    fake->answer("GET", "/art/gone", 502);
    Artwork provider(false, true);
    std::unique_ptr<QQuickImageResponse> response(provider.requestImageResponse(
        QUrl::toPercentEncoding(at("/art/gone").toString()), {}));
    QTRY_VERIFY(fake->requests().size() > 1 + Artwork::retryDelays.size());
    response->cancel();
    QTest::qWait(2 * Artwork::againEvery);
    const qsizetype asked = fake->requests().size();
    QTest::qWait(2 * Artwork::againEvery);
    QCOMPARE(fake->requests().size(), asked);
  }

  // Qt deletes a response only after its finished, cancelled or not; a
  // cancel that never finished kept every poster scrolled past mid-request.
  void aCancelDuringTheRequestFinishes() {
    fake->hold("GET", "/art/held");
    Artwork provider(false, true);
    std::unique_ptr<QQuickImageResponse> response(provider.requestImageResponse(
        QUrl::toPercentEncoding(at("/art/held").toString()), {}));
    QSignalSpy finished(response.get(), &QQuickImageResponse::finished);
    QTRY_COMPARE(fake->requests().size(), 1);
    response->cancel();
    QVERIFY(finished.wait());
    QVERIFY(!response->errorString().isEmpty());
    QTest::qWait(2 * Artwork::retryDelays.first());
    QCOMPARE(fake->requests().size(), 1);
  }

  void aCancelDuringThePauseFinishes() {
    fake->answer("GET", "/art/down", 502);
    // Long enough that the cancel lands in it; cancelled, never waited out.
    Artwork::retryDelays = {60000};
    Artwork provider(false, true);
    std::unique_ptr<QQuickImageResponse> response(provider.requestImageResponse(
        QUrl::toPercentEncoding(at("/art/down").toString()), {}));
    QSignalSpy finished(response.get(), &QQuickImageResponse::finished);
    // The provider's manager is a child of the application; its finished
    // comes just before the response sees the 502 and starts the pause.
    bool answered = false;
    for (auto *network : qApp->findChildren<QNetworkAccessManager *>())
      connect(network, &QNetworkAccessManager::finished, this, [&answered] { answered = true; });
    QTRY_VERIFY(answered);
    response->cancel();
    QVERIFY(finished.wait());
    QVERIFY(!response->errorString().isEmpty());
    QCOMPARE(fake->requests().size(), 1);
  }

  // A still with a frame of the file to stand in gives up instead.
  void aStillsRetriesStop() {
    fake->answer("GET", "/art/down", 502);
    Artwork provider(false, false);
    QVERIFY(!fetch(provider, at("/art/down")).error.isEmpty());
    QCOMPARE(fake->requests().size(), 1 + Artwork::retryDelays.size());
  }

  // Some titles ship a card drawn dark for a light poster, which disappears
  // on our ground; the shape is the design, only the ink changes.
  void aBlackTitleCardComesBackWhite() {
    fake->file("/art/logo", png({40, 20}, Qt::black), "image/png");
    Artwork provider(true, true);
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
