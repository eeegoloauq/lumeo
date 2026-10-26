#pragma once

#include <QImage>
#include <QMutex>
#include <QObject>
#include <functional>
#include <memory>

struct mpv_handle;
struct mpv_node;

// Single frames out of a video, from an mpv of its own: a keyframe seek, then
// `screenshot-raw` (the pixels handed here) or `screenshot-to-file`. One
// request at a time. Nothing is read ahead: every byte of a torrent that is
// read is a byte fetched (decisions/player.md, Preview frames).
class FrameGrabber : public QObject {
  Q_OBJECT

public:
  // [headers] go with every HTTP request mpv makes.
  FrameGrabber(const QString &url, const QStringList &headers, QObject *parent = nullptr);
  // The mpv goes on another thread: its teardown waits on a read in flight.
  ~FrameGrabber() override;

  bool isOpen() const { return m_open; }
  bool isDead() const { return m_dead; }

  // The frame at [seconds], as mpv's seek with [flags] lands; [done] gets a
  // null image when there is none.
  void frame(double seconds, const QString &flags, std::function<void(const QImage &)> done);
  // Writes that frame to [path], in the format its extension names.
  void save(double seconds, const QString &flags, const QString &path,
            std::function<void(bool)> done);

  // What mpv's callback reaches this through, on mpv's thread.
  struct Shared {
    mpv_handle *mpv = nullptr;
    QMutex lock;
    FrameGrabber *grabber = nullptr;
  };

signals:
  // The file is loaded; or it never will be.
  void opened();
  void failed();

private slots:
  void drain();

private:
  void request(double seconds, const QString &flags, const QString &path);
  void finish(const QImage &image, bool saved);
  void fail();
  int command(uint64_t reply, const QStringList &args);
  static QImage image(const mpv_node &result);

  std::shared_ptr<Shared> m_shared;
  bool m_open = false;
  bool m_dead = false;
  bool m_seeking = false;
  // The request in flight: the file its frame goes to, empty for a picture
  // here, and who waits for it.
  QString m_path;
  std::function<void(const QImage &)> m_frame;
  std::function<void(bool)> m_saved;
};
