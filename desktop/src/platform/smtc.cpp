#include "smtc.h"

#include "mpvitem.h"
#include "playback.h"

#include <QMutex>
#include <QQuickWindow>
#include <cmath>

struct Smtc::Dispatch {
  // WinRT can invoke delegates off-thread, including while they are removed.
  static void post(const std::shared_ptr<Dispatch> &dispatch, std::function<void(Smtc &)> action) {
    const QMutexLocker lock(&dispatch->mutex);
    if (auto *target = dispatch->target)
      QMetaObject::invokeMethod(target, [dispatch, target, action = std::move(action)] {
        if (target->m_dispatch == dispatch && target->m_playback->mediaActive())
          action(*target);
      }, Qt::QueuedConnection);
  }

  QMutex mutex;
  Smtc *target = nullptr;
};

Smtc::Smtc(Playback *playback) : QObject(playback), m_playback(playback) {
  auto *mpv = playback->mpv();
  connect(playback, &Playback::changed, this, &Smtc::schedule);
  connect(playback, &Playback::closed, this, &Smtc::closeSession);
  connect(playback->next(), &Next::changed, this, &Smtc::schedule);
  connect(mpv, &QQuickItem::windowChanged, this, [this] {
    closeSession();
    schedule();
  });
  connect(mpv, &MpvItem::hasPictureChanged, this, &Smtc::schedule);
  auto updateTimeline = [this] {
    m_timelineChanged = true;
    schedule();
  };
  for (const auto signal : {&MpvItem::pausedChanged, &MpvItem::endedChanged, &MpvItem::durationChanged,
                            &MpvItem::speedChanged, &MpvItem::seekableChanged})
    connect(mpv, signal, this, updateTimeline);
  connect(mpv, &MpvItem::seekFinished, this, updateTimeline);
  connect(mpv, &MpvItem::positionChanged, this, [this, mpv] {
    if (m_native && std::abs(mpv->position() - m_timelineSentAt) >= 1.0)
      schedule();
  });
}

Smtc::~Smtc() {
  if (m_dispatch) {
    const QMutexLocker lock(&m_dispatch->mutex);
    m_dispatch->target = nullptr;
  }
}

void Smtc::closeSession() {
  if (m_dispatch) {
    const QMutexLocker lock(&m_dispatch->mutex);
    m_dispatch->target = nullptr;
  }
  m_native.reset();
  m_dispatch.reset();
  m_attempted = false;
  m_playback->setSystemMediaKeys(false);
}

void Smtc::schedule() {
  if (m_queued)
    return;
  m_queued = true;
  QMetaObject::invokeMethod(this, &Smtc::refresh, Qt::QueuedConnection);
}

void Smtc::refresh() {
  m_queued = false;
  if (!m_playback->mediaActive()) {
    if (m_attempted)
      closeSession();
    return;
  }

  auto *mpv = m_playback->mpv();
  auto *window = mpv->window();
  if (!window || (m_attempted && !m_native))
    return;

  const bool opening = !m_native;
  if (opening) {
    m_attempted = true;
    m_dispatch = std::make_shared<Dispatch>();
    m_dispatch->target = this;
    m_native = std::make_unique<SmtcNative>(
        reinterpret_cast<void *>(window->winId()),
        [dispatch = m_dispatch](auto button) {
          Dispatch::post(dispatch, [button](Smtc &session) { session.buttonPressed(button); });
        },
        [dispatch = m_dispatch](double position) {
          Dispatch::post(dispatch, [position](Smtc &session) { session.m_playback->mediaSeek(position); });
        });
    if (!m_native->ready()) {
      qWarning("SMTC initialization failed (0x%08lx)", static_cast<unsigned long>(m_native->error()));
      closeSession();
      m_attempted = true;
      return;
    }
  }

  const QString title = m_playback->title();
  const QString episode = m_playback->episodeTitle();
  auto metadata = std::tuple{episode.isEmpty() ? title : episode, episode.isEmpty() ? QString() : title,
                             m_playback->mediaArtwork(), m_playback->trailer()};
  if (opening || metadata != m_metadata) {
    m_metadata = std::move(metadata);
    const auto &[name, series, art, trailer] = m_metadata;
    m_native->setMetadata(name.toStdWString(), series.toStdWString(), art.toStdWString());
  }
  const auto state = std::tuple{mpv->paused() || mpv->ended(), m_playback->mediaHasNext(),
                                m_playback->mediaHasPrevious()};
  if (opening || state != m_playbackState) {
    m_playbackState = state;
    const auto [paused, next, previous] = state;
    m_native->setPlayback(paused, next, previous);
  }
  if (opening || m_timelineChanged || std::abs(mpv->position() - m_timelineSentAt) >= 1.0) {
    m_timelineSentAt = mpv->position();
    m_timelineChanged = false;
    m_native->setTimeline(mpv->duration(), m_timelineSentAt, mpv->speed(), m_playback->mediaCanSeek());
  }
  if (opening) {
    if (!m_native->enable()) {
      qWarning("SMTC activation failed (0x%08lx)", static_cast<unsigned long>(m_native->error()));
      closeSession();
      m_attempted = true;
      return;
    }
    m_playback->setSystemMediaKeys(true);
  }
}

void Smtc::buttonPressed(SmtcNative::Button button) {
  switch (button) {
  case SmtcNative::Button::Play: m_playback->mediaSetPaused(false); break;
  case SmtcNative::Button::Pause: m_playback->mediaSetPaused(true); break;
  case SmtcNative::Button::Stop: m_playback->close(); break;
  case SmtcNative::Button::Next: m_playback->mediaNext(); break;
  case SmtcNative::Button::Previous: m_playback->mediaPrevious(); break;
  }
}
