#pragma once

#include <QDBusAbstractAdaptor>
#include <QDBusObjectPath>
#include <QVariantMap>

class Playback;

class MprisRoot : public QDBusAbstractAdaptor {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2")
  Q_PROPERTY(bool CanQuit READ unsupported)
  Q_PROPERTY(bool CanRaise READ unsupported)
  Q_PROPERTY(bool HasTrackList READ unsupported)
  Q_PROPERTY(QString Identity READ identity)
  Q_PROPERTY(QString DesktopEntry READ desktopEntry)
  Q_PROPERTY(QStringList SupportedUriSchemes READ unsupportedTypes)
  Q_PROPERTY(QStringList SupportedMimeTypes READ unsupportedTypes)

public:
  explicit MprisRoot(QObject *parent);
  bool unsupported() const { return false; }
  QString identity() const;
  QString desktopEntry() const;
  QStringList unsupportedTypes() const { return {}; }

public slots:
  void Raise() {}
  void Quit() {}
};

class Mpris : public QDBusAbstractAdaptor {
  Q_OBJECT
  Q_CLASSINFO("D-Bus Interface", "org.mpris.MediaPlayer2.Player")
  Q_PROPERTY(QString PlaybackStatus READ playbackStatus)
  Q_PROPERTY(QVariantMap Metadata READ metadata)
  Q_PROPERTY(double Rate READ rate WRITE setRate)
  Q_PROPERTY(double MinimumRate READ minimumRate)
  Q_PROPERTY(double MaximumRate READ maximumRate)
  Q_PROPERTY(double Volume READ volume WRITE setVolume)
  Q_PROPERTY(qlonglong Position READ position)
  Q_PROPERTY(bool CanGoNext READ canGoNext)
  Q_PROPERTY(bool CanGoPrevious READ canGoPrevious)
  Q_PROPERTY(bool CanPlay READ active)
  Q_PROPERTY(bool CanPause READ active)
  Q_PROPERTY(bool CanSeek READ canSeek)
  Q_PROPERTY(bool CanControl READ canControl)

public:
  explicit Mpris(Playback *playback);
  ~Mpris() override;

  QString playbackStatus() const;
  QVariantMap metadata() const;
  double rate() const;
  void setRate(double rate);
  double minimumRate() const { return 0.01; }
  double maximumRate() const { return 100; }
  double volume() const;
  void setVolume(double volume);
  qlonglong position() const;
  bool active() const;
  bool canGoNext() const;
  bool canGoPrevious() const;
  bool canSeek() const;
  bool canControl() const { return true; }

public slots:
  void Next();
  void Previous();
  void Pause();
  void PlayPause();
  void Stop();
  void Play();
  void Seek(qlonglong offset);
  void SetPosition(const QDBusObjectPath &trackId, qlonglong position);
  void OpenUri(const QString &) {}

signals:
  void Seeked(qlonglong position);

private:
  void schedule();
  void refresh();
  bool registerService();
  void unregisterService(bool updatePlayback = true);
  QDBusObjectPath trackId() const;

  Playback *m_playback;
  QObject *m_object;
  QString m_service;
  QVariantMap m_published;
  quint64 m_track = 0;
  int m_trailer = -1;
  bool m_queued = false;
};
