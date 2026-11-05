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
// resolver keeps handing out for the name's 30 s TTL, so the first retries
// reach past one TTL; after them it is asked again every minute for as long
// as an Image wants it, since a line down for longer (a laptop waking, a VPN
// coming up) otherwise left the picture blank while its page stayed made.
// The image stays loading meanwhile, so the placeholder holds and every Image
// showing the address fills in together. A 4xx is an answer, the image does
// not exist, and is final.
//
// image://logo/<address> is a title card, with ink that would vanish on our
// ground repainted white (needsInk). image://still/<address> gives up after
// the first retries, for a picture with something of our own to stand in.
// <address> may be a file of our own too, and blur/<address> is the picture
// blurred as it is decoded: an unwatched episode's still, where an effect on
// the Image cost offscreen textures and render passes for each still shown.
class Artwork : public QQuickAsyncImageProvider {
public:
  Artwork(bool ink, bool patient);

  // Both providers on [engine].
  static void install(QQmlEngine *engine);

  QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;

  // Whether a title card is dark enough to vanish on our ground, with
  // nothing to lose by being repainted white: the mean luminance of its
  // opaque pixels is below 0.18 (decisions/interface.md).
  static bool needsInk(const QImage &logo);

  // The pause before each retry, in milliseconds, and between the patient
  // ones after them; tests shorten both.
  static QList<int> retryDelays;
  static int againEvery;

private:
  bool m_ink;
  bool m_patient;
  QPointer<QNetworkAccessManager> m_network;
};
