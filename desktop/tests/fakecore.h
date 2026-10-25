#pragma once

#include <QHash>
#include <QHttpServer>
#include <QJsonValue>
#include <QObject>
#include <QTcpServer>
#include <QUrl>
#include <functional>
#include <memory>
#include <vector>

// A core for tests, on a real socket: it answers what a test sets, from the
// core's JSON in client/test/fixtures/core/, which
// core/internal/api/fixtures_test.go checks against the types the handlers
// write. It keeps none of the core's rules (docs/decisions/testing.md).
class FakeCore : public QObject {
  Q_OBJECT
  Q_PROPERTY(QStringList requests READ requests NOTIFY requested)

public:
  explicit FakeCore(QObject *parent = nullptr);
  ~FakeCore() override;

  // Listens on [port], any free one when 0.
  bool listen(quint16 port = 0);
  QUrl address() const;

  // Every request so far, as "METHOD /path?query body".
  QStringList requests() const { return m_requests; }

  // What [method] [path] answers from now on: [status] and [body].
  Q_INVOKABLE void answer(const QString &method, const QString &path, int status,
                          const QJsonValue &body = QJsonValue::Undefined);
  // An answer worked out from the request's body.
  using Handler = std::function<std::pair<int, QJsonValue>(const QJsonValue &body)>;
  void on(const QString &method, const QString &path, Handler handler);

  // Leaves [method] [path] unanswered until release(): a request in flight.
  Q_INVOKABLE void hold(const QString &method, const QString &path);
  Q_INVOKABLE void release();

  // A request without this token is refused, as the core refuses it.
  QByteArray token;

  static QJsonValue fixture(const QString &name);

signals:
  void requested();

private:
  struct Held;
  void respond(const QString &key, const QJsonValue &body, QHttpServerResponder &responder);

  QHttpServer m_server;
  QTcpServer *m_tcp = nullptr;
  QStringList m_requests;
  QHash<QString, Handler> m_handlers;
  QStringList m_holding;
  std::vector<std::unique_ptr<Held>> m_held;
};
