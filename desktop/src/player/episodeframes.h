#pragma once

#include <QObject>
#include <QPointer>
#include <QSet>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class Core;
class Downloads;
class FrameGrabber;
class QQmlEngine;
class QJSEngine;

// A frame from each episode on disk, for the cards the catalogue has no still
// for (every season after the first, for many series). Taken once, a third of
// the way in, and kept in the cache. An episode not on disk is never opened
// for one: that would start its torrent.
class EpisodeFrames : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // The frames taken, as file addresses by "itemId/season/episode".
  Q_PROPERTY(QVariantMap known READ known NOTIFY changed)

public:
  EpisodeFrames(Core *core, Downloads *downloads, const QString &directory,
                QObject *parent = nullptr);
  static EpisodeFrames *create(QQmlEngine *qml, QJSEngine *);

  QVariantMap known() const;

signals:
  void changed();

private:
  static QString name(const QString &itemId, int season, int episode);
  void update();

  Core *m_core;
  Downloads *m_downloads;
  QString m_directory;
  QSet<QString> m_known;
  // Taken or failed this session; a failure is not tried again until a
  // restart.
  QSet<QString> m_tried;
  // One frame at a time.
  QPointer<FrameGrabber> m_grabber;
};
