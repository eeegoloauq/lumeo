#include "fakecore.h"

#include <QFile>
#include <QHttpServerRequest>
#include <QHttpServerResponder>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>

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

// A file as the core streams one: whole, or the range asked for, so that
// mpv can seek in it.
void serve(QHttpServerResponder &responder, const QByteArray &bytes, const QByteArray &type,
           const QByteArray &range) {
  using Status = QHttpServerResponder::StatusCode;
  QHttpHeaders headers;
  headers.append(QHttpHeaders::WellKnownHeader::ContentType, type);
  headers.append(QHttpHeaders::WellKnownHeader::AcceptRanges, "bytes");
  static const QRegularExpression asked("^bytes=(\\d+)-(\\d*)$");
  const QRegularExpressionMatch match = asked.match(QString::fromLatin1(range));
  if (!match.hasMatch()) {
    responder.write(bytes, headers, Status::Ok);
    return;
  }
  const qint64 first = match.captured(1).toLongLong();
  const qint64 last = match.captured(2).isEmpty()
                          ? bytes.size() - 1
                          : qMin<qint64>(match.captured(2).toLongLong(), bytes.size() - 1);
  if (first > last) {
    headers.append(QHttpHeaders::WellKnownHeader::ContentRange,
                   QByteArray("bytes */") + QByteArray::number(bytes.size()));
    responder.write(QByteArray(), headers, Status::RequestRangeNotSatisfiable);
    return;
  }
  headers.append(QHttpHeaders::WellKnownHeader::ContentRange,
                 QString("bytes %1-%2/%3").arg(first).arg(last).arg(bytes.size()).toLatin1());
  responder.write(bytes.mid(first, last - first + 1), headers, Status::PartialContent);
}

} // namespace

struct FakeCore::Held {
  QString key;
  QJsonValue body;
  QUrlQuery query;
  QByteArray range;
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
          new Held{key, parse(request.body()), request.query(), request.value("range"),
                   std::move(responder)}));
      return;
    }
    respond(key, parse(request.body()), request.query(), request.value("range"), responder);
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
  m_handlers.insert(method + " " + path,
                    [handler](const QJsonValue &body, const QUrlQuery &) { return handler(body); });
}

void FakeCore::onQuery(const QString &method, const QString &path, QueryHandler handler) {
  m_handlers.insert(method + " " + path, [handler](const QJsonValue &, const QUrlQuery &query) {
    return handler(query);
  });
}

void FakeCore::answerBy(const QString &method, const QString &path, const QString &key,
                        const QJsonObject &bodies) {
  onQuery(method, path, [key, bodies](const QUrlQuery &query) {
    const QJsonValue body = bodies[query.queryItemValue(key)];
    return body.isUndefined() ? std::pair{404, QJsonValue()} : std::pair{200, body};
  });
}

void FakeCore::file(const QString &path, const QByteArray &bytes, const QByteArray &type) {
  m_files.insert("GET " + path, {bytes, type});
}

void FakeCore::hold(const QString &method, const QString &path) {
  m_holding.append(method + " " + path);
}

void FakeCore::release() {
  m_holding.clear();
  auto held = std::move(m_held);
  for (const auto &request : held)
    respond(request->key, request->body, request->query, request->range, request->responder);
}

void FakeCore::respond(const QString &key, const QJsonValue &body, const QUrlQuery &query,
                       const QByteArray &range, QHttpServerResponder &responder) {
  if (const auto file = m_files.constFind(key); file != m_files.constEnd()) {
    serve(responder, file->first, file->second, range);
    return;
  }
  const auto handler = m_handlers.constFind(key);
  if (handler == m_handlers.constEnd()) {
    write(responder, 404, QJsonObject{{"error", "not faked: " + key}});
    return;
  }
  const auto [status, answer] = (*handler)(body, query);
  write(responder, status, answer);
}

QJsonValue FakeCore::fixture(const QString &name) {
  QFile file(QStringLiteral(LUMEO_FIXTURES "/") + name);
  if (!file.open(QIODevice::ReadOnly))
    qFatal("no fixture %s", qPrintable(file.fileName()));
  return parse(file.readAll());
}
