#include "fakecore.h"

#include <QFile>
#include <QHttpServerRequest>
#include <QHttpServerResponder>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

namespace {

QString methodName(QHttpServerRequest::Method method) {
  switch (method) {
  case QHttpServerRequest::Method::Get: return "GET";
  case QHttpServerRequest::Method::Post: return "POST";
  case QHttpServerRequest::Method::Put: return "PUT";
  case QHttpServerRequest::Method::Patch: return "PATCH";
  case QHttpServerRequest::Method::Delete: return "DELETE";
  default: return "OTHER";
  }
}

QJsonValue parse(const QByteArray &body) {
  const QJsonDocument document = QJsonDocument::fromJson(body);
  return document.isArray() ? QJsonValue(document.array()) : QJsonValue(document.object());
}

void write(QHttpServerResponder &responder, int status, const QJsonValue &body) {
  const auto code = QHttpServerResponder::StatusCode(status);
  if (body.isUndefined() || body.isNull())
    responder.write(code);
  else if (body.isArray())
    responder.write(QJsonDocument(body.toArray()), code);
  else
    responder.write(QJsonDocument(body.toObject()), code);
}

} // namespace

struct FakeCore::Held {
  QString key;
  QJsonValue body;
  QHttpServerResponder responder;
};

FakeCore::FakeCore(QObject *parent) : QObject(parent) {
  m_server.setMissingHandler(this, [this](const QHttpServerRequest &request,
                                          QHttpServerResponder &responder) {
    const QString method = methodName(request.method());
    const QString path = request.url().path();
    const QString query = request.url().query();
    m_requests.append(method + " " + path + (query.isEmpty() ? "" : "?" + query) +
                      (request.body().isEmpty() ? "" : " " + QString::fromUtf8(request.body())));
    emit requested();
    if (!token.isEmpty() && request.value("authorization") != "Bearer " + token) {
      write(responder, 401, QJsonObject{{"error", "missing or wrong api token"}});
      return;
    }
    const QString key = method + " " + path;
    if (m_holding.contains(key)) {
      m_held.push_back(std::unique_ptr<Held>(
          new Held{key, parse(request.body()), std::move(responder)}));
      return;
    }
    respond(key, parse(request.body()), responder);
  });
}

FakeCore::~FakeCore() = default;

bool FakeCore::listen(quint16 port) {
  m_tcp = new QTcpServer(this);
  return m_tcp->listen(QHostAddress::LocalHost, port) && m_server.bind(m_tcp);
}

QUrl FakeCore::address() const {
  return QUrl(QString("http://127.0.0.1:%1").arg(m_tcp ? m_tcp->serverPort() : 0));
}

void FakeCore::answer(const QString &method, const QString &path, int status,
                      const QJsonValue &body) {
  on(method, path, [status, body](const QJsonValue &) { return std::pair{status, body}; });
}

void FakeCore::on(const QString &method, const QString &path, Handler handler) {
  m_handlers.insert(method + " " + path, std::move(handler));
}

void FakeCore::hold(const QString &method, const QString &path) {
  m_holding.append(method + " " + path);
}

void FakeCore::release() {
  m_holding.clear();
  auto held = std::move(m_held);
  for (const auto &request : held)
    respond(request->key, request->body, request->responder);
}

void FakeCore::respond(const QString &key, const QJsonValue &body,
                       QHttpServerResponder &responder) {
  const auto handler = m_handlers.constFind(key);
  if (handler == m_handlers.constEnd()) {
    write(responder, 404, QJsonObject{{"error", "not faked: " + key}});
    return;
  }
  const auto [status, answer] = (*handler)(body);
  write(responder, status, answer);
}

QJsonValue FakeCore::fixture(const QString &name) {
  QFile file(QStringLiteral(LUMEO_FIXTURES "/") + name);
  if (!file.open(QIODevice::ReadOnly))
    qFatal("no fixture %s", qPrintable(file.fileName()));
  return parse(file.readAll());
}
