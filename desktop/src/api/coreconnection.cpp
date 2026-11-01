#include "coreconnection.h"

#include "core.h"
#include "folders.h"
#include "instance.h"
#include "pins.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QNetworkReply>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSslConfiguration>
#include <memory>

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
  if (saved.contains("certificate") && QSslCertificate(saved.value("certificate").toString().toLatin1()).isNull())
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

// A server whose certificate an authority vouches for is sent the code. One
// that serves its own certificate is sent a proof of the code over the
// certificate it showed, and pinned once it proves the code back
// (core/internal/remote/proof.go). The probe that tells them apart sends
// nothing past a certificate it cannot verify.
void CoreConnection::pair(const QString &address, const QString &code, const QString &name) {
  if (m_busy || overridden())
    return;
  const QUrl base = origin(address);
  if (base.isEmpty() || code.trimmed().isEmpty() || name.trimmed().isEmpty()) {
    m_error = qtTrId("connectionInvalid");
    emit changed();
    return;
  }
  QNetworkRequest probe(base.resolved(QUrl("/healthz")));
  probe.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
  probe.setTransferTimeout(20000);
  m_busy = true;
  m_error.clear();
  emit changed();
  QNetworkReply *reply = m_network.get(probe);
  auto shown = std::make_shared<QSslCertificate>();
  auto refused = std::make_shared<QList<QSslError>>();
  connect(reply, &QNetworkReply::sslErrors, this, [reply, shown, refused](const QList<QSslError> &errors) {
    *shown = reply->sslConfiguration().peerCertificate();
    *refused = errors;
  });
  connect(reply, &QNetworkReply::finished, this, [this, reply, base, shown, refused, code, name] {
    reply->deleteLater();
    const QJsonObject device{{"name", name.trimmed()}};
    if (refused->isEmpty()) {
      if (reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt() == 0) {
        m_busy = false;
        m_error = qtTrId("connectionFailed");
        emit changed();
        return;
      }
      QJsonObject body = device;
      body["code"] = code.trimmed();
      sendPair(base, body, code.trimmed(), QSslCertificate());
      return;
    }
    // The player checks the name as well: a certificate for another one
    // would pair and then play nothing.
    if (!Pins::names(*shown, base.host())) {
      m_busy = false;
      m_error = qtTrId("connectionWrongAddress");
      emit changed();
      return;
    }
    // Only a certificate no authority vouches for; an expired one, or one
    // refused for anything else, is not a core's own.
    static const QList<QSslError::SslError> unvouched{
        QSslError::SelfSignedCertificate, QSslError::CertificateUntrusted,
        QSslError::UnableToGetLocalIssuerCertificate, QSslError::UnableToVerifyFirstCertificate};
    for (const QSslError &error : *refused) {
      if (!unvouched.contains(error.error())) {
        m_busy = false;
        m_error = qtTrId("connectionFailed");
        emit changed();
        return;
      }
    }
    QJsonObject body = device;
    body["proof"] = Pins::deviceProof(code.trimmed(), *shown);
    sendPair(base, body, code.trimmed(), *shown);
  });
}

void CoreConnection::sendPair(const QUrl &base, QJsonObject body, const QString &code, const QSslCertificate &shown) {
  QNetworkRequest request(base.resolved(QUrl("/api/v1/pair")));
  request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
  request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::ManualRedirectPolicy);
  request.setTransferTimeout(20000);
  QNetworkReply *reply = m_network.post(request, QJsonDocument(body).toJson(QJsonDocument::Compact));
  if (!shown.isNull())
    Pins::trust(reply, shown);
  connect(reply, &QNetworkReply::finished, this, [this, reply, base, code, shown] {
    reply->deleteLater();
    m_busy = false;
    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    const QJsonObject result = QJsonDocument::fromJson(reply->readAll()).object();
    const QString token = result.value("token").toString();
    const QString id = result.value("device").toObject().value("id").toString();
    // Only a holder of the code proves it: anything else did not issue it,
    // and its certificate is not kept.
    const bool proven = shown.isNull() || result.value("proof").toString() == Pins::serverProof(code, shown);
    if (reply->error() != QNetworkReply::NoError || status != 201 || !validToken(token) ||
        id.isEmpty() || !proven) {
      m_error = status == 401 ? qtTrId("connectionCodeExpired") : qtTrId("connectionFailed");
      emit changed();
      return;
    }
    const QString certificate = shown.isNull() ? QString() : QString::fromLatin1(shown.toPem());
    if (result.value("mode").toString() == "media") {
      handOver(base, token, certificate);
      return;
    }
    QJsonObject connection{{"address", base.toString()}, {"token", token}, {"deviceId", id}, {"enabled", true}};
    if (!certificate.isEmpty())
      connection["certificate"] = certificate;
    save(connection);
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
  // The server's artwork is loaded from it directly, over the certificate
  // this machine's core pinned.
  Pins::add(QUrl(m_running), QSslCertificate(link.value("certificate").toString().toLatin1()));
  emit changed();
}

// The credential becomes this machine's core's, which checks it with the
// server before keeping it, and the client no longer keeps it: a direct
// connection to a media server would find none of the viewer's data there.
void CoreConnection::handOver(const QUrl &server, const QString &token, const QString &certificate) {
  m_busy = true;
  m_error.clear();
  emit changed();
  if (usingServer())
    Instance::startOwnCore();
  QJsonObject body{{"url", server.toString()}, {"token", token}};
  if (!certificate.isEmpty())
    body["certificate"] = certificate;
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
  handOver(origin(m_started.value("address").toString()), m_started.value("token").toString(),
           m_started.value("certificate").toString());
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
