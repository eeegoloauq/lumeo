#pragma once

#include <cstdint>
#include <QMutex>
#include <QQuickFramebufferObject>
#include <QVariant>
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
// the GUI thread waits on mpv: commands and property writes are asynchronous
// and every value shown is an observed property.
class MpvItem : public QQuickFramebufferObject {
  Q_OBJECT
  QML_ELEMENT
  Q_PROPERTY(bool paused READ paused NOTIFY pausedChanged)
  Q_PROPERTY(double position READ position NOTIFY positionChanged)
  Q_PROPERTY(double duration READ duration NOTIFY durationChanged)
  Q_PROPERTY(double volume READ volume NOTIFY volumeChanged)
  Q_PROPERTY(bool fullscreen READ fullscreen NOTIFY fullscreenChanged)
  Q_PROPERTY(QString hwdec READ hwdec NOTIFY hwdecChanged)
  Q_PROPERTY(bool anime4k READ anime4k NOTIFY anime4kChanged)

public:
  explicit MpvItem(QQuickItem *parent = nullptr);
  ~MpvItem() override;

  Renderer *createRenderer() const override;

  bool paused() const { return m_paused; }
  double position() const { return m_position; }
  double duration() const { return m_duration; }
  double volume() const { return m_volume; }
  bool fullscreen() const { return m_fullscreen; }
  QString hwdec() const { return m_hwdec; }
  bool anime4k() const { return m_anime4k; }

  // Opens a file or address; [headers] go with every HTTP request mpv makes.
  Q_INVOKABLE void open(const QString &url, const QStringList &headers = {});
  Q_INVOKABLE void command(const QStringList &args);
  Q_INVOKABLE void set(const QString &name, const QVariant &value);
  // A key as mpv names it, down or up: mpv's own auto-repeat runs in between.
  Q_INVOKABLE void key(const QString &name, bool down);
  Q_INVOKABLE void toggleAnime4k();

  std::shared_ptr<MpvShared> shared() const { return m_shared; }

signals:
  void pausedChanged();
  void positionChanged();
  void durationChanged();
  void volumeChanged();
  void fullscreenChanged();
  void hwdecChanged();
  void anime4kChanged();
  void endOfFile(const QString &reason);
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
  bool m_fullscreen = false;
  QString m_hwdec;
  bool m_anime4k = false;
};
