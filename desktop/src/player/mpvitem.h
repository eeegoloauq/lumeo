#pragma once

#include <QHash>
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
  Q_PROPERTY(bool fullscreen READ fullscreen NOTIFY fullscreenChanged)
  Q_PROPERTY(QString hwdec READ hwdec NOTIFY hwdecChanged)
  // Waiting for the cache to fill, not paused or seeking.
  Q_PROPERTY(bool buffering READ buffering NOTIFY bufferingChanged)
  // `keep-open` holds the last frame; a seek back clears it.
  Q_PROPERTY(bool ended READ ended NOTIFY endedChanged)
  // A frame has been put out: the file is playing, not still being opened.
  Q_PROPERTY(bool hasPicture READ hasPicture NOTIFY hasPictureChanged)
  // [{time, title}], in mpv's order.
  Q_PROPERTY(QVariantList chapters READ chapters NOTIFY chaptersChanged)
  // -1 before the first chapter or in a file with none.
  Q_PROPERTY(int chapter READ chapter NOTIFY chapterChanged)

public:
  explicit MpvItem(QQuickItem *parent = nullptr);
  ~MpvItem() override;

  // An mpv profile applied over the defaults. The player tests draw on
  // llvmpipe, where mpv's default scalers cost more CPU than it has.
  static QString profile;

  Renderer *createRenderer() const override;

  bool paused() const { return m_paused; }
  double position() const { return m_position; }
  double duration() const { return m_duration; }
  double volume() const { return m_volume; }
  bool muted() const { return m_muted; }
  double speed() const { return m_speed; }
  bool fullscreen() const { return m_fullscreen; }
  QString hwdec() const { return m_hwdec; }
  bool buffering() const { return m_buffering; }
  bool ended() const { return m_ended; }
  bool hasPicture() const { return m_hasPicture; }
  QVariantList chapters() const { return m_chapters; }
  int chapter() const { return m_chapter; }

  // Opens a file or address; [headers] go with every HTTP request mpv makes.
  Q_INVOKABLE void open(const QString &url, const QStringList &headers = {});
  Q_INVOKABLE void command(const QStringList &args);
  Q_INVOKABLE void set(const QString &name, const QVariant &value);
  // Reads [name] without waiting on mpv; [answer] gets an invalid QVariant
  // when mpv has no such property, and is not called once [context] is gone.
  void get(const QString &name, QObject *context, std::function<void(const QVariant &)> answer);

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
  void fullscreenChanged();
  void hwdecChanged();
  void bufferingChanged();
  void endedChanged();
  void hasPictureChanged();
  void chaptersChanged();
  void chapterChanged();
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
  bool m_fullscreen = false;
  QString m_hwdec;
  bool m_buffering = false;
  bool m_ended = false;
  bool m_hasPicture = false;
  QVariantList m_chapters;
  int m_chapter = -1;

  // The mpv name sent on each held key's press, by physical key: a release
  // has no text, and Shift let go first changes what Qt calls the key.
  QHash<qint64, QString> m_held;
  struct Pending {
    QPointer<QObject> context;
    std::function<void(const QVariant &)> answer;
  };
  QHash<uint64_t, Pending> m_gets;
  uint64_t m_nextGet = 1;
};
