#include "framegrabber.h"

#include <QThreadPool>
#include <mpv/client.h>
#include <vector>

namespace {

enum Reply : uint64_t { Load = 1, Seek, Grab };

void wakeup(void *context) {
  auto *shared = static_cast<FrameGrabber::Shared *>(context);
  QMutexLocker locker(&shared->lock);
  if (shared->grabber)
    QMetaObject::invokeMethod(shared->grabber, "drain", Qt::QueuedConnection);
}

} // namespace

FrameGrabber::FrameGrabber(const QString &url, const QStringList &headers, QObject *parent)
    : QObject(parent), m_shared(std::make_shared<Shared>()) {
  mpv_handle *mpv = mpv_create();
  if (!mpv) {
    m_dead = true;
    return;
  }
  const std::pair<const char *, const char *> options[] = {
      {"vo", "null"},
      {"aid", "no"},
      {"sid", "no"},
      {"pause", "yes"},
      {"keep-open", "always"},
      {"hwdec", "auto-copy"},
      // Keyframes only, and nothing read ahead.
      {"hr-seek", "no"},
      {"cache", "no"},
      {"demuxer-readahead-secs", "0"},
      {"demuxer-max-bytes", "128KiB"},
      // mpv scales, so a 4K frame never crosses into the app or onto disk.
      {"vf", "scale=480:-2"},
      {"load-scripts", "no"},
      {"ytdl", "no"},
  };
  for (const auto &[name, value] : options)
    mpv_set_option_string(mpv, name, value);
  // A string list, which mpv splits at commas; a header has none.
  if (!headers.isEmpty())
    mpv_set_option_string(mpv, "http-header-fields", headers.join(',').toUtf8().constData());
  if (mpv_initialize(mpv) < 0) {
    mpv_destroy(mpv);
    m_dead = true;
    return;
  }
  m_shared->mpv = mpv;
  m_shared->grabber = this;
  mpv_set_wakeup_callback(mpv, wakeup, m_shared.get());
  if (command(Load, {"loadfile", url}) < 0)
    fail();
}

FrameGrabber::~FrameGrabber() {
  {
    QMutexLocker locker(&m_shared->lock);
    m_shared->grabber = nullptr;
  }
  if (!m_shared->mpv)
    return;
  // The shared state goes with the handle, so a wakeup still on its way
  // finds it. The application waits for the pool as it ends, so the mpv is
  // gone before the process is.
  QThreadPool::globalInstance()->start([shared = m_shared] { mpv_terminate_destroy(shared->mpv); });
}

void FrameGrabber::frame(double seconds, const QString &flags,
                         std::function<void(const QImage &)> done) {
  m_frame = std::move(done);
  m_saved = nullptr;
  request(seconds, flags, {});
}

void FrameGrabber::save(double seconds, const QString &flags, const QString &path,
                        std::function<void(bool)> done) {
  m_saved = std::move(done);
  m_frame = nullptr;
  request(seconds, flags, path);
}

void FrameGrabber::request(double seconds, const QString &flags, const QString &path) {
  if (m_dead) {
    finish({}, false);
    return;
  }
  m_path = path;
  m_seeking = true;
  if (command(Seek, {"seek", QString::number(seconds, 'f', 3), flags}) < 0)
    finish({}, false);
}

void FrameGrabber::finish(const QImage &image, bool saved) {
  m_seeking = false;
  if (auto done = std::exchange(m_frame, nullptr))
    done(image);
  if (auto done = std::exchange(m_saved, nullptr))
    done(saved);
}

void FrameGrabber::fail() {
  if (m_dead)
    return;
  m_dead = true;
  finish({}, false);
  emit failed();
}

int FrameGrabber::command(uint64_t reply, const QStringList &args) {
  std::vector<QByteArray> bytes;
  std::vector<const char *> argv;
  for (const QString &arg : args)
    bytes.push_back(arg.toUtf8());
  for (const QByteArray &arg : bytes)
    argv.push_back(arg.constData());
  argv.push_back(nullptr);
  return mpv_command_async(m_shared->mpv, reply, argv.data());
}

void FrameGrabber::drain() {
  for (;;) {
    mpv_event *event = mpv_wait_event(m_shared->mpv, 0);
    switch (event->event_id) {
    case MPV_EVENT_NONE:
      return;
    case MPV_EVENT_PLAYBACK_RESTART:
      if (!m_open) {
        m_open = true;
        emit opened();
      } else if (m_seeking) {
        m_seeking = false;
        const QStringList grab = m_path.isEmpty()
                                     ? QStringList{"screenshot-raw", "video"}
                                     : QStringList{"screenshot-to-file", m_path, "video"};
        if (command(Grab, grab) < 0)
          finish({}, false);
      }
      break;
    case MPV_EVENT_COMMAND_REPLY:
      if (m_dead)
        break;
      if (event->reply_userdata == Load && event->error < 0) {
        fail();
      } else if (event->reply_userdata == Seek && event->error < 0) {
        finish({}, false);
      } else if (event->reply_userdata == Grab) {
        if (event->error < 0)
          finish({}, false);
        else if (!m_path.isEmpty())
          finish({}, true);
        else
          // The node is mpv's until the next mpv_wait_event: copied now.
          finish(image(static_cast<mpv_event_command *>(event->data)->result), true);
      }
      break;
    // The stream failed: with keep-open, the end of the file is no end.
    case MPV_EVENT_END_FILE:
      fail();
      break;
    default:
      break;
    }
  }
}

// mpv's bgr0 is Qt's RGB32 on a little-endian machine, but for the fourth
// byte: mpv leaves it 0, RGB32 promises 0xff, and a texture made from it
// takes the 0 as alpha and draws nothing.
QImage FrameGrabber::image(const mpv_node &result) {
  if (result.format != MPV_FORMAT_NODE_MAP)
    return {};
  int width = 0, height = 0, stride = 0;
  const mpv_byte_array *data = nullptr;
  for (int i = 0; i < result.u.list->num; ++i) {
    const QByteArray key = result.u.list->keys[i];
    const mpv_node &value = result.u.list->values[i];
    if (key == "w")
      width = int(value.u.int64);
    else if (key == "h")
      height = int(value.u.int64);
    else if (key == "stride")
      stride = int(value.u.int64);
    else if (key == "data" && value.format == MPV_FORMAT_BYTE_ARRAY)
      data = value.u.ba;
  }
  if (!data || width <= 0 || height <= 0 || data->size < size_t(stride) * height)
    return {};
  QImage frame = QImage(static_cast<const uchar *>(data->data), width, height, stride,
                        QImage::Format_RGB32)
                     .copy();
  for (int y = 0; y < height; ++y) {
    auto *row = reinterpret_cast<QRgb *>(frame.scanLine(y));
    for (int x = 0; x < width; ++x)
      row[x] |= 0xff000000;
  }
  return frame;
}
