#include "coreconnection.h"

#include "folders.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSaveFile>

namespace {
bool validToken(const QString &token) {
  static const QRegularExpression syntax("^[A-Za-z0-9_-]{20,128}$");
  return syntax.match(token).hasMatch();
}
} // namespace

CoreConnection::CoreConnection(QObject *parent) : CoreConnection(file(), parent) {}

CoreConnection::CoreConnection(const QString &path, QObject *parent)
    : QObject(parent), m_path(path), m_started(read(path)), m_saved(m_started) {}

QString CoreConnection::file() { return Folders::config() + "/core.json"; }

QUrl CoreConnection::origin(const QString &address) {
  QUrl url(address.trimmed(), QUrl::StrictMode);
  if (!url.isValid() || url.scheme() != "https" || url.host().isEmpty() ||
      !url.userInfo().isEmpty() || (!url.path().isEmpty() && url.path() != "/") ||
      url.hasQuery() || url.hasFragment())
    return {};
  url.setPath({});
  return url;
}

QJsonObject CoreConnection::read(const QString &path) {
  QFile source(path);
  if (!source.open(QIODevice::ReadOnly))
    return {};
  const QJsonObject saved = QJsonDocument::fromJson(source.readAll()).object();
  if (origin(saved.value("address").toString()).isEmpty() || !validToken(saved.value("token").toString()))
    return {};
  return saved;
}

void CoreConnection::save(const QJsonObject &connection) {
  if (!QDir().mkpath(QFileInfo(m_path).absolutePath())) {
    m_error = qtTrId("connectionSaveFailed");
    emit changed();
    return;
  }
  QSaveFile destination(m_path);
  const QByteArray bytes = QJsonDocument(connection).toJson(QJsonDocument::Compact);
  if (!destination.open(QIODevice::WriteOnly) ||
      !destination.setPermissions(QFile::ReadOwner | QFile::WriteOwner) ||
      destination.write(bytes) != bytes.size() || !destination.commit()) {
    m_error = qtTrId("connectionSaveFailed");
  } else {
    m_saved = connection;
    m_error.clear();
  }
  emit changed();
}

void CoreConnection::pair(const QString &address, const QString &code, const QString &name) {
  if (m_busy || overridden())
    return;
  const QUrl base = origin(address);
  if (base.isEmpty() || code.trimmed().isEmpty() || name.trimmed().isEmpty()) {
    m_error = qtTrId("connectionInvalid");
    emit changed();
    return;
  }
  QNetworkRequest request(base.resolved(QUrl("/api/v1/pair")));
  request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
  request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
  request.setTransferTimeout(20000);
  m_busy = true;
  m_error.clear();
  emit changed();
  const QByteArray body = QJsonDocument(QJsonObject{{"code", code.trimmed()}, {"name", name.trimmed()}})
                             .toJson(QJsonDocument::Compact);
  QNetworkReply *reply = m_network.post(request, body);
  connect(reply, &QNetworkReply::finished, this, [this, reply, base] {
    reply->deleteLater();
    m_busy = false;
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QJsonObject result = QJsonDocument::fromJson(reply->readAll()).object();
    const QString token = result.value("token").toString();
    const QString id = result.value("device").toObject().value("id").toString();
    if (reply->error() != QNetworkReply::NoError || status != 201 || !validToken(token) ||
        id.isEmpty()) {
      m_error = status == 401 ? qtTrId("connectionCodeExpired") : qtTrId("connectionFailed");
      emit changed();
      return;
    }
    save({{"address", base.toString()}, {"token", token}, {"deviceId", id}, {"enabled", true}});
  });
}

void CoreConnection::useLocal() {
  if (m_busy || overridden())
    return;
  QJsonObject saved = m_saved;
  saved["enabled"] = false;
  save(saved);
}

void CoreConnection::useRemote() {
  if (m_busy || overridden() || address().isEmpty())
    return;
  QJsonObject saved = m_saved;
  saved["enabled"] = true;
  save(saved);
}

void CoreConnection::forget() {
  if (!m_busy && !overridden())
    save({});
}
