#pragma once

#include <QObject>
#include <QTimer>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class Core;
class QQmlEngine;
class QJSEngine;

// What the viewer says was watched, from the menu on any poster or card: a
// film or an episode marked watched or not, a series marked up to an
// episode, a title out of Continue watching or forgotten. Each says
// changed() once the core has it, and every page showing the title reads it
// again. Forgetting waits [undoTime] for undo() before the core is told, as
// a line taken out of History does. It also keeps which titles are finished,
// for the eye on every poster.
class Viewing : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // The title being forgotten, while undo() still keeps it; empty otherwise.
  Q_PROPERTY(QString forgetting READ forgetting NOTIFY forgettingChanged)
  // How long undo() is offered. Tests shorten it.
  Q_PROPERTY(int undoTime READ undoTime WRITE setUndoTime NOTIFY undoTimeChanged)
  // The titles seen to the end, by id, each true: a film watched, a series
  // caught up with. Read again after every change made here and on
  // refresh(); what the last answer said until the next one comes.
  Q_PROPERTY(QVariantMap finished READ finished NOTIFY finishedChanged)

public:
  explicit Viewing(Core *core, QObject *parent = nullptr);
  static Viewing *create(QQmlEngine *qml, QJSEngine *);
  // A title still waiting for its undo is forgotten now.
  ~Viewing() override;

  QString forgetting() const { return m_forgetting; }
  int undoTime() const { return m_undo.interval(); }
  void setUndoTime(int ms);
  QVariantMap finished() const { return m_finished; }

  // Asks the core again which titles are finished: the player marks as it
  // plays, so the window coming back calls it.
  Q_INVOKABLE void refresh();

  // A film (season and episode 0) or one episode, watched or not.
  Q_INVOKABLE void mark(const QString &itemId, int season, int episode, bool watched);
  // A series watched up to and including the episode named, its specials
  // aside; season -1 for every episode aired.
  Q_INVOKABLE void markThrough(const QString &itemId, int season = -1, int episode = 0);
  // Out of Continue watching until it is next played; where it was left stays.
  Q_INVOKABLE void hide(const QString &itemId);
  // Every position and watched mark of the title, after the undo time. A
  // title already waiting is forgotten first.
  Q_INVOKABLE void forget(const QString &itemId);
  Q_INVOKABLE void undo();

signals:
  void changed(const QString &itemId);
  // What the core did not take: "mark", "hide" or "forget".
  void refused(const QString &what);
  void forgettingChanged();
  void undoTimeChanged();
  void finishedChanged();

private:
  void commit();
  void send(const QByteArray &method, const QString &path, const QJsonValue &body,
            const QString &itemId, const QString &what);

  Core *m_core;
  QString m_forgetting;
  QTimer m_undo;
  QVariantMap m_finished;
  // A refresh asked while one is out goes again once it lands, so the last
  // answer is never older than the last change.
  bool m_asking = false;
  bool m_askAgain = false;
};
