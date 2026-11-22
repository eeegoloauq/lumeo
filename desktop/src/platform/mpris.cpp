#include "mpris.h"

// D-Bus adaptors and property publication adapted from Legato.
#include "mpvitem.h"
#include "playback.h"

#include <QDBusConnection>
#include <QDBusMessage>
#include <QGuiApplication>
#include <algorithm>
#include <cmath>

namespace {
constexpr auto objectPath = "/org/mpris/MediaPlayer2";
constexpr auto playerInterface = "org.mpris.MediaPlayer2.Player";
constexpr auto serviceName = "org.mpris.MediaPlayer2.lumeo";
constexpr double microsPerSecond = 1000000;
quint64 trackSequence = 0;
} // namespace

MprisRoot::MprisRoot(QObject *parent) : QDBusAbstractAdaptor(parent) {}

QString MprisRoot::identity() const {
  return QGuiApplication::applicationDisplayName();
}

QString MprisRoot::desktopEntry() const {
  return QGuiApplication::desktopFileName();
}

Mpris::Mpris(Playback *playback)
    : QDBusAbstractAdaptor(new QObject(playback)), m_playback(playback), m_object(parent()) {
  new MprisRoot(m_object);
  auto *mpv = playback->mpv();
  connect(playback, &Playback::changed, this, &Mpris::schedule);
  connect(playback, &Playback::closed, this, [this] { unregisterService(); });
  connect(playback->next(), &::Next::changed, this, &Mpris::schedule);
  for (auto signal : {&MpvItem::pausedChanged, &MpvItem::durationChanged, &MpvItem::volumeChanged,
                      &MpvItem::speedChanged, &MpvItem::seekableChanged, &MpvItem::hasPictureChanged,
                      &MpvItem::endedChanged})
    connect(mpv, signal, this, &Mpris::schedule);
  connect(mpv, &MpvItem::seekFinished, this, [this](double seconds) {
    if (!m_service.isEmpty() && active())
      emit Seeked(qlonglong(seconds * microsPerSecond));
  });
}

Mpris::~Mpris() {
  unregisterService(false);
}

bool Mpris::active() const {
  return m_playback->mediaActive();
}

QString Mpris::playbackStatus() const {
  if (!active())
    return "Stopped";
  const auto *mpv = m_playback->mpv();
  return mpv->paused() || mpv->ended() ? "Paused" : "Playing";
}

QDBusObjectPath Mpris::trackId() const {
  return QDBusObjectPath(QString("/dev/lumeo/lumeo/track/%1").arg(m_track));
}

QVariantMap Mpris::metadata() const {
  if (!active())
    return {};
  const QString title = m_playback->title();
  const QString episode = m_playback->episodeTitle();
  QVariantMap values{{"mpris:trackid", QVariant::fromValue(trackId())},
                     {"xesam:title", episode.isEmpty() ? title : episode}};
  if (m_playback->download().value("episode").toInt() > 0)
    values.insert("xesam:album", title);
  const double duration = m_playback->mpv()->duration();
  if (duration > 0)
    values.insert("mpris:length", qlonglong(duration * microsPerSecond));
  if (const QString poster = m_playback->mediaArtwork(); !poster.isEmpty())
    values.insert("mpris:artUrl", poster);
  return values;
}

double Mpris::rate() const {
  return active() ? m_playback->mpv()->speed() : 1.0;
}

void Mpris::setRate(double rate) {
  if (rate == 0)
    Pause();
  else if (active() && rate >= minimumRate() && rate <= maximumRate())
    m_playback->mpv()->set("speed", rate);
}

double Mpris::volume() const {
  return active() ? m_playback->mpv()->volume() / 100 : 0;
}

void Mpris::setVolume(double volume) {
  if (active() && std::isfinite(volume))
    m_playback->mpv()->set("volume", std::clamp(volume, 0.0, 1.0) * 100);
}

qlonglong Mpris::position() const {
  return active() ? qlonglong(m_playback->mpv()->position() * microsPerSecond) : 0;
}

bool Mpris::canGoNext() const {
  return m_playback->mediaHasNext();
}

bool Mpris::canGoPrevious() const {
  return m_playback->mediaHasPrevious();
}

bool Mpris::canSeek() const {
  return m_playback->mediaCanSeek();
}

void Mpris::Next() {
  m_playback->mediaNext();
}

void Mpris::Previous() {
  m_playback->mediaPrevious();
}

void Mpris::Pause() {
  m_playback->mediaSetPaused(true);
}

void Mpris::PlayPause() {
  m_playback->mediaTogglePause();
}

void Mpris::Stop() {
  if (active())
    m_playback->close();
}

void Mpris::Play() {
  m_playback->mediaSetPaused(false);
}

void Mpris::Seek(qlonglong offset) {
  if (!canSeek())
    return;
  const double target = m_playback->mpv()->position() + offset / microsPerSecond;
  if (target > m_playback->mpv()->duration() && canGoNext())
    Next();
  else
    m_playback->mediaSeek(std::clamp(target, 0.0, m_playback->mpv()->duration()));
}

void Mpris::SetPosition(const QDBusObjectPath &track, qlonglong position) {
  if (track == trackId())
    m_playback->mediaSeek(position / microsPerSecond);
}

void Mpris::schedule() {
  if (m_queued)
    return;
  m_queued = true;
  QMetaObject::invokeMethod(this, &Mpris::refresh, Qt::QueuedConnection);
}

void Mpris::refresh() {
  m_queued = false;
  if (!active()) {
    unregisterService();
    return;
  }
  if (m_service.isEmpty() || m_trailer != m_playback->trailer()) {
    m_track = ++trackSequence;
    m_trailer = m_playback->trailer();
  }
  if (m_service.isEmpty() && !registerService())
    return;

  // Position is read on demand. Only discontinuities emit Seeked.
  const QVariantMap properties{{"PlaybackStatus", playbackStatus()}, {"Metadata", metadata()},
                               {"Rate", rate()}, {"Volume", volume()}, {"CanGoNext", canGoNext()},
                               {"CanGoPrevious", canGoPrevious()}, {"CanSeek", canSeek()}};
  QVariantMap changed;
  for (auto it = properties.cbegin(); it != properties.cend(); ++it)
    if (m_published.value(it.key()) != it.value())
      changed.insert(it.key(), it.value());
  m_published = properties;
  if (!changed.isEmpty()) {
    auto signal = QDBusMessage::createSignal(objectPath, "org.freedesktop.DBus.Properties",
                                             "PropertiesChanged");
    signal << QString(playerInterface) << changed << QStringList();
    QDBusConnection::sessionBus().send(signal);
  }
}

bool Mpris::registerService() {
  auto bus = QDBusConnection::sessionBus();
  if (!bus.isConnected() || !bus.registerObject(objectPath, m_object))
    return false;
  const QString instance = QString("%1.instance%2").arg(serviceName).arg(QCoreApplication::applicationPid());
  for (const auto &name : {QString(serviceName), instance}) {
    if (bus.registerService(name)) {
      m_service = name;
      m_playback->setSystemMediaKeys(true);
      return true;
    }
  }
  bus.unregisterObject(objectPath);
  return false;
}

void Mpris::unregisterService(bool updatePlayback) {
  if (m_service.isEmpty())
    return;
  auto bus = QDBusConnection::sessionBus();
  bus.unregisterObject(objectPath);
  bus.unregisterService(m_service);
  m_service.clear();
  m_published.clear();
  if (updatePlayback)
    m_playback->setSystemMediaKeys(false);
}
