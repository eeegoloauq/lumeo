#pragma once

#include <QList>
#include <QString>

class QSslCertificate;
struct mpv_handle;

// mpv checks no certificate unless told to, and the core's token goes with
// every request it makes. Called before mpv_initialize.
void verifyTls(mpv_handle *mpv);

// The certificates Qt reads from the system and the [pinned] ones of cores
// serving their own, as one PEM file at [path] for mpv's tls-ca-file; empty
// when there are none or the file cannot be written.
QString trustedCertificates(const QString &path, const QList<QSslCertificate> &pinned = {});
