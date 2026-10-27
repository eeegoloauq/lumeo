#include "mpvitem.h"

#include "folders.h"
#include "subtitlestyle.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QOpenGLContext>
#include <QOpenGLFramebufferObject>
#include <QQuickOpenGLUtils>
#include <QJSEngine>
#include <QQuickWindow>
#include <QtGui/qguiapplication_platform.h>
#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <list>
#include <vector>

MpvShared::~MpvShared() {
  if (mpv)
    mpv_terminate_destroy(mpv);
}

QString MpvItem::profile;

namespace {

enum Observed : uint64_t {
  Paused = 1,
  Position,
  Duration,
  Volume,
  Muted,
  Speed,
  Hwdec,
  Buffering,
  Ended,
  Picture,
  Chapters,
  Chapter,
  PlaylistPos,
  PlaylistCount,
  Tracks,
  Aid,
  Sid,
  SubDelay,
  SubVisible,
  SubScale,
  SubPos,
  Panscan,
  KeepAspect,
  Shaders,
};

// The shaders of Anime4K 4.0.1's high-end presets, in the order mpv runs them.
const QHash<QString, QStringList> anime4kPresets = {
    {"a", {"Clamp_Highlights", "Restore_CNN_VL", "Upscale_CNN_x2_VL", "AutoDownscalePre_x2",
           "AutoDownscalePre_x4", "Upscale_CNN_x2_M"}},
    {"b", {"Clamp_Highlights", "Restore_CNN_Soft_VL", "Upscale_CNN_x2_VL",
           "AutoDownscalePre_x2", "AutoDownscalePre_x4", "Upscale_CNN_x2_M"}},
    {"c", {"Clamp_Highlights", "Upscale_Denoise_CNN_x2_VL", "AutoDownscalePre_x2",
           "AutoDownscalePre_x4", "Upscale_CNN_x2_M"}},
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

QVariant fromNode(const mpv_node &node) {
  switch (node.format) {
  case MPV_FORMAT_STRING:
    return QString::fromUtf8(node.u.string);
  case MPV_FORMAT_FLAG:
    return node.u.flag != 0;
  case MPV_FORMAT_INT64:
    return static_cast<qlonglong>(node.u.int64);
  case MPV_FORMAT_DOUBLE:
    return node.u.double_;
  case MPV_FORMAT_NODE_ARRAY: {
    QVariantList list;
    for (int i = 0; i < node.u.list->num; ++i)
      list.append(fromNode(node.u.list->values[i]));
    return list;
  }
  case MPV_FORMAT_NODE_MAP: {
    QVariantMap map;
    for (int i = 0; i < node.u.list->num; ++i)
      map.insert(QString::fromUtf8(node.u.list->keys[i]), fromNode(node.u.list->values[i]));
    return map;
  }
  default:
    return {};
  }
}

// mpv's names for the keys that are not characters.
const QHash<int, QString> namedKeys = {
    {Qt::Key_Space, "SPACE"},
    {Qt::Key_Return, "ENTER"},
    {Qt::Key_Enter, "KP_ENTER"},
    {Qt::Key_Tab, "TAB"},
    {Qt::Key_Escape, "ESC"},
    {Qt::Key_Backspace, "BS"},
    {Qt::Key_Delete, "DEL"},
    {Qt::Key_Insert, "INS"},
    {Qt::Key_Home, "HOME"},
    {Qt::Key_End, "END"},
    {Qt::Key_PageUp, "PGUP"},
    {Qt::Key_PageDown, "PGDWN"},
    {Qt::Key_Left, "LEFT"},
    {Qt::Key_Right, "RIGHT"},
    {Qt::Key_Up, "UP"},
    {Qt::Key_Down, "DOWN"},
    {Qt::Key_F1, "F1"},
    {Qt::Key_F2, "F2"},
    {Qt::Key_F3, "F3"},
    {Qt::Key_F4, "F4"},
    {Qt::Key_F5, "F5"},
    {Qt::Key_F6, "F6"},
    {Qt::Key_F7, "F7"},
    {Qt::Key_F8, "F8"},
    {Qt::Key_F9, "F9"},
    {Qt::Key_F10, "F10"},
    {Qt::Key_F11, "F11"},
    {Qt::Key_F12, "F12"},
    {Qt::Key_MediaPlay, "PLAY"},
    {Qt::Key_MediaPause, "PAUSE"},
    {Qt::Key_MediaTogglePlayPause, "PLAYPAUSE"},
    {Qt::Key_MediaStop, "STOP"},
    {Qt::Key_MediaNext, "NEXT"},
    {Qt::Key_MediaPrevious, "PREV"},
    {Qt::Key_AudioForward, "FORWARD"},
    {Qt::Key_AudioRewind, "REWIND"},
    {Qt::Key_VolumeUp, "VOLUME_UP"},
    {Qt::Key_VolumeDown, "VOLUME_DOWN"},
    {Qt::Key_VolumeMute, "MUTE"},
};

// The keypad's digits, which Qt tells apart only by a modifier.
const QHash<int, QString> keypad = {
    {Qt::Key_0, "KP0"}, {Qt::Key_1, "KP1"}, {Qt::Key_2, "KP2"}, {Qt::Key_3, "KP3"},
    {Qt::Key_4, "KP4"}, {Qt::Key_5, "KP5"}, {Qt::Key_6, "KP6"}, {Qt::Key_7, "KP7"},
    {Qt::Key_8, "KP8"}, {Qt::Key_9, "KP9"}, {Qt::Key_Period, "KP_DEC"},
};

// The US layout's characters by PC scan code: a key's place on the board,
// whatever layout is on. Linux reports XKB's codes, which are these plus 8.
QChar usLayout(quint32 scanCode, bool shift) {
#ifndef Q_OS_WIN
  scanCode -= 8;
#endif
  struct Row {
    quint32 first;
    const char *plain;
    const char *shifted;
  };
  static const Row rows[] = {
      {0x02, "1234567890-=", "!@#$%^&*()_+"},
      {0x10, "qwertyuiop[]", "QWERTYUIOP{}"},
      {0x1e, "asdfghjkl;'`", "ASDFGHJKL:\"~"},
      {0x2b, "\\zxcvbnm,./", "|ZXCVBNM<>?"},
  };
  for (const Row &row : rows) {
    const quint32 at = scanCode - row.first;
    if (scanCode >= row.first && at < qstrlen(row.plain))
      return QLatin1Char((shift ? row.shifted : row.plain)[at]);
  }
  return {};
}

const std::pair<Qt::MouseButton, const char *> mouseButtons[] = {
    {Qt::LeftButton, "MBTN_LEFT"},   {Qt::RightButton, "MBTN_RIGHT"},
    {Qt::MiddleButton, "MBTN_MID"},  {Qt::BackButton, "MBTN_BACK"},
    {Qt::ForwardButton, "MBTN_FORWARD"},
};

QString modifierPrefix(Qt::KeyboardModifiers modifiers) {
  QString prefix;
  if (modifiers & Qt::ControlModifier)
    prefix += "Ctrl+";
  if (modifiers & Qt::AltModifier)
    prefix += "Alt+";
  if (modifiers & Qt::MetaModifier)
    prefix += "Meta+";
  return prefix;
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
      {"cache-pause-initial", "yes"},
      {"volume-max", "150"},
      // mpv's bar would be drawn into the picture under ours; a seek shows
      // its time, without the percentage the bar already shows.
      {"osd-bar", "no"},
      {"osd-on-seek", "msg"},
      {"osd-msg3", "${osd-sym-cc} ${time-pos}${?duration: / ${duration}}"},
  };
  for (const auto &[name, value] : options)
    mpv_set_option_string(mpv, name, value);
  // Plain text where a streaming release's styled dialogue sits
  // (decisions/subtitles.md).
  mpv_set_option_string(mpv, "sub-font-size", QByteArray::number(SubtitleStyle::fontSize).constData());
  mpv_set_option_string(mpv, "sub-margin-y", QByteArray::number(SubtitleStyle::margin).constData());
  if (mpv_initialize(mpv) < 0)
    qFatal("mpv_initialize failed");
  if (!profile.isEmpty())
    command({"apply-profile", profile});
  mpv_request_log_messages(mpv, "error");

  const std::pair<Observed, std::pair<const char *, mpv_format>> observed[] = {
      {Paused, {"pause", MPV_FORMAT_FLAG}},
      {Position, {"time-pos", MPV_FORMAT_DOUBLE}},
      {Duration, {"duration", MPV_FORMAT_DOUBLE}},
      {Volume, {"volume", MPV_FORMAT_DOUBLE}},
      {Muted, {"mute", MPV_FORMAT_FLAG}},
      {Speed, {"speed", MPV_FORMAT_DOUBLE}},
      {Hwdec, {"hwdec-current", MPV_FORMAT_STRING}},
      {Buffering, {"paused-for-cache", MPV_FORMAT_FLAG}},
      {Ended, {"eof-reached", MPV_FORMAT_FLAG}},
      {Picture, {"video-out-params", MPV_FORMAT_NODE}},
      {Chapters, {"chapter-list", MPV_FORMAT_NODE}},
      {Chapter, {"chapter", MPV_FORMAT_INT64}},
      {PlaylistPos, {"playlist-pos", MPV_FORMAT_INT64}},
      {PlaylistCount, {"playlist-count", MPV_FORMAT_INT64}},
      {Tracks, {"track-list", MPV_FORMAT_NODE}},
      {Aid, {"aid", MPV_FORMAT_STRING}},
      {Sid, {"sid", MPV_FORMAT_STRING}},
      {SubDelay, {"sub-delay", MPV_FORMAT_DOUBLE}},
      {SubVisible, {"sub-visibility", MPV_FORMAT_FLAG}},
      {SubScale, {"sub-scale", MPV_FORMAT_DOUBLE}},
      {SubPos, {"sub-pos", MPV_FORMAT_DOUBLE}},
      {Panscan, {"panscan", MPV_FORMAT_DOUBLE}},
      {KeepAspect, {"keepaspect", MPV_FORMAT_FLAG}},
      {Shaders, {"glsl-shaders", MPV_FORMAT_NODE}},
  };
  for (const auto &[id, property] : observed)
    mpv_observe_property(mpv, id, property.first, property.second);
  mpv_set_wakeup_callback(mpv, wakeup, m_shared.get());
}

MpvItem::~MpvItem() {
  QMutexLocker locker(&m_shared->lock);
  m_shared->item = nullptr;
}

QQuickFramebufferObject::Renderer *MpvItem::createRenderer() const {
  return new MpvRenderer(m_shared);
}

// The previous log is kept beside it: mpv empties its log on open, and a
// report is usually about the film just closed. Two files bound the size.
void MpvItem::componentComplete() {
  QQuickFramebufferObject::componentComplete();
  if (!m_keepsLog)
    return;
  const QString log = Folders::playerLog();
  QDir().mkpath(QFileInfo(log).path());
  const QString previous = QFileInfo(log).path() + "/" + QFileInfo(log).completeBaseName() + ".old.log";
  QFile::remove(previous);
  QFile::rename(log, previous);
  set("log-file", log);
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
  const uint64_t id = m_nextSet++;
  m_sets.insert(id, name);
  mpv_set_property_async(m_shared->mpv, id, name.toUtf8().constData(), MPV_FORMAT_NODE, &node);
}

void MpvItem::get(const QString &name, QObject *context,
                  std::function<void(const QVariant &)> answer) {
  const uint64_t id = m_nextGet++;
  m_gets.insert(id, {context, std::move(answer)});
  mpv_get_property_async(m_shared->mpv, id, name.toUtf8().constData(), MPV_FORMAT_NODE);
}

void MpvItem::get(const QString &name, const QJSValue &answer) {
  get(name, this, [this, answer](const QVariant &value) {
    QJSValue call = answer;
    QJSEngine *engine = qjsEngine(this);
    call.call({value.isValid() && engine ? engine->toScriptValue(value) : QJSValue()});
  });
}

void MpvItem::setFit(int fit) {
  set("panscan", fit == 1 ? 1.0 : 0.0);
  set("keepaspect", fit != 2);
}

void MpvItem::setAnime4k(const QString &preset) {
  QStringList paths;
  const QString dir = QCoreApplication::applicationDirPath() + "/../share/lumeo/anime4k";
  for (const QString &shader : anime4kPresets.value(preset))
    paths << QString("%1/Anime4K_%2.glsl").arg(dir, shader);
  set("glsl-shaders", paths);
}

QString MpvItem::keyName(int key, const QString &text, Qt::KeyboardModifiers modifiers,
                         quint32 scanCode, const QSet<QString> &bound) {
  QString prefix = modifierPrefix(modifiers);
  const bool shift = modifiers & Qt::ShiftModifier;
  QString name = namedKeys.value(key);
  if (name.isEmpty() && (modifiers & Qt::KeypadModifier))
    name = keypad.value(key);
  if (!name.isEmpty())
    return prefix + (shift ? "Shift+" : "") + name;
  QString character;
  // With Ctrl or Alt the text is a control character or none, and Qt's key
  // is the Latin one even on another layout.
  if (modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) {
    if (key > 0x20 && key < 0x7f)
      character = QChar(key);
    if (key >= Qt::Key_A && key <= Qt::Key_Z && !shift)
      character = character.toLower();
  } else if (text.size() == 1 && text[0] >= QChar(0x20) && text[0] != QChar(0x7f)) {
    character = text;
    if (text[0].unicode() >= 0x80 && !bound.contains(text)) {
      const QChar us = usLayout(scanCode, shift);
      if (!us.isNull())
        character = us;
    }
  }
  if (character.isEmpty())
    return {};
  if (character == "#")
    character = "SHARP";
  return prefix + character;
}

bool MpvItem::press(int key, const QString &text, int modifiers, quint32 scanCode,
                    bool autoRepeat) {
  // Qt's synthetic events, a test's among them, carry no scan code.
  const qint64 physical = scanCode ? scanCode : (qint64(1) << 32) + key;
  if (autoRepeat)
    return m_held.contains(physical);
  const QString name =
      keyName(key, text, Qt::KeyboardModifiers(modifiers), scanCode, bound);
  if (name.isEmpty())
    return false;
  m_held.insert(physical, name);
  command({"keydown", name});
  return true;
}

bool MpvItem::release(int key, quint32 scanCode, bool autoRepeat) {
  const qint64 physical = scanCode ? scanCode : (qint64(1) << 32) + key;
  if (autoRepeat)
    return m_held.contains(physical);
  const QString name = m_held.take(physical);
  if (name.isEmpty())
    return false;
  command({"keyup", name});
  return true;
}

void MpvItem::releaseKeys() {
  if (m_held.isEmpty())
    return;
  m_held.clear();
  // The empty name is "release all"; an omitted one reaches mpv 0.41's
  // cmd_key as NULL and crashes it.
  command({"keyup", ""});
}

void MpvItem::button(int button, bool down) {
  for (const auto &[which, name] : mouseButtons)
    if (which == button)
      command({down ? "keydown" : "keyup", name});
}

void MpvItem::pointer(qreal x, qreal y) {
  const qreal ratio = window() ? window()->effectiveDevicePixelRatio() : 1;
  command({"mouse", QString::number(qRound(x * ratio)), QString::number(qRound(y * ratio))});
}

void MpvItem::wheel(QPointF angleDelta, int modifiers) {
  QString key;
  if (qAbs(angleDelta.y()) >= qAbs(angleDelta.x())) {
    if (angleDelta.y() == 0)
      return;
    key = angleDelta.y() > 0 ? "WHEEL_UP" : "WHEEL_DOWN";
  } else {
    key = angleDelta.x() > 0 ? "WHEEL_LEFT" : "WHEEL_RIGHT";
  }
  const auto held = Qt::KeyboardModifiers(modifiers);
  command({"keypress",
           modifierPrefix(held) + (held & Qt::ShiftModifier ? "Shift+" : "") + key});
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
    case MPV_EVENT_GET_PROPERTY_REPLY: {
      const Pending pending = m_gets.take(event->reply_userdata);
      auto *property = static_cast<mpv_event_property *>(event->data);
      QVariant value;
      if (event->error >= 0 && property->format == MPV_FORMAT_NODE)
        value = fromNode(*static_cast<mpv_node *>(property->data));
      if (pending.context && pending.answer)
        pending.answer(value);
      break;
    }
    case MPV_EVENT_SET_PROPERTY_REPLY: {
      const QString name = m_sets.take(event->reply_userdata);
      // A property this mpv does not have, or a value it does not take: a
      // decision that silently did nothing.
      if (event->error < 0)
        qWarning("mpv refused %s: %s", qPrintable(name), mpv_error_string(event->error));
      break;
    }
    case MPV_EVENT_CLIENT_MESSAGE: {
      auto *message = static_cast<mpv_event_client_message *>(event->data);
      if (message->num_args == 2 && qstrcmp(message->args[0], "lumeo") == 0)
        emit action(QString::fromUtf8(message->args[1]));
      break;
    }
    case MPV_EVENT_LOG_MESSAGE: {
      auto *message = static_cast<mpv_event_log_message *>(event->data);
      emit logged(QString::fromUtf8(message->text).trimmed());
      break;
    }
    case MPV_EVENT_END_FILE: {
      auto *end = static_cast<mpv_event_end_file *>(event->data);
      if (end->reason == MPV_END_FILE_REASON_ERROR)
        emit loadFailed(QString::fromUtf8(mpv_error_string(end->error)));
      break;
    }
    case MPV_EVENT_SHUTDOWN:
      emit shutdown();
      return;
    default:
      break;
    }
  }
}

// Announced only when the value changes: mpv first reports what it starts
// with, which is no news to anyone following a property.
void MpvItem::onProperty(uint64_t id, const mpv_event_property *property) {
  const void *data = property->format == MPV_FORMAT_NONE ? nullptr : property->data;
  const bool flag = data && *static_cast<const int *>(data);
  const double number =
      data && property->format == MPV_FORMAT_DOUBLE ? *static_cast<const double *>(data) : 0.0;
  const QVariant node = data && property->format == MPV_FORMAT_NODE
                            ? fromNode(*static_cast<const mpv_node *>(data))
                            : QVariant();
  const QString text = data && property->format == MPV_FORMAT_STRING
                           ? QString::fromUtf8(*static_cast<char *const *>(data))
                           : QString();
  auto update = [this](auto &member, const auto &value, void (MpvItem::*changed)()) {
    if (member == value)
      return;
    member = value;
    emit(this->*changed)();
  };
  switch (id) {
  case Paused:
    update(m_paused, flag, &MpvItem::pausedChanged);
    break;
  case Position:
    update(m_position, number, &MpvItem::positionChanged);
    break;
  case Duration:
    update(m_duration, number, &MpvItem::durationChanged);
    break;
  case Volume:
    update(m_volume, number, &MpvItem::volumeChanged);
    break;
  case Muted:
    update(m_muted, flag, &MpvItem::mutedChanged);
    break;
  case Speed:
    update(m_speed, data ? number : 1.0, &MpvItem::speedChanged);
    break;
  case Hwdec:
    update(m_hwdec, text, &MpvItem::hwdecChanged);
    break;
  case Buffering:
    update(m_buffering, flag, &MpvItem::bufferingChanged);
    break;
  case Ended:
    update(m_ended, flag, &MpvItem::endedChanged);
    break;
  case Picture: {
    const QVariantMap params = node.toMap();
    update(m_hasPicture, params.value("w").toInt() > 0, &MpvItem::hasPictureChanged);
    const double width = params.value("dw").toDouble(), height = params.value("dh").toDouble();
    const bool turned = params.value("rotate").toInt() % 180 != 0;
    update(m_aspect, width > 0 && height > 0 ? (turned ? height / width : width / height) : 0.0,
           &MpvItem::aspectChanged);
    break;
  }
  case Chapters:
    update(m_chapters, node.toList(), &MpvItem::chaptersChanged);
    break;
  case Chapter:
    update(m_chapter, data ? static_cast<int>(*static_cast<const int64_t *>(data)) : -1,
           &MpvItem::chapterChanged);
    break;
  case PlaylistPos:
    update(m_playlistPos, data ? static_cast<int>(*static_cast<const int64_t *>(data)) : -1,
           &MpvItem::playlistChanged);
    break;
  case PlaylistCount:
    update(m_playlistCount, data ? static_cast<int>(*static_cast<const int64_t *>(data)) : 0,
           &MpvItem::playlistChanged);
    break;
  case Tracks:
    update(m_tracks, node.toList(), &MpvItem::tracksChanged);
    break;
  case Aid:
    update(m_aid, text, &MpvItem::aidChanged);
    break;
  case Sid:
    update(m_sid, text, &MpvItem::sidChanged);
    break;
  case SubDelay:
    update(m_subDelay, number, &MpvItem::subDelayChanged);
    break;
  case SubVisible:
    update(m_subVisible, flag, &MpvItem::subVisibleChanged);
    break;
  case SubScale:
    update(m_subScale, data ? number : 1.0, &MpvItem::subScaleChanged);
    break;
  case SubPos:
    update(m_subPos, data ? number : 100.0, &MpvItem::subPosChanged);
    break;
  case Panscan:
    update(m_panscan, number, &MpvItem::fitChanged);
    break;
  case KeepAspect:
    update(m_keepAspect, flag, &MpvItem::fitChanged);
    break;
  case Shaders: {
    // Read back from mpv, which a key or a user's input.conf may have
    // changed too: the preset whose files these are, by name.
    QStringList files;
    for (const QVariant &path : node.toList())
      files << path.toString().section('/', -1).section('\\', -1);
    QString preset = files.isEmpty() ? QString() : "other";
    for (auto it = anime4kPresets.begin(); it != anime4kPresets.end(); ++it) {
      QStringList names;
      for (const QString &shader : it.value())
        names << "Anime4K_" + shader + ".glsl";
      if (names == files)
        preset = it.key();
    }
    update(m_anime4k, preset, &MpvItem::anime4kChanged);
    break;
  }
  }
}
