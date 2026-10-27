#pragma once

#include <QHash>
#include <QJSValue>
#include <QMutex>
#include <QPointer>
#include <QQuickFramebufferObject>
#include <QSet>
#include <QVariant>
#include <cstdint>
#include <functional>
#include <memory>

struct mpv_handle;
struct mpv_event_property;

// What mpv's callbacks reach the item through. They arrive on mpv's threads
// and may outlive the item: the render context is freed on the render thread,
// after the item has gone, so the item is cleared here under the lock first.
struct MpvShared {
  mpv_handle *mpv = nullptr;
  QMutex lock;
  class MpvItem *item = nullptr;
  ~MpvShared();
};

// One mpv playing into the scene. It draws through the render API into a
// framebuffer object on Qt Quick's render thread, in desktop GL. Nothing on
// the GUI thread waits on mpv: commands, property writes and reads are
// asynchronous and every value shown is an observed property.
class MpvItem : public QQuickFramebufferObject {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
  Q_PROPERTY(double position READ position NOTIFY positionChanged)
  Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
  Q_PROPERTY(double volume READ volume NOTIFY volumeChanged)
  Q_PROPERTY(bool muted READ muted NOTIFY mutedChanged)
  Q_PROPERTY(double speed READ speed NOTIFY speedChanged)
  Q_PROPERTY(QString hwdec READ hwdec NOTIFY hwdecChanged)
  // Waiting for the cache to fill, not paused or seeking.
  Q_PROPERTY(bool buffering READ buffering NOTIFY bufferingChanged)
  // `keep-open` holds the last frame; a seek back clears it.
  Q_PROPERTY(bool ended READ ended NOTIFY endedChanged)
  // A frame has been put out: the file is playing, not still being opened.
  Q_PROPERTY(bool hasPicture READ hasPicture NOTIFY hasPictureChanged)
  // The picture's width over its height as shown, 0 before it has one.
  Q_PROPERTY(double aspect READ aspect NOTIFY aspectChanged)
  // [{time, title}], in mpv's order.
  Q_PROPERTY(QVariantList chapters READ chapters NOTIFY chaptersChanged)
  // -1 before the first chapter or in a file with none.
  Q_PROPERTY(int chapter READ chapter NOTIFY chapterChanged)
  // Where in mpv's playlist it plays, from 0, and how long the playlist is.
  Q_PROPERTY(int playlistPos READ playlistPos NOTIFY playlistChanged)
  Q_PROPERTY(int playlistCount READ playlistCount NOTIFY playlistChanged)
  // mpv's track list as it reports it: [{id, type, lang, title, ...}].
  Q_PROPERTY(QVariantList tracks READ tracks NOTIFY tracksChanged)
  // The track ids playing: an id, "no" or "auto".
  Q_PROPERTY(QString aid READ aid NOTIFY aidChanged)
  Q_PROPERTY(QString sid READ sid NOTIFY sidChanged)
  Q_PROPERTY(double subDelay READ subDelay NOTIFY subDelayChanged)
  Q_PROPERTY(bool subVisible READ subVisible NOTIFY subVisibleChanged)
  Q_PROPERTY(double subScale READ subScale NOTIFY subScaleChanged)
  // 100 is the bottom edge; less lifts the line.
  Q_PROPERTY(double subPos READ subPos NOTIFY subPosChanged)
  // The picture fitted to the view (0), filling it (1) or stretched (2).
  Q_PROPERTY(int fit READ fit NOTIFY fitChanged)
  // The Anime4K preset mpv runs: "" for none, "a", "b" or "c", and "other"
  // for shaders that are none of them.
  Q_PROPERTY(QString anime4k READ anime4k NOTIFY anime4kChanged)
  // Writes the player log, the one a report is about; set before it is
  // complete. A trailer in a title's banner leaves the film's log alone.
  Q_PROPERTY(bool keepsLog MEMBER m_keepsLog)

public:
  explicit MpvItem(QQuickItem *parent = nullptr);
  ~MpvItem() override;

  // An mpv profile applied over the defaults. The player tests draw on
  // llvmpipe, where mpv's default scalers cost more CPU than it has.
  static QString profile;

  Renderer *createRenderer() const override;
  void componentComplete() override;

  bool paused() const { return m_paused; }
  double position() const { return m_position; }
  double duration() const { return m_duration; }
  double volume() const { return m_volume; }
  bool muted() const { return m_muted; }
  double speed() const { return m_speed; }
  QString hwdec() const { return m_hwdec; }
  bool buffering() const { return m_buffering; }
  bool ended() const { return m_ended; }
  bool hasPicture() const { return m_hasPicture; }
  double aspect() const { return m_aspect; }
  QVariantList chapters() const { return m_chapters; }
  int chapter() const { return m_chapter; }
  int playlistPos() const { return m_playlistPos; }
  int playlistCount() const { return m_playlistCount; }
  QVariantList tracks() const { return m_tracks; }
  QString aid() const { return m_aid; }
  QString sid() const { return m_sid; }
  double subDelay() const { return m_subDelay; }
  bool subVisible() const { return m_subVisible; }
  double subScale() const { return m_subScale; }
  double subPos() const { return m_subPos; }
  int fit() const { return m_keepAspect ? (m_panscan > 0 ? 1 : 0) : 2; }
  QString anime4k() const { return m_anime4k; }

  // Opens a file or address; [headers] go with every HTTP request mpv makes.
  Q_INVOKABLE void open(const QString &url, const QStringList &headers = {});
  Q_INVOKABLE void command(const QStringList &args);
  Q_INVOKABLE void set(const QString &name, const QVariant &value);
  // Reads [name] without waiting on mpv; [answer] gets an invalid QVariant
  // when mpv has no such property, and is not called once [context] is gone.
  void get(const QString &name, QObject *context, std::function<void(const QVariant &)> answer);
  // The same for QML: [answer] is called with the value, or undefined.
  Q_INVOKABLE void get(const QString &name, const QJSValue &answer);

  // A key pressed or released, sent as mpv's keydown and keyup so that the
  // repeat is mpv's own; false when mpv has no name for it.
  Q_INVOKABLE bool press(int key, const QString &text, int modifiers, quint32 scanCode,
                         bool autoRepeat);
  Q_INVOKABLE bool release(int key, quint32 scanCode, bool autoRepeat);
  // Lets go of every key mpv holds, as the keyboard leaves: one released
  // elsewhere would repeat in mpv for ever.
  Q_INVOKABLE void releaseKeys();
  // A mouse button over the picture, as mpv's MBTN keys: mpv's bindings
  // decide, its double click included.
  Q_INVOKABLE void button(int button, bool down);
  // The pointer over the picture, in the render target's pixels.
  Q_INVOKABLE void pointer(qreal x, qreal y);
  Q_INVOKABLE void wheel(QPointF angleDelta, int modifiers);
  Q_INVOKABLE void setFit(int fit);
  // Anime4K 4.0.1's high-end presets: A for 1080p anime, B for 720p, C for
  // 480p; "" turns it off (decisions/player.md).
  Q_INVOKABLE void setAnime4k(const QString &preset);

  // mpv's name for a key, modifiers included; empty for none. A printable
  // key whose character is not ASCII and that nothing in [bound] names is
  // the US layout's key in the same place (decisions/player.md).
  static QString keyName(int key, const QString &text, Qt::KeyboardModifiers modifiers,
                         quint32 scanCode, const QSet<QString> &bound);

  // The keys mpv's bindings name, for keyName.
  QSet<QString> bound;

  std::shared_ptr<MpvShared> shared() const { return m_shared; }

signals:
  void pausedChanged();
  void positionChanged();
  void durationChanged();
  void volumeChanged();
  void mutedChanged();
  void speedChanged();
  void hwdecChanged();
  void bufferingChanged();
  void endedChanged();
  void hasPictureChanged();
  void aspectChanged();
  void chaptersChanged();
  void chapterChanged();
  void playlistChanged();
  void tracksChanged();
  void aidChanged();
  void sidChanged();
  void subDelayChanged();
  void subVisibleChanged();
  void subScaleChanged();
  void subPosChanged();
  void fitChanged();
  void anime4kChanged();
  // mpv gave up on the file it was opening or playing.
  void loadFailed(const QString &reason);
  // A line mpv logged as an error: it explains a failure, but on its own is
  // not one.
  void logged(const QString &line);
  // mpv quit, by a binding to `quit` or by itself: nothing will play.
  void shutdown();
  // A `script-message lumeo <action>` from one of our bindings.
  void action(const QString &name);

private slots:
  void drainEvents();

private:
  void onProperty(uint64_t id, const mpv_event_property *property);

  std::shared_ptr<MpvShared> m_shared;
  bool m_paused = false;
  double m_position = 0;
  double m_duration = 0;
  double m_volume = 100;
  bool m_muted = false;
  double m_speed = 1;
  QString m_hwdec;
  bool m_buffering = false;
  bool m_ended = false;
  bool m_hasPicture = false;
  double m_aspect = 0;
  QVariantList m_chapters;
  int m_chapter = -1;
  int m_playlistPos = -1;
  int m_playlistCount = 0;
  QVariantList m_tracks;
  QString m_aid;
  QString m_sid;
  double m_subDelay = 0;
  bool m_subVisible = true;
  double m_subScale = 1;
  double m_subPos = 100;
  double m_panscan = 0;
  bool m_keepAspect = true;
  QString m_anime4k;

  // The mpv name sent on each held key's press, by physical key: a release
  // has no text, and Shift let go first changes what Qt calls the key.
  QHash<qint64, QString> m_held;
  struct Pending {
    QPointer<QObject> context;
    std::function<void(const QVariant &)> answer;
  };
  QHash<uint64_t, Pending> m_gets;
  uint64_t m_nextGet = 1;
  // What each write in flight sets, to name it if mpv refuses.
  QHash<uint64_t, QString> m_sets;
  uint64_t m_nextSet = 1;
  bool m_keepsLog = true;
};
