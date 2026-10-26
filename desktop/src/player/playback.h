#pragma once

#include "next.h"
#include "tracks.h"

#include <QDateTime>
#include <QObject>
#include <QPointer>
#include <QQmlParserStatus>
#include <QTimer>
#include <QVariant>
#include <QtQml/qqmlregistration.h>

class Core;
class LocalSettings;
class MpvItem;
class Preferences;

// One download played in an MpvItem: waited for until the core says the
// front of its file is on disk, opened again while a stream that dropped
// may still come, resumed where it was left and reported back as it plays
// (decisions/player.md). The screen lays it out; everything it decides is
// here.
class Playback : public QObject, public QQmlParserStatus {
  Q_OBJECT
  QML_ELEMENT
  Q_INTERFACES(QQmlParserStatus)
  Q_PROPERTY(MpvItem *mpv READ mpv WRITE setMpv NOTIFY mpvChanged)
  Q_PROPERTY(QString downloadId MEMBER m_downloadId NOTIFY changed)
  // What the page that started it called it; the title once the core names a
  // file that came without one.
  Q_PROPERTY(QString name MEMBER m_name NOTIFY changed)
  Q_PROPERTY(QString title READ title NOTIFY changed)
  // The episode's own title, empty for a film or until the catalogue says.
  Q_PROPERTY(QString episodeTitle READ episodeTitle NOTIFY changed)
  // The download as the core last described it; empty until it answers.
  Q_PROPERTY(QVariantMap download READ download NOTIFY changed)
  // What an active download is doing: "findingPeers", "fetchingMetadata"
  // (asking the peers what the torrent holds) or "arriving".
  Q_PROPERTY(QString stage READ stage NOTIFY changed)
  // mpv has been handed the file.
  Q_PROPERTY(bool opened READ opened NOTIFY changed)
  Q_PROPERTY(Tracks *tracks READ tracks NOTIFY tracksChanged)
  Q_PROPERTY(Next *next READ next NOTIFY tracksChanged)
  // The title's episodes, for the episodes panel; empty for a film.
  Q_PROPERTY(QVariantList episodes READ episodes NOTIFY changed)
  // How long an episode runs, as the catalogue says; empty when it does not.
  Q_PROPERTY(QString runtime READ runtime NOTIFY changed)
  // The title's watching, {entries}, as last asked.
  Q_PROPERTY(QVariantMap watching READ watching NOTIFY changed)
  // close() has been called: what mpv says now is about no film.
  Q_PROPERTY(bool closing READ closing NOTIFY changed)
  // Why nothing plays, once that is the answer.
  Q_PROPERTY(Failure failure READ failure NOTIFY changed)
  // The codec the failure names, when mpv named one.
  Q_PROPERTY(QString codec READ codec NOTIFY changed)
  // The download has found no peers for noPeersPatience with the network up:
  // another copy is worth offering. Offline, no copy would do better.
  Q_PROPERTY(bool findingNoPeers READ findingNoPeers NOTIFY changed)
  // The waits below, which tests shorten.
  Q_PROPERTY(int noPeersPatience MEMBER noPeersPatience)
  Q_PROPERTY(int openPatience MEMBER openPatience)
  Q_PROPERTY(int pollInterval MEMBER pollInterval)
  Q_PROPERTY(int reopenStep MEMBER reopenStep)

public:
  enum Failure { None, CoreStopped, WouldNotStart };
  Q_ENUM(Failure)

  explicit Playback(QObject *parent = nullptr);

  void classBegin() override {}
  void componentComplete() override;

  MpvItem *mpv() const { return m_mpv; }
  void setMpv(MpvItem *mpv);
  QString title() const;
  QString episodeTitle() const { return m_episodeTitle; }
  QVariantMap download() const { return m_download; }
  QString stage() const;
  bool opened() const { return m_opened; }
  Tracks *tracks() const { return m_tracks; }
  Next *next() const { return m_next; }
  QVariantList episodes() const { return m_episodes; }
  QString runtime() const { return m_runtime; }
  QVariantMap watching() const { return m_watching; }
  bool closing() const { return m_closing; }
  Failure failure() const { return m_failure; }
  QString codec() const { return m_codec; }
  bool findingNoPeers() const;

  // Asks again at once rather than at the next poll.
  Q_INVOKABLE void retry();
  // Asks for the title's watching again, for the episodes panel.
  Q_INVOKABLE void loadProgress();
  // Leaves the film: the sound stops and closed() comes at once; finished()
  // once the position has reached the core, within three seconds whatever
  // happens, so that a window closing waits for it while the core answers.
  Q_INVOKABLE void close();

  // How long a film that failed to open is opened again, counted from the
  // first failure: a torrent may still be finding the bytes.
  int openPatience = 30000;
  // The download's poll.
  int pollInterval = 2000;
  // The wait before another attempt, times the attempts so far, up to five.
  int reopenStep = 2000;

  int noPeersPatience = 30000;

  // Which of a title's copies is the one playing, by its release name; -1
  // when none is.
  Q_INVOKABLE int playingCopy(const QVariantList &sources) const;
  // The copy to offer when this one finds no peers: the next in the core's
  // ranking after it.
  Q_INVOKABLE int nextCopy(const QVariantList &sources) const;

  // The codec an mpv error says it had no decoder for, else empty.
  static QString decoderCodec(const QString &line);

signals:
  void mpvChanged();
  void tracksChanged();
  void changed();
  // Something to say over the picture: a sound or picture decoder that
  // failed ("sound" or "picture"), naming [codec]; a file that stopped
  // ("failed"); a subtitle that could not be fetched ("subtitle").
  void notice(const QString &kind, const QString &codec);
  void closed();
  void finished();

private:
  void poll();
  void refresh();
  void open();
  void loadItem();
  void resume();
  void defineBindings();
  void onLoadFailed();
  void onLogged(const QString &line);
  void onPicture();
  // [watched]: it counts as watched whatever the position.
  void report(bool watched = false);
  void reported();
  bool dueToOpen() const;

  QPointer<MpvItem> m_mpv;
  Tracks *m_tracks = nullptr;
  Next *m_next = nullptr;
  Core *m_core = nullptr;
  Preferences *m_preferences = nullptr;
  LocalSettings *m_settings = nullptr;
  QString m_downloadId;
  QString m_name;
  QString m_named;
  QString m_episodeTitle;
  QVariantList m_episodes;
  QString m_runtime;
  QVariantMap m_watching;
  QVariantMap m_download;
  bool m_itemAsked = false;
  // Whether the download came without a title: a file opened with the app
  // plays at once and the core names it while it does.
  int m_openedUnnamed = -1;

  QTimer m_poll;
  bool m_opened = false;
  // Waiting for the tracks to be prepared before mpv is handed the file.
  bool m_opening = false;
  bool m_resumeAsked = false;
  Failure m_failure = None;
  QString m_codec;
  // mpv's last error line naming no codec, to explain a failure it reports
  // later: Windows without a working d3d11va logs one per hardware decoder
  // it tries before it decodes in software, and the film plays.
  QString m_lastError;
  int m_attempts = 0;
  QDateTime m_firstFailure;
  QDateTime m_reopenAt;
  bool m_reopenPending = false;

  QTimer m_progress;
  double m_lastReported = -1;
  double m_lastDelay = 0;
  bool m_reporting = false;
  bool m_reportAgain = false;
  bool m_watchedAgain = false;
  bool m_closing = false;
  // Where the film stood when it was closed: mpv stops at once.
  double m_closedAt = 0;
  double m_closedLength = 0;
  QTimer m_finishLimit;

  // The arrows' step, once our section is defined with it.
  int m_seekStep = 0;
};
