#pragma once

#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QObject>
#include <QUrl>
#include <QtQml/qqmlregistration.h>

// Connection credentials belong to this device, separately from preferences
// and client.json. Changing cores takes effect on restart so an old request
// or a player's final progress report cannot reach the new core.
class CoreConnection : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QString address READ address NOTIFY changed)
  Q_PROPERTY(bool remote READ remote NOTIFY changed)
  Q_PROPERTY(bool busy READ busy NOTIFY changed)
  Q_PROPERTY(QString error READ error NOTIFY changed)
  Q_PROPERTY(bool restartNeeded READ restartNeeded NOTIFY changed)
  Q_PROPERTY(bool overridden READ overridden CONSTANT)

public:
  explicit CoreConnection(QObject *parent = nullptr);
  CoreConnection(const QString &path, QObject *parent = nullptr);
  static QString file();
  static QJsonObject read(const QString &path);
  static QUrl origin(const QString &address);

  QString address() const { return m_saved.value("address").toString(); }
  bool remote() const { return m_saved.value("enabled").toBool(); }
  bool busy() const { return m_busy; }
  QString error() const { return m_error; }
  bool restartNeeded() const { return m_started != m_saved; }
  bool overridden() const { return !qEnvironmentVariableIsEmpty("LUMEO_CORE"); }
  Q_INVOKABLE void pair(const QString &address, const QString &code, const QString &name);
  Q_INVOKABLE void useLocal();
  Q_INVOKABLE void useRemote();
  Q_INVOKABLE void forget();

signals:
  void changed();

private:
  void save(const QJsonObject &connection);
  QString m_path;
  QJsonObject m_started;
  QJsonObject m_saved;
  QNetworkAccessManager m_network;
  bool m_busy = false;
  QString m_error;
};
