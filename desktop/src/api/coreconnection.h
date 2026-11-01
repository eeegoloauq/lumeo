#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QSslCertificate>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantList>
#include <functional>
#include <QtQml/qqmlregistration.h>

class Core;
class QQmlEngine;
class QJSEngine;

// Connection credentials belong to this device, separately from preferences
// and client.json. Every server paired with stays saved, so going back to one
// needs no new pairing code. Changing cores takes effect on restart so an old
// request or a player's final progress report cannot reach the new core.
//
// A full server is talked to directly with its credential in core.json. A
// media server keeps none of its devices' personal data, so its credential
// goes to this machine's own core, which forwards to the server what it owns;
// the client talks only to that core (docs/remote-core.md). That core keeps
// every media server's credential and which it forwards to; core.json keeps
// their addresses alone, to list them while the app uses a full server and
// that core is not running. The server says which it is when it pairs, and on
// every answer, and the client follows it with no setting of its own.
class CoreConnection : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // Every saved server, as {address, media}.
  Q_PROPERTY(QVariantList servers READ servers NOTIFY changed)
  // The server the app uses from its next start, a full one or the media
  // server this machine's core forwards to; empty for that core alone.
  Q_PROPERTY(QString selected READ selected NOTIFY changed)
  // Whether that is a media server, for one saved as both.
  Q_PROPERTY(bool selectedMedia READ selectedMedia NOTIFY changed)
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
  // core.json with what is not valid left out; a file from before several
  // servers were saved reads as a list of its one.
  static QJsonObject read(const QString &path);
  // [file] with what is not valid left out.
  static QJsonObject valid(QJsonObject file);
  // The full server [saved] uses, empty for this machine's core.
  static QJsonObject inUse(const QJsonObject &saved);
  static QUrl origin(const QString &address);

  QVariantList servers() const;
  QString selected() const;
  bool selectedMedia() const { return m_saved.value("use").toString().isEmpty() && !m_link.isEmpty(); }
  bool busy() const { return m_busy; }
  QString error() const { return m_error; }
  bool restartNeeded() const;
  bool overridden() const { return !qEnvironmentVariableIsEmpty("LUMEO_CORE"); }
  Q_INVOKABLE void pair(const QString &address, const QString &code, const QString &name);
  // Uses a saved server from the next start, a media server through this
  // machine's core; empty for that core alone. A server that changed mode
  // can be saved as both.
  Q_INVOKABLE void use(const QString &address, bool media = false);
  // Forgets a saved server; the server keeps the device until revoked.
  Q_INVOKABLE void forget(const QString &address, bool media = false);
  // Asks this machine's core which media servers it keeps.
  void readLink();

signals:
  void changed();
  // Pairing ended with a connection to use after a restart.
  void paired();

private:
  void save(const QJsonObject &connection);
  bool usingServer() const { return !inUse(m_started).isEmpty(); }
  bool isFull(const QString &address) const;
  bool isMedia(const QString &address) const;
  Core *localCore();
  void showLink(const QJsonObject &link);
  // Changes the links of this machine's core, starting it when the app uses
  // a full server, and calls [done] once it has.
  void changeLink(const QByteArray &method, const QUrlQuery &query, const QJsonValue &body,
                  const QString &failure, std::function<void()> done);
  void sendPair(const QUrl &base, QJsonObject body, const QString &code, const QSslCertificate &shown);
  void handOver(const QUrl &server, const QString &token, const QString &certificate);
  void follow();
  QString m_path;
  Core *m_app = nullptr;
  Core *m_local = nullptr;
  // The media server this machine's core forwards to from its next start,
  // and the one it forwards to now.
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
