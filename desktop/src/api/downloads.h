#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class Core;
class QQmlEngine;
class QJSEngine;

// Live download state, polled from the core: the core does not push
// progress. Fast while something moves, slow when nothing does.
class Downloads : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QVariantList all READ all NOTIFY changed)
  // What is actually moving: a failed or stopped download is not "1
  // downloading" with a frozen percentage.
  Q_PROPERTY(int running READ running NOTIFY changed)
  // The mark on a poster, by title and by "title/season/episode" for the one
  // episode a card plays: {fraction} while any of it arrives, else {done}
  // when any of it is on disk; no entry when neither. A download paused or
  // given up on is not what the title is doing, and marks nothing. A corner
  // mark rather than a bar, so the one bar along a picture's bottom edge is
  // how much was watched (decisions/interface.md).
  Q_PROPERTY(QVariantMap marks READ marks NOTIFY changed)

public:
  explicit Downloads(Core *core, QObject *parent = nullptr);
  static Downloads *create(QQmlEngine *qml, QJSEngine *);

  QVariantList all() const { return m_downloads.toVariantList(); }
  int running() const;
  QVariantMap marks() const { return m_marks; }

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
  void openLocal(const QString &path, QObject *context,
                 std::function<void(const QJsonObject &, int)> answer);

  Q_INVOKABLE void pause(const QString &id) { setPaused(id, true); }
  // Fetches a paused download again, or retries a failed one.
  Q_INVOKABLE void resume(const QString &id) { setPaused(id, false); }
  // Off the list now, so the click visibly lands; a stop that failed comes
  // back with the next poll.
  Q_INVOKABLE void forget(const QString &id);
  Q_INVOKABLE void refresh();

  // The polls' pace; tests shorten them.
  int activeInterval = 2000;
  int idleInterval = 15000;

signals:
  void changed();

private:
  void setPaused(const QString &id, bool paused);
  // Emits changed with the marks worked out again.
  void update();
  void adopt(const QJsonObject &download);
  void resolveTitles();
  void schedule();

  Core *m_core;
  QJsonArray m_downloads;
  QHash<QString, QJsonObject> m_items;
  QVariantMap m_marks;
  QTimer m_poll;
  // Moves with every answer put in the list: a poll asked before it answers
  // without it, and must not put the old state back.
  int m_adopted = 0;
};
