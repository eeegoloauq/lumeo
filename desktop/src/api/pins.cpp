#include "pins.h"

#include <QCryptographicHash>
#include <QHash>
#include <QHostAddress>
#include <QMessageAuthenticationCode>
#include <QMutex>
#include <QNetworkReply>
#include <QSslConfiguration>

namespace {
QMutex mutex;
QHash<QString, QSslCertificate> pins;

QString originOf(const QUrl &url) {
  return url.scheme() + "://" + url.host().toLower() + ":" + QString::number(url.port(443));
}

QString proof(const QString &code, const char *role, const QSslCertificate &certificate) {
  QMessageAuthenticationCode mac(QCryptographicHash::Sha256, code.toUtf8());
  mac.addData(QByteArray(role));
  mac.addData(QByteArray(1, '\0'));
  mac.addData(QCryptographicHash::hash(certificate.toDer(), QCryptographicHash::Sha256));
  return QString::fromLatin1(mac.result().toHex());
}
} // namespace

void Pins::add(const QUrl &origin, const QSslCertificate &certificate) {
  if (certificate.isNull())
    return;
  QMutexLocker lock(&mutex);
  pins.insert(originOf(origin), certificate);
}

QSslCertificate Pins::of(const QUrl &url) {
  QMutexLocker lock(&mutex);
  return pins.value(originOf(url));
}

QList<QSslCertificate> Pins::all() {
  QMutexLocker lock(&mutex);
  return pins.values();
}

void Pins::guard(QNetworkReply *reply) {
  if (reply->url().scheme() != "https")
    return;
  const QSslCertificate pinned = of(reply->url());
  if (!pinned.isNull())
    trust(reply, pinned);
}

void Pins::trust(QNetworkReply *reply, const QSslCertificate &certificate) {
  QObject::connect(reply, &QNetworkReply::sslErrors, reply, [reply, certificate](const QList<QSslError> &errors) {
    // The exact certificate proves the server: the handshake showed it holds
    // the key. Only its name still counts, which the player checks too.
    if (reply->sslConfiguration().peerCertificate() != certificate)
      return;
    for (const QSslError &error : errors)
      if (error.error() == QSslError::HostNameMismatch)
        return;
    reply->ignoreSslErrors();
  });
}

bool Pins::names(const QSslCertificate &certificate, const QString &host) {
  const QHostAddress address(host);
  const auto names = certificate.subjectAlternativeNames();
  for (auto entry = names.cbegin(); entry != names.cend(); ++entry) {
    if (address.isNull() ? entry.key() == QSsl::DnsEntry && entry.value().compare(host, Qt::CaseInsensitive) == 0
                         : entry.key() == QSsl::IpAddressEntry && QHostAddress(entry.value()) == address)
      return true;
  }
  return false;
}

QString Pins::deviceProof(const QString &code, const QSslCertificate &certificate) {
  return proof(code, "lumeo pair device", certificate);
}

QString Pins::serverProof(const QString &code, const QSslCertificate &certificate) {
  return proof(code, "lumeo pair server", certificate);
}
