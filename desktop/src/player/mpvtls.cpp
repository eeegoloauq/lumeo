#include "mpvtls.h"

#include "folders.h"
#include "pins.h"

#include <QDir>
#include <QFileInfo>
#include <QMutex>
#include <QSaveFile>
#include <QSslCertificate>
#include <QSslConfiguration>
#include <mpv/client.h>

void verifyTls(mpv_handle *mpv) {
  mpv_set_option_string(mpv, "tls-verify", "yes");
  const QList<QSslCertificate> pinned = Pins::all();
#ifndef Q_OS_WIN
  // FFmpeg reads the system's certificates itself unless given a file.
  if (pinned.isEmpty())
    return;
#endif
  // The bundled FFmpeg on Windows verifies with OpenSSL, which is not
  // pointed at the Windows store: it gets the certificates Qt trusts, the
  // ones pairing was checked against. A core's own certificate, pinned at
  // pairing, goes beside them, so its streams verify and so does the rest
  // (a trailer). Written once per set of pins.
  static QMutex mutex;
  static QList<QSslCertificate> written;
  static QString file;
  QMutexLocker lock(&mutex);
  if (file.isEmpty() || written != pinned) {
    file = trustedCertificates(Folders::cache() + "/trusted-certificates.pem", pinned);
    written = pinned;
  }
  if (!file.isEmpty())
    mpv_set_option_string(mpv, "tls-ca-file", file.toUtf8().constData());
}

QString trustedCertificates(const QString &path, const QList<QSslCertificate> &pinned) {
  QByteArray pem;
  for (const QSslCertificate &certificate : QSslConfiguration::systemCaCertificates() + pinned)
    pem += certificate.toPem();
  if (pem.isEmpty() || !QDir().mkpath(QFileInfo(path).absolutePath()))
    return {};
  QSaveFile file(path);
  if (!file.open(QIODevice::WriteOnly) || file.write(pem) != pem.size() || !file.commit())
    return {};
  return path;
}
