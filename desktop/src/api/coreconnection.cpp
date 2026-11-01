#include "coreconnection.h"

#include "core.h"
#include "folders.h"
#include "instance.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QSaveFile>

namespace {
bool validToken(const QString &token) {
  static const QRegularExpression syntax("^[A-Za-z0-9_-]{20,128}$");
  return syntax.match(token).hasMatch();
}
} // namespace

CoreConnection::CoreConnection(const QString &path, Core *app, Core *local, QObject *parent)
    : QObject(parent), m_path(path), m_app(app), m_local(local), m_started(read(path)),
      m_saved(m_started) {
  if (m_app)
    connect(m_app, &Core::modeChanged, this, &CoreConnection::follow);
}

CoreConnection *CoreConnection::create(QQmlEngine *qml, QJSEngine *) {
  auto *connection = new CoreConnection(file(), qml->singletonInstance<Core *>("Lumeo", "Core"));
  connection->readLink();
  return connection;
}

Core *CoreConnection::localCore() {
  if (!m_local)
    m_local = m_app && !usingServer() ? m_app : new Core(Core::local, Core::dataDir() + "/api-token", this);
  return m_local;
}

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
    if (result.value("mode").toString() == "media") {
      handOver(base, token);
      return;
    }
    save({{"address", base.toString()}, {"token", token}, {"deviceId", id}, {"enabled", true}});
    if (m_error.isEmpty())
      emit paired();
  });
}

void CoreConnection::readLink() {
  // While the app uses a server, its own core is not running.
  if (overridden() || usingServer())
    return;
  localCore()->get("/api/v1/link", {}, this, [this](const Core::Reply &reply) {
    // A core from before links has nothing to show.
    if (reply.ok())
      showLink(reply.json().toObject());
  });
}

void CoreConnection::showLink(const QJsonObject &link) {
  m_link = link.value("url").toString();
  m_running = link.value("running").toString();
  emit changed();
}

// The credential becomes this machine's core's, which checks it with the
// server before keeping it, and the client no longer keeps it: a direct
// connection to a media server would find none of the viewer's data there.
void CoreConnection::handOver(const QUrl &server, const QString &token) {
  m_busy = true;
  m_error.clear();
  emit changed();
  if (usingServer())
    Instance::startOwnCore();
  const QJsonObject body{{"url", server.toString()}, {"token", token}};
  localCore()->send("PUT", "/api/v1/link", {}, body, this, [this, server](const Core::Reply &reply) {
    m_busy = false;
    if (!reply.ok()) {
      qWarning("handing the media server to this machine's core failed: %s", qPrintable(reply.message()));
      m_error = qtTrId("connectionLinkFailed");
      emit changed();
      return;
    }
    m_link = reply.json()["url"].toString();
    m_running = reply.json()["running"].toString();
    QJsonObject saved = m_saved;
    if (origin(saved.value("address").toString()) == server)
      saved = {};
    else if (!saved.isEmpty())
      saved["enabled"] = false;
    if (saved != m_saved)
      save(saved);
    else
      emit changed();
    if (m_error.isEmpty())
      emit paired();
  });
}

// A full server used directly that turns into a media server hands its
// credential over as pairing with it would have.
void CoreConnection::follow() {
  if (m_followed || overridden() || !usingServer() || m_app->mode() != "media")
    return;
  m_followed = true;
  handOver(origin(m_started.value("address").toString()), m_started.value("token").toString());
}

void CoreConnection::unlink() {
  if (m_busy || overridden())
    return;
  m_busy = true;
  m_error.clear();
  emit changed();
  localCore()->send("DELETE", "/api/v1/link", {}, QJsonValue::Undefined, this, [this](const Core::Reply &reply) {
    m_busy = false;
    if (reply.ok()) {
      showLink(reply.json().toObject());
      return;
    }
    m_error = qtTrId("connectionSaveFailed");
    emit changed();
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
