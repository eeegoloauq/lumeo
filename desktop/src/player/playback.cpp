#include "playback.h"

#include "core.h"
#include "downloads.h"
#include "mpvfacts.h"
#include "mpvitem.h"
#include "preferences.h"
#include "settings.h"
#include "tracks.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QStandardPaths>

Playback::Playback(QObject *parent) : QObject(parent) {
  m_poll.setSingleShot(true);
  connect(&m_poll, &QTimer::timeout, this, &Playback::refresh);
  // While it plays, so a crash or a pulled plug loses seconds, not the film.
  m_progress.setInterval(5000);
  connect(&m_progress, &QTimer::timeout, this, [this] {
    if (m_mpv && !m_mpv->paused())
      report();
  });
  m_finishLimit.setSingleShot(true);
  m_finishLimit.setInterval(3000);
  connect(&m_finishLimit, &QTimer::timeout, this, &Playback::finished, Qt::QueuedConnection);
}

void Playback::componentComplete() {
  QQmlEngine *engine = qmlEngine(this);
  m_core = engine->singletonInstance<Core *>("Lumeo", "Core");
  m_preferences = engine->singletonInstance<Preferences *>("Lumeo", "Preferences");
  m_settings = engine->singletonInstance<LocalSettings *>("Lumeo", "LocalSettings");
  connect(m_preferences, &Preferences::changed, this, &Playback::defineBindings);
  if (m_mpv) {
    m_mpv->set("volume", m_settings->volume());
    defineBindings();
    m_tracks = new Tracks(m_mpv, m_core, m_preferences, this);
    connect(m_tracks, &Tracks::subtitleFailed, this, [this] { emit notice("subtitle", {}); });
    m_next = new Next(m_mpv, m_core, m_preferences,
                      engine->singletonInstance<Downloads *>("Lumeo", "Downloads"), this);
    connect(m_next, &Next::watched, this, [this] { report(true); });
    emit tracksChanged();
    applyScreenshots();
  }
  refresh();
}

void Playback::setMpv(MpvItem *mpv) {
  if (mpv == m_mpv)
    return;
  m_mpv = mpv;
  connect(mpv, &MpvItem::loadFailed, this, &Playback::onLoadFailed);
  connect(mpv, &MpvItem::logged, this, &Playback::onLogged);
  connect(mpv, &MpvItem::hasPictureChanged, this, &Playback::onPicture);
  connect(mpv, &MpvItem::durationChanged, this, &Playback::resume);
  connect(mpv, &MpvItem::pausedChanged, this, [this] {
    if (!m_mpv->paused())
      m_progress.start();
    else if (m_opened)
      report();
  });
  // Changed by a key as much as by the bar: what is kept is what mpv ended at.
  connect(mpv, &MpvItem::volumeChanged, this, [this] {
    if (m_settings)
      m_settings->setVolume(m_mpv->volume());
  });
  // A binding to `quit` ends mpv; the film goes with it rather than leaving
  // a dead picture.
  connect(mpv, &MpvItem::shutdown, this, &Playback::close);
  // For Settings › About, which has no film to ask.
  connect(mpv, &MpvItem::hwdecChanged, this, [this] {
    if (!m_mpv->hwdec().isEmpty())
      MpvFacts::instance()->setHardware(m_mpv->hwdec());
  });
  emit mpvChanged();
}

QString Playback::title() const {
  static const QRegularExpression episode(" · S\\d+E\\d+$");
  return QString(m_named.isEmpty() ? m_name : m_named).remove(episode);
}

QString Playback::stage() const {
  const QVariantMap progress = m_download.value("progress").toMap();
  if (progress.value("peers").toInt() == 0)
    return "findingPeers";
  return m_download.value("resolved").toBool() ? "arriving" : "fetchingMetadata";
}

bool Playback::findingNoPeers() const {
  const QDateTime since = QDateTime::fromString(m_download.value("waitingSince").toString(), Qt::ISODate);
  return m_download.value("state") == "active" && stage() == "findingPeers" &&
         !m_download.value("offline").toBool() && since.isValid() &&
         since.msecsTo(QDateTime::currentDateTime()) >= noPeersPatience;
}

int Playback::playingCopy(const QVariantList &sources) const {
  const QString name = m_download.value("name").toString();
  for (int i = 0; i < sources.size(); ++i) {
    const QVariantMap source = sources[i].toMap();
    if (source.value("rawName") == name || source.value("filename") == name)
      return i;
  }
  return -1;
}

int Playback::nextCopy(const QVariantList &sources) const {
  const int next = playingCopy(sources) + 1;
  return next < sources.size() ? next : -1;
}

QString Playback::decoderCodec(const QString &line) {
  static const QRegularExpression codec("decoder for codec '([^']+)'");
  return codec.match(line).captured(1);
}

// Each answer schedules the next ask, so polls never overlap.
void Playback::refresh() {
  m_poll.stop();
  const QString path = "/api/v1/downloads/" + Core::segment(m_downloadId);
  m_core->get(path, {}, this, [this](const Core::Reply &reply) {
    m_poll.start(pollInterval);
    if (!reply.ok()) {
      // Shown only while nothing plays: a film on screen goes on regardless.
      if (m_failure == None)
        m_failure = CoreStopped;
      emit changed();
      return;
    }
    if (m_failure == CoreStopped)
      m_failure = None;
    m_download = reply.json().toObject().toVariantMap();
    const QString itemId = m_download.value("itemId").toString();
    if (m_openedUnnamed < 0)
      m_openedUnnamed = itemId.isEmpty();
    if (!m_itemAsked && !itemId.isEmpty() &&
        (m_download.value("episode").toInt() > 0 || m_openedUnnamed == 1)) {
      m_itemAsked = true;
      loadItem();
    }
    emit changed();
    resume();
    if (m_next)
      m_next->update(m_download);
    if (!m_opened && !m_opening && m_failure == None && m_download.value("ready").toBool() &&
        dueToOpen())
      open();
  });
}

// Only once the core says ready: before that mpv blocks on its first read and
// reports a copy that will not play (decisions/player.md).
void Playback::open() {
  if (!m_mpv || !m_tracks)
    return;
  m_opening = true;
  m_tracks->prepare(m_download.value("itemId").toString(), m_downloadId, [this] {
    m_opening = false;
    if (m_closing || !m_mpv)
      return;
    m_opened = true;
    m_reopenPending = false;
    m_lastError.clear();
    const QString path = "/api/v1/downloads/" + Core::segment(m_downloadId) + "/stream";
    m_mpv->open(m_core->url(path).toString(), m_core->headers());
    m_tracks->opened();
    m_next->opened();
    // A fresh one per open: a stream that failed failed for it too. Off in
    // the settings, the second mpv never starts.
    delete m_previews;
    m_previews = m_settings->timelinePreviews()
                     ? new Previews(m_core->url(path).toString(), m_core->headers(), this)
                     : nullptr;
    emit changed();
    resume();
  });
}

void Playback::loadItem() {
  const QString itemId = m_download.value("itemId").toString();
  const int season = m_download.value("season").toInt();
  const int episode = m_download.value("episode").toInt();
  m_core->get("/api/v1/items/" + Core::segment(itemId), {}, this,
              [this, season, episode](const Core::Reply &reply) {
                if (!reply.ok())
                  return;
                const QJsonObject item = reply.json().toObject();
                m_episodes = item["episodes"].toArray().toVariantList();
                m_runtime = item["runtime"].toString();
                for (const QJsonValue &e : item["episodes"].toArray())
                  if (e["season"].toInt() == season && e["number"].toInt() == episode)
                    m_episodeTitle = e["title"].toString();
                if (m_openedUnnamed == 1) {
                  m_named = item["title"].toString();
                  applyScreenshots();
                }
                emit changed();
              });
  if (episode > 0)
    loadProgress();
}

void Playback::loadProgress() {
  const QString itemId = m_download.value("itemId").toString();
  if (itemId.isEmpty())
    return;
  m_core->get("/api/v1/progress/" + Core::segment(itemId), {}, this,
              [this](const Core::Reply &reply) {
                if (!reply.ok())
                  return;
                m_watching = reply.json().toObject().toVariantMap();
                emit changed();
              });
}

// Where it was left, unless that was the first seconds or the credits.
void Playback::resume() {
  const QString itemId = m_download.value("itemId").toString();
  if (m_resumeAsked || !m_opened || !m_mpv || m_mpv->duration() <= 0 || itemId.isEmpty())
    return;
  m_resumeAsked = true;
  const int season = m_download.value("season").toInt();
  const int episode = m_download.value("episode").toInt();
  m_core->get("/api/v1/progress/" + Core::segment(itemId), {}, this,
              [this, season, episode](const Core::Reply &reply) {
                if (!reply.ok() || !m_mpv)
                  return;
                double delay = 0;
                for (const QJsonValue &entry : reply.json()["entries"].toArray()) {
                  if (entry["season"].toInt() != season || entry["episode"].toInt() != episode)
                    continue;
                  const double position = entry["position"].toDouble();
                  if (position > 10 && position < m_mpv->duration() * 0.95)
                    m_mpv->command({"seek", QString::number(position, 'f', 3), "absolute+exact"});
                  delay = entry["subtitleDelay"].toDouble();
                }
                // A delay is a fact about this copy: it comes back with the
                // episode, not with the next one.
                m_tracks->restoreDelay(delay);
              });
}

// Our section over mpv's; a section of the same name replaces the old one.
void Playback::defineBindings() {
  if (!m_mpv || !m_preferences)
    return;
  const int step = m_preferences->current().value("seekStep", 5).toInt();
  if (step == m_seekStep)
    return;
  m_seekStep = step;
  const QStringList bindings = MpvFacts::ownBindings(step);
  m_mpv->command({"define-section", "lumeo", bindings.join('\n'), "default"});
  m_mpv->command({"enable-section", "lumeo"});
  m_mpv->get("input-bindings", this, [this](const QVariant &value) {
    if (!m_mpv)
      return;
    m_mpv->bound.clear();
    for (const QVariant &binding : value.toList())
      m_mpv->bound.insert(binding.toMap().value("key").toString());
  });
}

// mpv's own folder is the process's working directory, often `/` for an app
// started from the menu, where a screenshot fails: the one chosen in the
// settings, else Pictures/Lumeo, and the film's name on each.
void Playback::applyScreenshots() {
  const QString pictures = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation);
  const QString chosen = m_settings->screenshotsDir();
  const QString folder = !chosen.isEmpty() ? chosen : pictures.isEmpty() ? QString() : pictures + "/Lumeo";
  if (!folder.isEmpty())
    m_mpv->set("screenshot-dir", folder);
  // `%` is mpv's; what a file name cannot hold becomes a dash.
#ifdef Q_OS_WIN
  static const QRegularExpression unsafe(R"([\\/:*?"<>|])");
#else
  static const QRegularExpression unsafe("/");
#endif
  QString name = title().replace('%', "%%").replace(unsafe, "-").trimmed();
  if (name.isEmpty())
    name = "Lumeo";
  // Frames grabbed while paused share a time; `%n` keeps them apart.
  m_mpv->set("screenshot-template", name + " %P %#01n");
}

bool Playback::dueToOpen() const {
  return !m_reopenAt.isValid() || QDateTime::currentDateTime() >= m_reopenAt;
}

// mpv gave up on the file. Before the first picture that may be a stream
// dropped while it was opened, so it is opened again until openPatience runs
// out; a missing picture decoder is already a verdict.
void Playback::onLoadFailed() {
  if (m_failure == WouldNotStart || m_reopenPending || !m_mpv)
    return;
  const QDateTime now = QDateTime::currentDateTime();
  if (!m_mpv->hasPicture() &&
      (!m_firstFailure.isValid() || m_firstFailure.msecsTo(now) < openPatience)) {
    ++m_attempts;
    if (!m_firstFailure.isValid())
      m_firstFailure = now;
    m_reopenPending = true;
    // Spaced, since each attempt opens a new reader on the core.
    m_reopenAt = now.addMSecs((m_attempts < 5 ? m_attempts : 5) * reopenStep);
    m_mpv->command({"stop"});
    m_opened = false;
    m_tracks->reopened();
    emit changed();
    return;
  }
  m_failure = WouldNotStart;
  m_codec = decoderCodec(m_lastError);
  emit changed();
  if (m_mpv->hasPicture())
    emit notice(m_codec.isEmpty() ? "failed" : "picture", m_codec);
}

// A decoder that failed for the soundtrack leaves the picture playing; one
// for the picture is the end of it.
void Playback::onLogged(const QString &line) {
  const QString codec = decoderCodec(line);
  if (codec.isEmpty()) {
    m_lastError = line;
    return;
  }
  m_mpv->get("track-list", this, [this, codec](const QVariant &tracks) {
    QString type;
    for (const QVariant &track : tracks.toList())
      if (track.toMap().value("codec").toString().compare(codec, Qt::CaseInsensitive) == 0)
        type = track.toMap().value("type").toString();
    if (type == "audio") {
      emit notice("sound", codec);
      return;
    }
    m_failure = WouldNotStart;
    m_codec = codec;
    emit changed();
    if (m_mpv && m_mpv->hasPicture())
      emit notice("picture", codec);
  });
}

// A picture is the answer to every attempt so far: a later failure starts a
// fresh count.
void Playback::onPicture() {
  if (!m_mpv->hasPicture())
    return;
  m_attempts = 0;
  m_firstFailure = {};
  m_reopenAt = {};
  m_reopenPending = false;
  checkDecoder();
}

// Once there is a picture: a codec this machine plays with a decoder known to
// lose sync is said once, before the player gets blamed for it.
void Playback::checkDecoder() {
  if (m_decoderChecked)
    return;
  m_decoderChecked = true;
  m_mpv->get("video-format", this, [this](const QVariant &format) {
    const QString codec = format.toString();
    if (!MpvFacts::instance()->unreliable(codec).isEmpty())
      emit notice("broken", codec);
  });
}

void Playback::readShortcuts() {
  if (m_shortcutsRead || !m_mpv)
    return;
  m_mpv->get("input-bindings", this, [this](const QVariant &bindings) {
    m_shortcuts = MpvFacts::shortcuts(bindings.toList());
    m_shortcutsRead = true;
    emit changed();
  });
}

void Playback::retry() {
  if (m_tracks)
    m_tracks->reopened();
  m_failure = None;
  m_codec.clear();
  m_opened = false;
  m_attempts = 0;
  m_firstFailure = {};
  m_reopenAt = {};
  m_reopenPending = false;
  emit changed();
  refresh();
}

// One report at a time; one asked for meanwhile goes after it, with the
// position as it is by then.
void Playback::report(bool watched) {
  if (m_reporting) {
    m_reportAgain = true;
    m_watchedAgain = m_watchedAgain || watched;
    return;
  }
  const QString itemId = m_download.value("itemId").toString();
  const double position = m_closing ? m_closedAt : m_mpv ? m_mpv->position() : 0;
  const double duration = m_closing ? m_closedLength : m_mpv ? m_mpv->duration() : 0;
  const double delay = m_tracks ? m_tracks->delay() : 0;
  if (itemId.isEmpty() || duration <= 0 ||
      (!watched && position == m_lastReported && delay == m_lastDelay)) {
    reported();
    return;
  }
  m_reporting = true;
  m_lastReported = position;
  m_lastDelay = delay;
  QJsonObject body{
      {"season", m_download.value("season").toInt()},
      {"episode", m_download.value("episode").toInt()},
      {"position", position},
      {"duration", duration},
  };
  if (m_tracks && m_tracks->delayKnown())
    body["subtitleDelay"] = delay;
  // An episode is watched once its named ending starts, which in an anime
  // can be before the core's 90%.
  if (watched || (m_mpv && Next::inCredits(m_mpv->chapters(), position)))
    body["watched"] = true;
  m_core->send("PUT", "/api/v1/progress/" + Core::segment(itemId), {}, body, this,
               [this](const Core::Reply &reply) {
                 if (!reply.ok())
                   qWarning("progress not saved: %s", qPrintable(reply.message()));
                 m_reporting = false;
                 if (m_reportAgain) {
                   m_reportAgain = false;
                   report(std::exchange(m_watchedAgain, false));
                   return;
                 }
                 reported();
               });
}

void Playback::reported() {
  if (m_closing && !m_reporting && m_finishLimit.isActive()) {
    m_finishLimit.stop();
    // Queued: what answers it may destroy this.
    QMetaObject::invokeMethod(this, &Playback::finished, Qt::QueuedConnection);
  }
}

void Playback::close() {
  if (m_closing)
    return;
  m_closing = true;
  m_poll.stop();
  m_progress.stop();
  if (m_mpv) {
    m_closedAt = m_mpv->position();
    m_closedLength = m_mpv->duration();
    m_mpv->command({"stop"});
  }
  m_finishLimit.start();
  emit changed();
  emit closed();
  report();
}
