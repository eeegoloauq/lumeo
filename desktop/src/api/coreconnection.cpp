#include "coreconnection.h"

#include "core.h"
#include "folders.h"
#include "instance.h"
#include "pins.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
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
  return valid(QJsonDocument::fromJson(source.readAll()).object());
}

QJsonObject CoreConnection::valid(QJsonObject file) {
  // One server, as kept before several were: used when it was enabled.
  if (!file.contains("servers") && file.contains("address")) {
    QJsonObject one = file;
    one.remove("enabled");
    file = {{"servers", QJsonArray{one}},
            {"use", file.value("enabled").toBool() ? file.value("address").toString() : QString()}};
  }
  QJsonArray servers;
  QStringList full;
  for (const QJsonValue &value : file.value("servers").toArray()) {
    QJsonObject server = value.toObject();
    const QString address = origin(server.value("address").toString()).toString();
    if (address.isEmpty() || full.contains(address) || !validToken(server.value("token").toString()))
      continue;
    if (server.contains("certificate") && QSslCertificate(server.value("certificate").toString().toLatin1()).isNull())
      continue;
    server["address"] = address;
    full << address;
    servers.append(server);
  }
  QJsonArray media;
  for (const QJsonValue &value : file.value("media").toArray()) {
    const QString address = origin(value.toString()).toString();
    if (!address.isEmpty() && !media.contains(address))
      media.append(address);
  }
  if (servers.isEmpty() && media.isEmpty())
    return {};
  QJsonObject saved{{"servers", servers}};
  const QString use = origin(file.value("use").toString()).toString();
  if (full.contains(use))
    saved["use"] = use;
  if (!media.isEmpty())
    saved["media"] = media;
  return saved;
}

QJsonObject CoreConnection::inUse(const QJsonObject &saved) {
  const QString use = saved.value("use").toString();
  for (const QJsonValue &server : saved.value("servers").toArray()) {
    if (!use.isEmpty() && server["address"].toString() == use)
      return server.toObject();
  }
  return {};
}

QVariantList CoreConnection::servers() const {
  QVariantList list;
  for (const QJsonValue &server : m_saved.value("servers").toArray())
    list << QVariantMap{{"address", server["address"].toString()}, {"media", false}};
  for (const QJsonValue &address : m_saved.value("media").toArray())
    list << QVariantMap{{"address", address.toString()}, {"media", true}};
  return list;
}

QString CoreConnection::selected() const {
  const QString use = m_saved.value("use").toString();
  return use.isEmpty() ? m_link : use;
}

// A full server re-paired is a new credential, so a restart too. While the
// app uses this machine's core, that core's link applies on its next start.
bool CoreConnection::restartNeeded() const {
  return inUse(m_started) != inUse(m_saved) || (!usingServer() && m_link != m_running);
}

bool CoreConnection::isFull(const QString &address) const {
  for (const QJsonValue &server : m_saved.value("servers").toArray()) {
    if (server["address"].toString() == address)
      return true;
  }
  return false;
}

bool CoreConnection::isMedia(const QString &address) const {
  return m_saved.value("media").toArray().contains(address);
}

void CoreConnection::save(const QJsonObject &connection) {
  if (!QDir().mkpath(QFileInfo(m_path).absolutePath())) {
    m_error = qtTrId("connectionSaveFailed");
    emit changed();
    return;
  }
  const QJsonObject kept = valid(connection);
  QSaveFile destination(m_path);
  const QByteArray bytes = QJsonDocument(kept).toJson(QJsonDocument::Compact);
  if (!destination.open(QIODevice::WriteOnly) ||
      !destination.setPermissions(QFile::ReadOwner | QFile::WriteOwner) ||
      destination.write(bytes) != bytes.size() || !destination.commit()) {
    m_error = qtTrId("connectionSaveFailed");
  } else {
    m_saved = kept;
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
    QJsonObject server{{"address", base.toString()}, {"token", token}, {"deviceId", id}};
    if (!certificate.isEmpty())
      server["certificate"] = certificate;
    // In place of an earlier credential for the same server.
    QJsonArray servers;
    for (const QJsonValue &kept : m_saved.value("servers").toArray()) {
      if (kept["address"].toString() != server["address"].toString())
        servers.append(kept);
    }
    servers.append(server);
    QJsonObject saved = m_saved;
    saved["servers"] = servers;
    saved["use"] = server["address"];
    save(saved);
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
  // The addresses alone, to list them while that core is not running.
  const QJsonArray media = link.value("saved").toArray();
  if (link.contains("saved") && media != m_saved.value("media").toArray()) {
    QJsonObject saved = m_saved;
    saved["media"] = media;
    save(saved);
    return;
  }
  emit changed();
}

void CoreConnection::changeLink(const QByteArray &method, const QUrlQuery &query, const QJsonValue &body,
                                const QString &failure, std::function<void()> done) {
  m_busy = true;
  m_error.clear();
  emit changed();
  if (usingServer())
    Instance::startOwnCore();
  localCore()->send(method, "/api/v1/link", query, body, this, [this, failure, done](const Core::Reply &reply) {
    m_busy = false;
    if (!reply.ok()) {
      qWarning("changing the link of this machine's core failed: %s", qPrintable(reply.message()));
      m_error = failure;
      emit changed();
      return;
    }
    showLink(reply.json().toObject());
    if (m_error.isEmpty() && done)
      done();
  });
}

// The credential becomes this machine's core's, which checks it with the
// server before keeping it, and the client no longer keeps it: a direct
// connection to a media server would find none of the viewer's data there.
void CoreConnection::handOver(const QUrl &server, const QString &token, const QString &certificate) {
  QJsonObject body{{"url", server.toString()}, {"token", token}};
  if (!certificate.isEmpty())
    body["certificate"] = certificate;
  changeLink("PUT", {}, body, qtTrId("connectionLinkFailed"), [this, server] {
    // A full server that became this one is not used directly any more.
    QJsonObject saved = m_saved;
    QJsonArray servers;
    for (const QJsonValue &kept : saved.value("servers").toArray()) {
      if (origin(kept["address"].toString()) != server)
        servers.append(kept);
    }
    saved["servers"] = servers;
    saved.remove("use");
    save(saved);
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
  const QJsonObject server = inUse(m_started);
  handOver(origin(server.value("address").toString()), server.value("token").toString(),
           server.value("certificate").toString());
}

void CoreConnection::use(const QString &address, bool media) {
  if (m_busy || overridden())
    return;
  if (!media && isFull(address)) {
    QJsonObject saved = m_saved;
    saved["use"] = address;
    save(saved);
    return;
  }
  if (!address.isEmpty() && (!media || !isMedia(address)))
    return;
  // This machine's core, forwarding to the media server or to none.
  changeLink("PATCH", {}, QJsonObject{{"url", address}}, qtTrId("connectionSaveFailed"), [this] {
    QJsonObject saved = m_saved;
    saved.remove("use");
    if (saved != m_saved)
      save(saved);
  });
}

void CoreConnection::forget(const QString &address, bool media) {
  if (m_busy || overridden())
    return;
  if (media) {
    changeLink("DELETE", QUrlQuery{{"url", address}}, QJsonValue::Undefined, qtTrId("connectionSaveFailed"), {});
    return;
  }
  QJsonObject saved = m_saved;
  QJsonArray servers;
  for (const QJsonValue &kept : saved.value("servers").toArray()) {
    if (kept["address"].toString() != address)
      servers.append(kept);
  }
  saved["servers"] = servers;
  if (saved.value("use").toString() == address)
    saved.remove("use");
  save(saved);
}
