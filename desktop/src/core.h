#pragma once

#include <QJsonArray>
#include <QNetworkAccessManager>
#include <QObject>
#include <QTimer>
#include <QUrl>
#include <QVariant>
#include <QtQml/qqmlregistration.h>
#include <functional>

class QNetworkReply;

// The core over HTTP, as much of it as the prototype needs: search, a
// title's sources, a download started and waited on until mpv can open it,
// and a file on this machine made a download ("Open with Lumeo").
class Core : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)

public:
  explicit Core(QObject *parent = nullptr);

  QString status() const { return m_status; }

  // What every request mpv makes to the core carries.
  Q_INVOKABLE QStringList headers() const;

  Q_INVOKABLE void search(const QString &query);
  Q_INVOKABLE void sources(const QString &itemId, int season, int episode);
  Q_INVOKABLE void play(const QString &itemId, int index, int season, int episode);
  Q_INVOKABLE void openLocal(const QString &path);

signals:
  void statusChanged();
  void searched(const QString &query, const QString &kind, const QVariantList &items);
  void sourcesListed(const QVariantList &sources);
  void playable(const QString &url);

private:
  using Answer = std::function<void(const QJsonValue &)>;
  void request(const QByteArray &method, const QString &path, const QUrlQuery &query,
               const QJsonObject *body, const Answer &answer);
  void waitForReady(const QString &downloadId);
  void setStatus(const QString &status);

  QNetworkAccessManager m_network;
  QUrl m_base;
  QByteArray m_token;
  QJsonArray m_sources;
  QTimer m_poll;
  QString m_waitingFor;
  QString m_status;
};
