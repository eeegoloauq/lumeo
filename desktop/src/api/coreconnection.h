#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QSslCertificate>
#include <QUrl>
#include <QtQml/qqmlregistration.h>

class Core;
class QQmlEngine;
class QJSEngine;

// Connection credentials belong to this device, separately from preferences
// and client.json. Changing cores takes effect on restart so an old request
// or a player's final progress report cannot reach the new core.
//
// A full server is talked to directly with the credential in core.json. A
// media server keeps none of its devices' personal data, so its credential
// goes to this machine's own core, which forwards to the server what it owns;
// the client talks only to that core (docs/remote-core.md). The server says
// which it is when it pairs, and on every answer, and the client follows it
// with no setting of its own.
class CoreConnection : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QString address READ address NOTIFY changed)
  Q_PROPERTY(bool remote READ remote NOTIFY changed)
  // The media server this machine's core forwards to from its next start.
  Q_PROPERTY(QString server READ server NOTIFY changed)
  Q_PROPERTY(bool busy READ busy NOTIFY changed)
  Q_PROPERTY(QString error READ error NOTIFY changed)
  Q_PROPERTY(bool restartNeeded READ restartNeeded NOTIFY changed)
  Q_PROPERTY(bool overridden READ overridden CONSTANT)

public:
  // [app] is the core the app talks to, whose answers say the server's mode;
  // [local] this machine's core, which is [app] when the app uses it.
  explicit CoreConnection(const QString &path, Core *app = nullptr, Core *local = nullptr,
                          QObject *parent = nullptr);
  // Not default-constructible: QML would take a default constructor over this.
  static CoreConnection *create(QQmlEngine *qml, QJSEngine *);
  static QString file();
  static QJsonObject read(const QString &path);
  static QUrl origin(const QString &address);

  QString address() const { return m_saved.value("address").toString(); }
  bool remote() const { return m_saved.value("enabled").toBool(); }
  bool busy() const { return m_busy; }
  QString error() const { return m_error; }
  QString server() const { return m_link; }
  bool restartNeeded() const { return m_started != m_saved || m_link != m_running; }
  bool overridden() const { return !qEnvironmentVariableIsEmpty("LUMEO_CORE"); }
  Q_INVOKABLE void pair(const QString &address, const QString &code, const QString &name);
  Q_INVOKABLE void useLocal();
  Q_INVOKABLE void useRemote();
  Q_INVOKABLE void forget();
  // Asks this machine's core which media server it is linked to.
  void readLink();
  // Forgets the media server; the server keeps the device until revoked.
  Q_INVOKABLE void unlink();

signals:
  void changed();
  // Pairing ended with a connection to use after a restart.
  void paired();

private:
  void save(const QJsonObject &connection);
  bool usingServer() const { return m_started.value("enabled").toBool(); }
  Core *localCore();
  void showLink(const QJsonObject &link);
  void sendPair(const QUrl &base, QJsonObject body, const QString &code, const QSslCertificate &shown);
  void handOver(const QUrl &server, const QString &token, const QString &certificate);
  void follow();
  QString m_path;
  Core *m_app = nullptr;
  Core *m_local = nullptr;
  // The media server this machine's core links to from its next start, and
  // the one it forwards to now.
  QString m_link;
  QString m_running;
  // A server used directly said it became a media server, once.
  bool m_followed = false;
  QJsonObject m_started;
  QJsonObject m_saved;
  QNetworkAccessManager m_network;
  bool m_busy = false;
  QString m_error;
};
