#pragma once

#include <QByteArray>
#include <QDeadlineTimer>
#include <QJsonValue>
#include <QNetworkAccessManager>
#include <QObject>
#include <QPointer>
#include <QUrl>
#include <QUrlQuery>
#include <QtQml/qqmlregistration.h>
#include <functional>
#include <memory>
#include <optional>

// The only way the client talks to the core. A core on this machine and one
// elsewhere are the same code with a different address and token
// (decisions/foundations.md).
class Core : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // The core reads the files and folders it is given, so a path picked here
  // means something to it only when it runs on this machine.
  Q_PROPERTY(bool onThisMachine READ onThisMachine CONSTANT)

public:
  // What came back: the status, or 0 when no answer came, and why.
  struct Reply {
    int status = 0;
    QByteArray body;
    QString failure;

    bool ok() const { return status >= 200 && status < 300; }
    QJsonValue json() const;
    // The core's explanation when it sent one, else the body, else why
    // nothing came.
    QString message() const;
  };
  using Answer = std::function<void(const Reply &)>;

  // The core LUMEO_CORE names, else the one on this machine with its token.
  explicit Core(QObject *parent = nullptr);
  // [tokenPath] empty: no token, as a core named by hand or a fake one.
  Core(const QUrl &address, const QString &tokenPath, QObject *parent = nullptr);

  static const QUrl local;
  // Where the core keeps its data, LUMEO_DATA first.
  static QString dataDir();
  static QUrl configuredAddress();

  QUrl address() const { return m_address; }
  bool onThisMachine() const {
    return m_address.scheme() == "http" &&
           (m_address.host() == "127.0.0.1" || m_address.host() == "localhost");
  }
  QString tokenPath() const { return m_tokenPath; }
  // What the core said it is on its last answer that said (Lumeo-Mode):
  // "full", "media", or empty before any did.
  QString mode() const { return m_mode; }
  // A path the core named, as an address mpv can open.
  QUrl url(const QString &path) const { return m_address.resolved(QUrl(path)); }
  // An id as one segment of a path, whatever it holds.
  static QString segment(const QString &id);

  // The token as headers, for what makes its own requests: mpv.
  Q_INVOKABLE QStringList headers();

  // Sends a request and calls [answer] with whatever came back, unless
  // [context] is gone by then. [body] undefined: none.
  void send(const QByteArray &method, const QString &path, const QUrlQuery &query,
            const QJsonValue &body, QObject *context, Answer answer);
  // The same with a body that is JSON already, sent as it is: a file the
  // core reads whole, which it checks and the client only carries.
  void send(const QByteArray &method, const QString &path, const QUrlQuery &query,
            const QByteArray &json, QObject *context, Answer answer);
  void get(const QString &path, const QUrlQuery &query, QObject *context, Answer answer) {
    send("GET", path, query, QJsonValue::Undefined, context, std::move(answer));
  }

  // How long a request may take without an answer, which is also how long
  // a core that is not listening yet is waited for. Tests shorten it.
  int patience = 20000;
  // The first wait before a refused request is sent again; it doubles up to
  // a second.
  int firstDelay = 100;

signals:
  void modeChanged();

private:
  struct Attempt;
  void start(const QByteArray &method, const QString &path, const QUrlQuery &query,
             const std::optional<QByteArray> &body, QObject *context, Answer answer);
  void attempt(const std::shared_ptr<Attempt> &pending);
  QByteArray token();
  bool reloadToken(const QByteArray &sent);

  QNetworkAccessManager m_network;
  QUrl m_address;
  QString m_tokenPath;
  QByteArray m_token;
  bool m_tokenRead = false;
  QString m_mode;
};
