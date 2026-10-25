#pragma once

#include <QList>
#include <QPointer>
#include <QQuickAsyncImageProvider>

class QNetworkAccessManager;
class QQmlEngine;

// Artwork the core serves from its cache, as image://artwork/<address>: asked
// for again when the core could not fetch it, and decoded at the size it is
// drawn (sourceSize), since posters arrive about 660 px wide to be drawn at
// 160 and a 4K still at full size is a hundred megabytes.
//
// The core answers 5xx when the provider's CDN did not answer in time. On a
// throttled line that is often a node blocked by address, which the system
// resolver keeps handing out for the name's 30 s TTL, so the retries reach
// past one TTL. The image stays loading meanwhile, so the placeholder holds
// and every Image showing the address fills in together. A 4xx is an answer,
// the image does not exist, and is final.
//
// image://logo/<address> is a title card, with ink that would vanish on our
// ground repainted white (needsInk).
class Artwork : public QQuickAsyncImageProvider {
public:
  explicit Artwork(bool ink);

  // Both providers on [engine].
  static void install(QQmlEngine *engine);

  QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;

  // Whether a title card is dark enough to vanish on our ground, with
  // nothing to lose by being repainted white: the mean luminance of its
  // opaque pixels is below 0.18 (decisions/interface.md).
  static bool needsInk(const QImage &logo);

  // The pause before each retry, in milliseconds; tests shorten it.
  static QList<int> retryDelays;

private:
  bool m_ink;
  QPointer<QNetworkAccessManager> m_network;
};
