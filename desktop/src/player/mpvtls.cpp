#include "mpvtls.h"

#include "folders.h"

#include <QDir>
#include <QFileInfo>
#include <QSaveFile>
#include <QSslCertificate>
#include <QSslConfiguration>
#include <mpv/client.h>

void verifyTls(mpv_handle *mpv) {
  mpv_set_option_string(mpv, "tls-verify", "yes");
#ifdef Q_OS_WIN
  // The bundled FFmpeg verifies with OpenSSL, which is not pointed at the
  // Windows store. It gets the certificates Qt trusts, the ones pairing was
  // checked against, written once per run.
  static const QString file = trustedCertificates(Folders::cache() + "/trusted-certificates.pem");
  if (!file.isEmpty())
    mpv_set_option_string(mpv, "tls-ca-file", file.toUtf8().constData());
#endif
}

QString trustedCertificates(const QString &path) {
  QByteArray pem;
  for (const QSslCertificate &certificate : QSslConfiguration::systemCaCertificates())
    pem += certificate.toPem();
  if (pem.isEmpty() || !QDir().mkpath(QFileInfo(path).absolutePath()))
    return {};
  QSaveFile file(path);
  if (!file.open(QIODevice::WriteOnly) || file.write(pem) != pem.size() || !file.commit())
    return {};
  return path;
}
