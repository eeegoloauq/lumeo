#pragma once

#include <QJsonArray>
#include <QObject>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class Core;
class QQmlEngine;
class QJSEngine;

// The prototype's way to a download playing: search, a title's copies, a
// download started and waited on until mpv can open it, and a file on this
// machine made a download. It goes as the screens of docs/qt-port.md, step 3,
// replace Browse.qml.
class Prototype : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QString status READ status NOTIFY statusChanged)

public:
  explicit Prototype(Core *core, QObject *parent = nullptr);
  static Prototype *create(QQmlEngine *qml, QJSEngine *);

  QString status() const { return m_status; }

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
  void waitForReady(const QString &downloadId);
  void setStatus(const QString &status);
  // The reply's message as the status when it failed.
  bool failed(const QByteArray &method, const QString &path, int status, const QString &message);

  Core *m_core;
  QJsonArray m_sources;
  QTimer m_poll;
  QString m_waitingFor;
  QString m_status;
};
