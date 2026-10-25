#include "core.h"

#include <QDir>
#include <QJsonArray>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QTimer>

const QUrl Core::local("http://127.0.0.1:7666");

QString Core::dataDir() {
  const QString chosen = qEnvironmentVariable("LUMEO_DATA");
  if (!chosen.isEmpty())
    return chosen;
#ifdef Q_OS_WIN
  return qEnvironmentVariable("LOCALAPPDATA") + "/Lumeo/Data";
#else
  const QString xdg = qEnvironmentVariable("XDG_DATA_HOME");
  return (xdg.isEmpty() ? QDir::homePath() + "/.local/share" : xdg) + "/lumeo";
#endif
}

namespace {

QUrl chosenAddress() {
  const QString address = qEnvironmentVariable("LUMEO_CORE");
  return address.isEmpty() ? Core::local : QUrl(address);
}

} // namespace

// The local core's secret goes to the local core only.
Core::Core(QObject *parent)
    : Core(chosenAddress(),
           chosenAddress() == local ? dataDir() + "/api-token" : QString(), parent) {}

Core::Core(const QUrl &address, const QString &tokenPath, QObject *parent)
    : QObject(parent), m_address(address), m_tokenPath(tokenPath) {}

QString Core::segment(const QString &id) { return QUrl::toPercentEncoding(id); }

QStringList Core::headers() {
  const QByteArray value = token();
  return value.isEmpty() ? QStringList{} : QStringList{"Authorization: Bearer " + value};
}

QByteArray Core::token() {
  if (!m_tokenRead && !m_tokenPath.isEmpty()) {
    QFile file(m_tokenPath);
    m_token = file.open(QIODevice::ReadOnly) ? file.readAll().trimmed() : QByteArray();
  }
  m_tokenRead = true;
  return m_token;
}

// A core started for the first time writes its token only just before it
// listens, after the client may have looked; a refusal reads the file again.
bool Core::reloadToken(const QByteArray &sent) {
  m_tokenRead = false;
  const QByteArray fresh = token();
  return !fresh.isEmpty() && fresh != sent;
}

struct Core::Attempt {
  QByteArray method;
  QUrl url;
  QByteArray body;
  bool hasBody = false;
  QPointer<QObject> context;
  Answer answer;
  QDeadlineTimer deadline;
  int delay = 0;
  bool tokenRetried = false;
};

void Core::send(const QByteArray &method, const QString &path, const QUrlQuery &query,
                const QJsonValue &body, QObject *context, Answer answer) {
  auto pending = std::make_shared<Attempt>();
  pending->method = method;
  pending->url = url(path);
  pending->url.setQuery(query);
  if (!body.isUndefined()) {
    pending->hasBody = true;
    pending->body = body.isArray() ? QJsonDocument(body.toArray()).toJson(QJsonDocument::Compact)
                                   : QJsonDocument(body.toObject()).toJson(QJsonDocument::Compact);
  }
  pending->context = context;
  pending->answer = std::move(answer);
  pending->deadline = QDeadlineTimer(patience);
  pending->delay = firstDelay;
  attempt(pending);
}

void Core::attempt(const std::shared_ptr<Attempt> &pending) {
  QNetworkRequest request(pending->url);
  request.setTransferTimeout(patience);
  const QByteArray sent = token();
  if (!sent.isEmpty())
    request.setRawHeader("Authorization", "Bearer " + sent);
  if (pending->hasBody)
    request.setHeader(QNetworkRequest::ContentTypeHeader, "application/json");
  QNetworkReply *reply = m_network.sendCustomRequest(request, pending->method, pending->body);
  connect(reply, &QNetworkReply::finished, this, [this, reply, pending, sent] {
    reply->deleteLater();
    if (!pending->context)
      return;
    Reply answer;
    answer.status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    answer.body = reply->readAll();
    // The app starts its core with the window, and a new core waits for the
    // old one to finish before it listens: for a few seconds the address
    // refuses. A refused connection never reached the core, so sending it
    // again is safe whatever the method.
    if (reply->error() == QNetworkReply::ConnectionRefusedError &&
        pending->deadline.remainingTime() > pending->delay) {
      QTimer::singleShot(pending->delay, this, [this, pending] { attempt(pending); });
      pending->delay = std::min(pending->delay * 2, 1000);
      return;
    }
    if (answer.status == 401 && !pending->tokenRetried && reloadToken(sent)) {
      pending->tokenRetried = true;
      attempt(pending);
      return;
    }
    if (answer.status == 0)
      answer.failure = reply->errorString();
    pending->answer(answer);
  });
}

QJsonValue Core::Reply::json() const {
  const QJsonDocument document = QJsonDocument::fromJson(body);
  if (document.isArray())
    return document.array();
  return document.object();
}

QString Core::Reply::message() const {
  if (status == 0)
    return failure;
  const QJsonValue error = QJsonDocument::fromJson(body)["error"];
  // A proxy or a broken core may answer in plain text, which is then the
  // best explanation there is.
  return error.isString() ? error.toString() : QString::fromUtf8(body).trimmed();
}
