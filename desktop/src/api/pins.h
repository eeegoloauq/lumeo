#pragma once

#include <QList>
#include <QSslCertificate>
#include <QString>
#include <QUrl>

class QNetworkReply;

// A core serving a certificate of its own, which no authority vouches for,
// is trusted by that exact certificate, pinned at pairing, for its origin
// alone. The process keeps the pins of the cores it talks to: the one it
// uses directly (core.json) and the media server its own core forwards to,
// whose artwork it loads.
namespace Pins {
void add(const QUrl &origin, const QSslCertificate &certificate);
// The certificate pinned for [url]'s origin, null for none.
QSslCertificate of(const QUrl &url);
QList<QSslCertificate> all();
// Lets [reply] past a certificate no authority vouches for when its server
// shows the one pinned for its origin.
void guard(QNetworkReply *reply);
// The same for one [certificate], as pairing does before it pins it.
void trust(QNetworkReply *reply, const QSslCertificate &certificate);
// Whether [certificate] names [host], as mpv checks before it plays.
bool names(const QSslCertificate &certificate, const QString &host);

// What a device sends in place of the pairing code, and what the server
// proves it with (core/internal/remote/proof.go).
QString deviceProof(const QString &code, const QSslCertificate &certificate);
QString serverProof(const QString &code, const QSslCertificate &certificate);
} // namespace Pins
