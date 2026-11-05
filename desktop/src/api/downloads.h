#pragma once

#include "core.h"

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QQmlParserStatus>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;
class QJSEngine;

// Live download state, polled from the core: the core does not push
// progress. Fast while something moves, slow when nothing does.
class Downloads : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QVariantList all READ all NOTIFY listChanged)
  // What is actually moving: a failed or stopped download is not "1
  // downloading" with a frozen percentage.
  Q_PROPERTY(int running READ running NOTIFY listChanged)

public:
  explicit Downloads(Core *core, QObject *parent = nullptr);
  static Downloads *create(QQmlEngine *qml, QJSEngine *);

  QVariantList all() const { return m_all; }
  const QJsonArray &list() const { return m_downloads; }
  int running() const { return m_running; }
  // The mark on a poster, by title and by "title/season/episode" for the one
  // episode a card plays: {fraction} while any of it arrives, else {done}
  // when any of it is on disk; no entry when neither. A download paused or
  // given up on is not what the title is doing, and marks nothing. A corner
  // mark rather than a bar, so the one bar along a picture's bottom edge is
  // how much was watched (decisions/interface.md). QML reads one through
  // DownloadMark.
  const QVariantMap &marks() const { return m_marks; }

  // The download of a film or one episode: the copy on disk when there is
  // one among several. Empty when there is none.
  Q_INVOKABLE QVariantMap of(const QString &itemId, int season = 0, int episode = 0) const;
  // The catalogue title behind a download, once known: a row carries the
  // release's name.
  Q_INVOKABLE QVariantMap itemOf(const QString &itemId) const;

  // Starts a download, in the list from the core's answer rather than the
  // next poll; [answer] gets the reply. A prefetch is one nobody asked for
  // yet, which the core refuses with 507 when it does not fit.
  void start(const QString &itemId, const QJsonObject &source, int season, int episode,
             bool prefetch, QObject *context, std::function<void(const QJsonObject &, int)> answer);
  // Makes a file on this machine a download the player can open.
  void openLocal(const QString &path, QObject *context, Core::Answer answer);

  Q_INVOKABLE void pause(const QString &id) { setPaused(id, true); }
  // Fetches a paused download again, or retries a failed one.
  Q_INVOKABLE void resume(const QString &id) { setPaused(id, false); }
  // Stops a download and deletes what it fetched. Off the list now, so the
  // click visibly lands; a stop that failed comes back with the next poll.
  Q_INVOKABLE void stop(const QString &id);
  Q_INVOKABLE void refresh();

  // The polls' pace; tests shorten them.
  int activeInterval = 2000;
  int idleInterval = 15000;

signals:
  void listChanged();
  void marksChanged();
  // A download's catalogue title arrived, which itemOf() gives from now.
  void titlesChanged();

private:
  void setPaused(const QString &id, bool paused);
  // Says the list changed, with the marks worked out again and said only
  // when they moved.
  void update();
  void adopt(const QJsonObject &download);
  void resolveTitles();
  void schedule();

  Core *m_core;
  QJsonArray m_downloads;
  // Converted once for every binding that reads the list.
  QVariantList m_all;
  int m_running = 0;
  QHash<QString, QJsonObject> m_items;
  QVariantMap m_marks;
  QTimer m_poll;
  // Moves with every answer put in the list: a poll asked before it answers
  // without it, and must not put the old state back.
  int m_adopted = 0;
  // Stops sent and not yet answered.
  int m_stopping = 0;
};

// One poster's mark from Downloads::marks(), told only when that mark moves.
// A poll every two seconds while something downloads changes one title's
// ring; with the whole map as a property, every poster on every page read
// it again.
class DownloadMark : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  // A title's id, or "id/season/episode"; empty marks nothing.
  Q_PROPERTY(QString key READ key WRITE setKey NOTIFY keyChanged)
  // {fraction} or {done}; undefined for none.
  Q_PROPERTY(QVariant mark READ mark NOTIFY markChanged)

public:
  explicit DownloadMark(QObject *parent = nullptr) : QObject(parent) {}
  DownloadMark(Downloads *downloads, QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  QString key() const { return m_key; }
  void setKey(const QString &key);
  QVariant mark() const { return m_mark; }

signals:
  void keyChanged();
  void markChanged();

private:
  void watch(Downloads *downloads);
  void read();

  Downloads *m_downloads = nullptr;
  QString m_key;
  QVariant m_mark;
};
