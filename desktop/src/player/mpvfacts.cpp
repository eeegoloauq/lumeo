#include "mpvfacts.h"

#include <QFile>
#include <QJSEngine>
#include <QRegularExpression>
#include <QThreadPool>
#include <mpv/client.h>

namespace {

enum Question : uint64_t { Decoders = 1, Bindings, Version };

QVariant fromNode(const mpv_node &node) {
  switch (node.format) {
  case MPV_FORMAT_STRING:
    return QString::fromUtf8(node.u.string);
  case MPV_FORMAT_FLAG:
    return node.u.flag != 0;
  case MPV_FORMAT_INT64:
    return qlonglong(node.u.int64);
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

// The decoders with evidence of breaking, not everything that could.
const QHash<QString, QString> knownBroken = {{"h264", "libopenh264"}};

// What our release parser prints, in mpv's spelling (x265 is hevc).
const QHash<QString, QString> videoCodecs = {
    {"AVC", "h264"}, {"HEVC", "hevc"}, {"AV1", "av1"}, {"VP9", "vp9"},
    {"XviD", "mpeg4"}, {"DivX", "mpeg4"}, {"MPEG-2", "mpeg2video"},
};
// DTS-HD and DTS-X are dts with more in the stream: one decoder. PCM is
// absent: a dozen codec names, and nothing ships without it.
const QHash<QString, QString> audioCodecs = {
    {"AAC", "aac"},     {"AC3", "ac3"},       {"EAC3", "eac3"},       {"DTS", "dts"},
    {"DTS-HD", "dts"},  {"DTS-X", "dts"},     {"TrueHD", "truehd"},   {"FLAC", "flac"},
    {"Opus", "opus"},   {"MP3", "mp3"},
};

QString ownLabel(const QString &cmd) {
  if (cmd == "script-message lumeo escape")
    return qtTrId("playerShortcutLeaveFullscreen");
  if (cmd == "script-message lumeo back")
    return qtTrId("playerShortcutBack");
  if (cmd == "script-message lumeo tracks")
    return qtTrId("playerShortcutTracks");
  if (cmd == "script-message lumeo fullscreen")
    return qtTrId("playerShortcutFullscreen");
  return {};
}

// mpv's default input.conf commands, in the interface's language; others
// keep mpv's own comment.
QString commandLabel(const QString &cmd) {
  static const QHash<QString, const char *> labels = {
      {"cycle pause", "playerCommandPause"},
      {"no-osd seek 1 exact", "playerCommandExactForward"},
      {"no-osd seek -1 exact", "playerCommandExactBackward"},
      {"cycle mute", "playerCommandMute"},
      {"multiply speed 1/1.1", "playerCommandSlower"},
      {"multiply speed 1.1", "playerCommandFaster"},
      {"multiply speed 0.5", "playerCommandHalfSpeed"},
      {"multiply speed 2.0", "playerCommandDoubleSpeed"},
      {"set speed 1.0", "playerCommandNormalSpeed"},
      {"frame-step", "playerCommandFrameForward"},
      {"frame-back-step", "playerCommandFrameBackward"},
      {"cycle audio", "playerCommandAudio"},
      {"cycle sub", "playerCommandSubtitle"},
      {"cycle sub down", "playerCommandSubtitleBack"},
      {"cycle sub-visibility", "playerCommandSubtitleVisible"},
      {"add sub-delay -0.1", "playerCommandSubtitleEarlier"},
      {"add sub-delay +0.1", "playerCommandSubtitleLater"},
      {"screenshot", "playerCommandScreenshot"},
      {"screenshot video", "playerCommandScreenshotVideo"},
      {"screenshot window", "playerCommandScreenshotWindow"},
      {"add chapter 1", "playerCommandChapterNext"},
      {"add chapter -1", "playerCommandChapterPrevious"},
      {"ab-loop", "playerCommandAbLoop"},
      {"show-progress", "playerCommandProgress"},
  };
  const auto at = labels.constFind(cmd);
  return at == labels.constEnd() ? QString() : qtTrId(*at);
}

// Bindings with nothing to act on here: quitting, the playlist, mpv's own
// window and its scripts' panels.
bool actsHere(const QString &cmd) {
  for (const char *dead : {"ignore", "quit", "playlist-", "set fullscreen", "cycle fullscreen", "cycle ontop",
                           "set current-window-scale", "script-binding osc/",
                           "script-binding console/"})
    if (cmd.startsWith(QLatin1String(dead)))
      return false;
  return true;
}

QString sentence(const QString &comment) {
  return comment.isEmpty() ? comment : comment.left(1).toUpper() + comment.mid(1);
}

// What has no label of ours and no comment of mpv's: our own arrows, said
// the way mpv says its own, and a plain `add`.
QString plain(const QString &cmd) {
  static const QRegularExpression seek("^seek (-?)(\\d+)$");
  const QRegularExpressionMatch byTime = seek.match(cmd);
  if (byTime.hasMatch()) {
    const int seconds = byTime.captured(2).toInt();
    const bool forward = byTime.captured(1).isEmpty();
    if (seconds % 60 == 0)
      return qtTrId(forward ? "playerShortcutSeekMinutesForward" : "playerShortcutSeekMinutesBackward",
                    seconds / 60);
    return qtTrId(forward ? "playerShortcutSeekSecondsForward" : "playerShortcutSeekSecondsBackward",
                  seconds);
  }
  static const QRegularExpression add("^add ([a-z][a-z-]*) ([+-]?\\d+(?:\\.\\d+)?)$");
  const QRegularExpressionMatch byStep = add.match(cmd);
  if (!byStep.hasMatch())
    return cmd;
  QString step = byStep.captured(2);
  step = step.startsWith('-') ? QString::fromUtf8("−") + step.mid(1) : "+" + QString(step).remove('+');
  if (byStep.captured(1) == "volume")
    return qtTrId("playerShortcutVolume").arg(step);
  return sentence(QString(byStep.captured(1)).replace('-', ' ')) + " " + step;
}

} // namespace

MpvFacts::MpvFacts(QObject *parent) : QObject(parent) {
  QFile release("/etc/os-release");
  if (release.open(QIODevice::ReadOnly))
    m_osRelease = QString::fromUtf8(release.readAll());
  ask();
}

MpvFacts *MpvFacts::instance() {
  static MpvFacts *facts = new MpvFacts;
  return facts;
}

MpvFacts *MpvFacts::create(QQmlEngine *, QJSEngine *) {
  MpvFacts *facts = instance();
  QJSEngine::setObjectOwnership(facts, QJSEngine::CppOwnership);
  return facts;
}

// An mpv with no file and no window, its default bindings on the way the
// film's are, asked three things and then let go of on another thread.
void MpvFacts::ask() {
  mpv_handle *mpv = mpv_create();
  if (!mpv)
    return;
  mpv_set_option_string(mpv, "input-default-bindings", "yes");
  mpv_set_option_string(mpv, "vo", "null");
  mpv_set_option_string(mpv, "load-scripts", "no");
  if (mpv_initialize(mpv) < 0) {
    mpv_destroy(mpv);
    return;
  }
  struct Asking {
    mpv_handle *mpv;
    MpvFacts *facts;
    int left = 3;
  };
  auto *asking = new Asking{mpv, this};
  mpv_set_wakeup_callback(
      mpv,
      [](void *context) {
        auto *asking = static_cast<Asking *>(context);
        QMetaObject::invokeMethod(asking->facts, [asking] {
          if (!asking->mpv)
            return;
          for (;;) {
            mpv_event *event = mpv_wait_event(asking->mpv, 0);
            if (event->event_id == MPV_EVENT_NONE)
              return;
            if (event->event_id != MPV_EVENT_GET_PROPERTY_REPLY)
              continue;
            auto *property = static_cast<mpv_event_property *>(event->data);
            const QVariant value = event->error >= 0 && property->format == MPV_FORMAT_NODE
                                       ? fromNode(*static_cast<mpv_node *>(property->data))
                                       : QVariant();
            MpvFacts *facts = asking->facts;
            if (event->reply_userdata == Decoders && value.toList().size() > 0) {
              facts->m_drivers = drivers(value.toList());
              facts->m_answered = true;
            } else if (event->reply_userdata == Bindings) {
              facts->m_bindings = value.toList();
            } else if (event->reply_userdata == Version) {
              facts->m_version = value.toString().remove(QRegularExpression("^mpv\\s+"));
            }
            emit facts->changed();
            if (--asking->left > 0)
              continue;
            mpv_handle *done = std::exchange(asking->mpv, nullptr);
            mpv_set_wakeup_callback(done, nullptr, nullptr);
            QThreadPool::globalInstance()->start([done, asking] {
              mpv_terminate_destroy(done);
              delete asking;
            });
            return;
          }
        }, Qt::QueuedConnection);
      },
      asking);
  mpv_get_property_async(mpv, Decoders, "decoder-list", MPV_FORMAT_NODE);
  mpv_get_property_async(mpv, Bindings, "input-bindings", MPV_FORMAT_NODE);
  mpv_get_property_async(mpv, Version, "mpv-version", MPV_FORMAT_NODE);
}

void MpvFacts::setDecoders(const QVariantList &decoderList) {
  m_drivers = drivers(decoderList);
  m_answered = true;
  emit changed();
}

void MpvFacts::setHardware(const QString &hwdec) {
  const QString used = hwdec == "no" ? QString() : hwdec;
  if (used == m_hardware)
    return;
  m_hardware = used;
  emit changed();
}

QSet<QString> MpvFacts::distributions(const QString &osRelease) {
  QHash<QString, QString> fields;
  for (const QString &line : osRelease.split('\n')) {
    const QString trimmed = line.trimmed();
    const qsizetype equals = trimmed.indexOf('=');
    if (trimmed.startsWith('#') || equals <= 0)
      continue;
    QString value = trimmed.mid(equals + 1).trimmed();
    if (value.size() >= 2 && (value.front() == '"' || value.front() == '\'') && value.back() == value.front())
      value = value.mid(1, value.size() - 2);
    fields.insert(trimmed.left(equals), value);
  }
  const QStringList ids = (fields.value("ID") + " " + fields.value("ID_LIKE"))
                              .toLower()
                              .split(QRegularExpression("\\s+"), Qt::SkipEmptyParts);
  return QSet<QString>(ids.begin(), ids.end());
}

// The repositories ship the whole set as one package.
QString MpvFacts::installHint() const {
  const QSet<QString> ids = distributions(m_osRelease);
  if (ids.contains("fedora"))
    return qtTrId("settingsCodecFedoraHint");
  if (ids.contains("opensuse") || ids.contains("suse"))
    return qtTrId("settingsCodecSuseHint");
  return {};
}

// Two on Fedora: the package is in RPM Fusion, which Fedora does not enable.
// None for openSUSE: adding Packman differs between Leap and Tumbleweed.
QStringList MpvFacts::installCommands() const {
  if (!distributions(m_osRelease).contains("fedora"))
    return {};
  return {
      // The release number from rpm, so it never goes stale here.
      "sudo dnf install https://mirrors.rpmfusion.org/free/fedora/"
      "rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm",
      "sudo dnf install libavcodec-freeworld",
  };
}

QHash<QString, QSet<QString>> MpvFacts::drivers(const QVariantList &decoderList) {
  QHash<QString, QSet<QString>> drivers;
  for (const QVariant &entry : decoderList) {
    const QVariantMap decoder = entry.toMap();
    const QString codec = decoder.value("codec").toString().toLower();
    if (codec.isEmpty())
      continue;
    const QString driver = decoder.value("driver").toString().toLower();
    drivers[codec].insert(driver.isEmpty() ? codec : driver);
  }
  return drivers;
}

int MpvFacts::has(const QString &codec) const {
  if (!m_answered)
    return -1;
  return m_drivers.contains(codec.toLower()) ? 1 : 0;
}

QString MpvFacts::videoCodec(const QString &release) { return videoCodecs.value(release); }

QString MpvFacts::audioCodec(const QString &release) { return audioCodecs.value(release); }

QVariantMap MpvFacts::gapIn(const QVariantMap &release) const {
  const QString video = videoCodec(release.value("videoCodec").toString());
  if (!video.isEmpty() && has(video) == 0)
    return {{"codec", video}, {"sound", false}};
  const QString audio = audioCodec(release.value("audioCodec").toString());
  if (!audio.isEmpty() && has(audio) == 0)
    return {{"codec", audio}, {"sound", true}};
  return {};
}

QString MpvFacts::gapMark(const QVariantMap &release) const {
  const QVariantMap gap = gapIn(release);
  if (gap.isEmpty())
    return {};
  return qtTrId(gap.value("sound").toBool() ? "playerDecoderNoSoundMark" : "playerDecoderMissingMark")
      .arg(gap.value("codec").toString());
}

QString MpvFacts::gapSentence(const QVariantMap &release) const {
  const QVariantMap gap = gapIn(release);
  if (gap.isEmpty())
    return {};
  const QString fact = qtTrId(gap.value("sound").toBool() ? "playerDecoderNoSound" : "playerDecoderMissing")
                           .arg(gap.value("codec").toString());
  const QString hint = installHint();
  return hint.isEmpty() ? fact : fact + " " + hint;
}

// The hardware wrappers (h264_qsv, h264_cuvid) are listed everywhere and
// used only when named: what matters is whether the driver named after the
// codec is there.
QString MpvFacts::unreliable(const QString &codec) const {
  const QString name = codec.toLower();
  if (!m_drivers.contains(name) || m_drivers.value(name).contains(name))
    return {};
  const QString substitute = knownBroken.value(name);
  return !substitute.isEmpty() && m_drivers.value(name).contains(substitute) ? substitute : QString();
}

QString MpvFacts::keyLabel(const QString &key) {
  static const QHash<QString, QString> names = [] {
    QHash<QString, QString> names = {
        {"SPACE", "Space"},  {"ENTER", "Enter"}, {"TAB", "Tab"},      {"BS", "Backspace"},
        {"DEL", "Delete"},   {"INS", "Insert"},  {"HOME", "Home"},    {"END", "End"},
        {"PGUP", "PgUp"},    {"PGDWN", "PgDn"},  {"ESC", "Esc"},      {"LEFT", "←"},
        {"RIGHT", "→"},      {"UP", "↑"},        {"DOWN", "↓"},       {"SHARP", "#"},
        {"KP_DEC", "Numpad ."}, {"KP_ENTER", "Numpad Enter"},
    };
    for (int i = 1; i <= 12; ++i)
      names.insert(QString("F%1").arg(i), QString("F%1").arg(i));
    for (int i = 0; i <= 9; ++i)
      names.insert(QString("KP%1").arg(i), QString("Numpad %1").arg(i));
    return names;
  }();
  // Mouse buttons and the wheel are words, and so translated.
  static const QHash<QString, const char *> mouse = {
      {"MBTN_LEFT", "playerKeyClick"},          {"MBTN_LEFT_DBL", "playerKeyDoubleClick"},
      {"MBTN_RIGHT", "playerKeyRightClick"},    {"MBTN_MID", "playerKeyMiddleClick"},
      {"MBTN_BACK", "playerKeyBackButton"},     {"MBTN_FORWARD", "playerKeyForwardButton"},
      {"WHEEL_UP", "playerKeyWheelUp"},         {"WHEEL_DOWN", "playerKeyWheelDown"},
      {"WHEEL_LEFT", "playerKeyWheelLeft"},     {"WHEEL_RIGHT", "playerKeyWheelRight"},
  };
  QStringList parts;
  QString rest = key;
  // The modifiers off the front, so that `Ctrl++` keeps its plus key.
  for (bool stripped = true; stripped;) {
    stripped = false;
    for (const char *modifier : {"Shift", "Ctrl", "Alt", "Meta"}) {
      const QString prefix = QString(modifier) + "+";
      if (rest.startsWith(prefix) && rest.size() > prefix.size()) {
        parts << modifier;
        rest = rest.mid(prefix.size());
        stripped = true;
      }
    }
  }
  if (rest.size() == 1) {
    if (rest.toLower() != rest.toUpper() && rest == rest.toUpper())
      parts << "Shift";
    parts << rest.toUpper();
    return parts.join('+');
  }
  QString named = names.value(rest);
  if (named.isEmpty() && mouse.contains(rest))
    named = qtTrId(mouse.value(rest));
  if (named.isEmpty())
    return {};
  parts << named;
  return parts.join('+');
}

QVariantList MpvFacts::shortcuts(const QVariantList &bindings, const QStringList &only) {
  QHash<QString, QVariantMap> byKey;
  QStringList keyOrder;
  for (const QVariant &b : bindings) {
    const QVariantMap binding = b.toMap();
    const QString section = binding.value("section").toString();
    if (section != "default" && section != "lumeo")
      continue;
    const QString key = binding.value("key").toString();
    if (!byKey.contains(key))
      keyOrder << key;
    if (!byKey.contains(key) || byKey.value(key).value("section") != "lumeo")
      byKey.insert(key, binding);
  }
  auto normal = [](const QString &cmd) { return cmd.simplified(); };
  QStringList wanted;
  for (const QString &key : only)
    if (byKey.contains(key))
      wanted << normal(byKey.value(key).value("cmd").toString());
  QHash<QString, QStringList> keys;
  QHash<QString, QString> comments;
  QStringList order;
  for (const QString &key : keyOrder) {
    const QVariantMap binding = byKey.value(key);
    const QString cmd = normal(binding.value("cmd").toString());
    if (!actsHere(cmd) || (!only.isEmpty() && !wanted.contains(cmd)))
      continue;
    const QString label = keyLabel(key);
    if (label.isEmpty())
      continue;
    if (!keys.contains(cmd))
      order << cmd;
    if (!keys[cmd].contains(label))
      keys[cmd] << label;
    const QString comment = binding.value("comment").toString();
    if (!comment.isEmpty() && !comments.contains(cmd))
      comments.insert(cmd, comment);
  }
  if (!only.isEmpty()) {
    order.clear();
    for (const QString &cmd : wanted)
      if (keys.contains(cmd) && !order.contains(cmd))
        order << cmd;
  }
  QVariantList lines;
  for (const QString &cmd : order) {
    QString what = ownLabel(cmd);
    if (what.isEmpty())
      what = commandLabel(cmd);
    if (what.isEmpty())
      what = comments.contains(cmd) ? sentence(comments.value(cmd)) : plain(cmd);
    lines.append(QVariantMap{{"keys", keys.value(cmd)}, {"what", what}});
  }
  return lines;
}

QStringList MpvFacts::ownBindings(int seekStep) {
  return {
      "MBTN_LEFT cycle pause",
      "ESC script-message lumeo escape",
      "q script-message lumeo back",
      "c script-message lumeo tracks",
      // The window is fullscreen or not, not mpv: these ask the player.
      "f script-message lumeo fullscreen",
      "F11 script-message lumeo fullscreen",
      "MBTN_LEFT_DBL script-message lumeo fullscreen",
      QString("LEFT seek -%1").arg(seekStep),
      QString("RIGHT seek %1").arg(seekStep),
  };
}

QVariantList MpvFacts::shortcutLines(int seekStep, bool all) const {
  // By mpv's names: what each does, and every other key that does the
  // same, is read from the bindings; nothing about a key is written here.
  static const QStringList everyday = {
      "SPACE", "LEFT", "RIGHT", "Shift+LEFT", "Shift+RIGHT", "DOWN", "UP", "9", "0", "m",
      "f", "F11", "c", "v", "[", "]", "s", "q", "ESC",
  };
  return shortcuts(m_bindings + ownBindingList(seekStep), all ? QStringList() : everyday);
}

QVariantList MpvFacts::ownBindingList(int seekStep) {
  QVariantList list;
  for (const QString &line : ownBindings(seekStep)) {
    const qsizetype space = line.indexOf(' ');
    list.append(QVariantMap{{"key", line.left(space)}, {"cmd", line.mid(space + 1)}, {"section", "lumeo"}});
  }
  return list;
}
