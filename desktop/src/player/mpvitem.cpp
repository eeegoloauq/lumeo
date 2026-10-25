#include "mpvitem.h"

#include <QDir>
#include <QGuiApplication>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QQuickOpenGLUtils>
#include <QtGui/qguiapplication_platform.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <list>
#include <vector>

MpvShared::~MpvShared() {
  if (mpv)
    mpv_terminate_destroy(mpv);
}

namespace {

enum Observed : uint64_t { Paused = 1, Position, Duration, Volume, Fullscreen, Hwdec };

// Anime4K's high-end preset A, as the Flutter client lists it.
const QStringList anime4kA = {
    "Clamp_Highlights",   "Restore_CNN_VL",      "Upscale_CNN_x2_VL",
    "AutoDownscalePre_x2", "AutoDownscalePre_x4", "Upscale_CNN_x2_M",
};

// A QVariant as mpv's node, with the bytes it points at kept in [storage]
// until the call that takes it returns; mpv copies what it is given.
mpv_node toNode(const QVariant &value, std::list<QByteArray> &storage,
                std::list<std::vector<mpv_node>> &lists, std::list<mpv_node_list> &nodeLists) {
  mpv_node node{};
  switch (value.typeId()) {
  case QMetaType::Bool:
    node.format = MPV_FORMAT_FLAG;
    node.u.flag = value.toBool();
    break;
  case QMetaType::Int:
  case QMetaType::LongLong:
    node.format = MPV_FORMAT_INT64;
    node.u.int64 = value.toLongLong();
    break;
  case QMetaType::Double:
    node.format = MPV_FORMAT_DOUBLE;
    node.u.double_ = value.toDouble();
    break;
  case QMetaType::QStringList:
  case QMetaType::QVariantList: {
    auto &items = lists.emplace_back();
    for (const QVariant &item : value.toList())
      items.push_back(toNode(item, storage, lists, nodeLists));
    auto &list = nodeLists.emplace_back();
    list.num = static_cast<int>(items.size());
    list.values = items.data();
    list.keys = nullptr;
    node.format = MPV_FORMAT_NODE_ARRAY;
    node.u.list = &list;
    break;
  }
  default:
    node.format = MPV_FORMAT_STRING;
    node.u.string = storage.emplace_back(value.toString().toUtf8()).data();
  }
  return node;
}

void wakeup(void *context) {
  auto *shared = static_cast<MpvShared *>(context);
  QMutexLocker locker(&shared->lock);
  if (shared->item)
    QMetaObject::invokeMethod(shared->item, "drainEvents", Qt::QueuedConnection);
}

class MpvRenderer : public QQuickFramebufferObject::Renderer {
public:
  explicit MpvRenderer(std::shared_ptr<MpvShared> shared) : m_shared(std::move(shared)) {}

  // Freed before the handle: the shared state outlives this only by the
  // reference held here.
  ~MpvRenderer() override {
    if (m_context)
      mpv_render_context_free(m_context);
  }

  QOpenGLFramebufferObject *createFramebufferObject(const QSize &size) override {
    if (!m_context)
      create();
    return new QOpenGLFramebufferObject(size);
  }

  void render() override {
    if (!m_context)
      return;
    QOpenGLFramebufferObject *fbo = framebufferObject();
    mpv_opengl_fbo target{static_cast<int>(fbo->handle()), fbo->width(), fbo->height(), 0};
    int flip = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &target},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    mpv_render_context_render(m_context, params);
    // mpv leaves its own GL state behind, which the scene graph does not expect.
    QQuickOpenGLUtils::resetOpenGLState();
  }

private:
  static void *procAddress(void *, const char *name) {
    QOpenGLContext *gl = QOpenGLContext::currentContext();
    return gl ? reinterpret_cast<void *>(gl->getProcAddress(name)) : nullptr;
  }

  static void onUpdate(void *context) {
    auto *shared = static_cast<MpvShared *>(context);
    QMutexLocker locker(&shared->lock);
    if (shared->item)
      QMetaObject::invokeMethod(shared->item, "update", Qt::QueuedConnection);
  }

  void create() {
    mpv_opengl_init_params gl{procAddress, nullptr};
    std::vector<mpv_render_param> params = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl},
    };
    // The display lets hardware decoders hand frames to GL without a copy
    // (VA-API's interop needs it; NVDEC's goes through CUDA and does not).
#if QT_CONFIG(wayland)
    if (auto *wayland = qGuiApp->nativeInterface<QNativeInterface::QWaylandApplication>())
      params.push_back({MPV_RENDER_PARAM_WL_DISPLAY, wayland->display()});
#endif
#if QT_CONFIG(xcb)
    if (auto *x11 = qGuiApp->nativeInterface<QNativeInterface::QX11Application>())
      params.push_back({MPV_RENDER_PARAM_X11_DISPLAY, x11->display()});
#endif
    params.push_back({MPV_RENDER_PARAM_INVALID, nullptr});
    if (mpv_render_context_create(&m_context, m_shared->mpv, params.data()) < 0) {
      qWarning("mpv: no render context");
      m_context = nullptr;
      return;
    }
    mpv_render_context_set_update_callback(m_context, onUpdate, m_shared.get());
  }

  std::shared_ptr<MpvShared> m_shared;
  mpv_render_context *m_context = nullptr;
};

} // namespace

MpvItem::MpvItem(QQuickItem *parent)
    : QQuickFramebufferObject(parent), m_shared(std::make_shared<MpvShared>()) {
  mpv_handle *mpv = mpv_create();
  if (!mpv)
    qFatal("mpv_create failed");
  m_shared->mpv = mpv;
  m_shared->item = this;

  // What docs/decisions/player.md sets on top of mpv's own defaults.
  const std::pair<const char *, const char *> options[] = {
      {"vo", "libmpv"},
      {"hwdec", "auto-safe"},
      {"hr-seek", "yes"},
      {"keep-open", "yes"},
      {"input-default-bindings", "yes"},
      {"stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=30"},
      {"cache-pause-initial", "yes"},
      {"volume-max", "150"},
      {"osd-bar", "no"},
      {"osd-on-seek", "msg"},
  };
  for (const auto &[name, value] : options)
    mpv_set_option_string(mpv, name, value);
  const QByteArray log = qgetenv("LUMEO_MPV_LOG");
  if (!log.isEmpty())
    mpv_set_option_string(mpv, "log-file", log.constData());
  if (mpv_initialize(mpv) < 0)
    qFatal("mpv_initialize failed");

  mpv_observe_property(mpv, Paused, "pause", MPV_FORMAT_FLAG);
  mpv_observe_property(mpv, Position, "time-pos", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, Duration, "duration", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, Volume, "volume", MPV_FORMAT_DOUBLE);
  mpv_observe_property(mpv, Fullscreen, "fullscreen", MPV_FORMAT_FLAG);
  mpv_observe_property(mpv, Hwdec, "hwdec-current", MPV_FORMAT_STRING);
  mpv_set_wakeup_callback(mpv, wakeup, m_shared.get());

  // The player's own keys are bindings in a section of ours rather than
  // keys taken before mpv sees them: the console's forced bindings win while
  // it is open, and a user's input.conf can rebind ours.
  command({"define-section", "lumeo",
           "ESC script-message lumeo escape\nq script-message lumeo back", "default"});
  command({"enable-section", "lumeo"});
}

MpvItem::~MpvItem() {
  QMutexLocker locker(&m_shared->lock);
  m_shared->item = nullptr;
}

QQuickFramebufferObject::Renderer *MpvItem::createRenderer() const {
  return new MpvRenderer(m_shared);
}

void MpvItem::open(const QString &url, const QStringList &headers) {
  set("http-header-fields", headers);
  command({"loadfile", url});
}

void MpvItem::command(const QStringList &args) {
  std::vector<QByteArray> bytes;
  std::vector<const char *> argv;
  for (const QString &arg : args)
    bytes.push_back(arg.toUtf8());
  for (const QByteArray &arg : bytes)
    argv.push_back(arg.constData());
  argv.push_back(nullptr);
  mpv_command_async(m_shared->mpv, 0, argv.data());
}

void MpvItem::set(const QString &name, const QVariant &value) {
  std::list<QByteArray> storage;
  std::list<std::vector<mpv_node>> lists;
  std::list<mpv_node_list> nodeLists;
  mpv_node node = toNode(value, storage, lists, nodeLists);
  mpv_set_property_async(m_shared->mpv, 0, name.toUtf8().constData(), MPV_FORMAT_NODE, &node);
}

void MpvItem::key(const QString &name, bool down) {
  command({down ? "keydown" : "keyup", name});
}

void MpvItem::toggleAnime4k() {
  m_anime4k = !m_anime4k;
  QStringList paths;
  if (m_anime4k)
    for (const QString &name : anime4kA)
      paths << QDir(LUMEO_ANIME4K_DIR).filePath("Anime4K_" + name + ".glsl");
  set("glsl-shaders", paths);
  emit anime4kChanged();
}

void MpvItem::drainEvents() {
  for (;;) {
    mpv_event *event = mpv_wait_event(m_shared->mpv, 0);
    switch (event->event_id) {
    case MPV_EVENT_NONE:
      return;
    case MPV_EVENT_PROPERTY_CHANGE:
      onProperty(event->reply_userdata, static_cast<mpv_event_property *>(event->data));
      break;
    case MPV_EVENT_CLIENT_MESSAGE: {
      auto *message = static_cast<mpv_event_client_message *>(event->data);
      if (message->num_args == 2 && qstrcmp(message->args[0], "lumeo") == 0)
        emit action(QString::fromUtf8(message->args[1]));
      break;
    }
    case MPV_EVENT_END_FILE: {
      auto *end = static_cast<mpv_event_end_file *>(event->data);
      if (end->reason == MPV_END_FILE_REASON_ERROR)
        emit endOfFile(QString::fromUtf8(mpv_error_string(end->error)));
      break;
    }
    default:
      break;
    }
  }
}

void MpvItem::onProperty(uint64_t id, const mpv_event_property *property) {
  const void *data = property->format == MPV_FORMAT_NONE ? nullptr : property->data;
  const bool flag = data && *static_cast<const int *>(data);
  const double number = data ? *static_cast<const double *>(data) : 0.0;
  switch (id) {
  case Paused:
    m_paused = flag;
    emit pausedChanged();
    break;
  case Position:
    m_position = number;
    emit positionChanged();
    break;
  case Duration:
    m_duration = number;
    emit durationChanged();
    break;
  case Volume:
    m_volume = number;
    emit volumeChanged();
    break;
  case Fullscreen:
    m_fullscreen = flag;
    emit fullscreenChanged();
    break;
  case Hwdec:
    m_hwdec = data ? QString::fromUtf8(*static_cast<char *const *>(data)) : QString();
    emit hwdecChanged();
    break;
  }
}
