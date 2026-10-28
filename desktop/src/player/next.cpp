#include "next.h"

#include "core.h"
#include "downloads.h"
#include "mpvitem.h"
#include "preferences.h"
#include "title.h"

#include <QJsonObject>
#include <QRegularExpression>
#include <cmath>

namespace {

// Word boundaries, or "Operation Mindcrime" would be an opening.
QRegularExpression named(const QStringList &names) {
  return QRegularExpression("\\b(?:" + names.join('|') + ")\\b",
                            QRegularExpression::CaseInsensitiveOption);
}

const QRegularExpression opening = named({"OP", "Opening", "NCOP"});
// "Intro" can name a cold open: an opening only without a stronger name.
const QRegularExpression intro = named({"Intro"});
const QRegularExpression ending = named({"ED", "Ending", "Credits", "Preview", "NCED"});

QString titleOf(const QVariantList &chapters, int i) {
  return chapters[i].toMap().value("title").toString();
}

double timeOf(const QVariantList &chapters, int i) {
  return chapters[i].toMap().value("time").toDouble();
}

int firstNamed(const QVariantList &chapters, const QRegularExpression &names) {
  for (int i = 0; i < chapters.size(); ++i)
    if (names.match(titleOf(chapters, i)).hasMatch())
      return i;
  return -1;
}

bool isEnding(const QString &title) {
  return ending.match(title).hasMatch() && !opening.match(title).hasMatch() &&
         !intro.match(title).hasMatch();
}

Next::Moment span(const QString &action, double start, double end, double position,
                  bool includeEnd, bool credits = true) {
  if (end - start <= 0 || position < start || (includeEnd ? position > end : position >= end))
    return {};
  return {action, start, end, (position - start) / (end - start), credits};
}

bool upcoming(const QVariantMap &episode) {
  const QDateTime released =
      QDateTime::fromString(episode.value("released").toString(), Qt::ISODate);
  return released.isValid() && released > QDateTime::currentDateTimeUtc();
}

} // namespace

int Next::openingChapter(const QVariantList &chapters) {
  const int named = firstNamed(chapters, opening);
  return named >= 0 ? named : firstNamed(chapters, intro);
}

// The opening and the first chapter are never the ending; consecutive ending
// and preview chapters are one.
int Next::endingChapter(const QVariantList &chapters) {
  const int opened = openingChapter(chapters);
  const int floor = opened < 0 ? 1 : opened + 1;
  int start = -1;
  for (int i = int(chapters.size()) - 1; i >= floor; --i) {
    if (isEnding(titleOf(chapters, i)))
      start = i;
    else if (start >= 0)
      break;
  }
  return start;
}

int Next::afterEnding(const QVariantList &chapters, int start) {
  for (int i = start; i < chapters.size(); ++i)
    if (!isEnding(titleOf(chapters, i)))
      return i;
  return -1;
}

bool Next::inCredits(const QVariantList &chapters, double position) {
  const int at = endingChapter(chapters);
  return at >= 0 && position >= timeOf(chapters, at);
}

Next::Moment Next::moment(const QVariantList &chapters, double position, double duration,
                          bool hasNext, double notice) {
  const int opened = openingChapter(chapters);
  if (opened >= 0) {
    // mpv lists starts only: the next start, or the file's end, ends it. At
    // the next chapter a skip would seek to the frame on screen.
    const double end = opened + 1 < chapters.size() ? timeOf(chapters, opened + 1) : duration;
    const Moment skip = span("intro", timeOf(chapters, opened), end, position, false);
    if (!skip.action.isEmpty())
      return skip;
  }
  const int ended = endingChapter(chapters);
  const int after = ended < 0 ? -1 : afterEnding(chapters, ended);
  if (after >= 0) {
    // A scene after the credits belongs to the episode: skipped to, as the
    // opening is, whether or not an episode follows.
    const Moment skip =
        span("ending", timeOf(chapters, ended), timeOf(chapters, after), position, false);
    if (!skip.action.isEmpty())
      return skip;
  }
  if (!hasNext)
    return {};
  if (ended < 0 || after >= 0) {
    // Past half a short file, "before the end" would be all of it: it is
    // offered its successor once it ends.
    if (notice <= 0 || duration < notice * 2)
      return {};
    return span("next", duration - notice, duration, position, true, false);
  }
  // Over the credits and the previews after them; mpv can hold the last
  // frame at exactly the file's length.
  return span("next", timeOf(chapters, ended), duration, position, true);
}

Next::Next(MpvItem *mpv, Core *core, Preferences *preferences, Downloads *downloads,
           QObject *parent)
    : QObject(parent), m_mpv(mpv), m_core(core), m_preferences(preferences),
      m_downloads(downloads) {
  connect(mpv, &MpvItem::positionChanged, this, &Next::recompute);
  connect(mpv, &MpvItem::chaptersChanged, this, &Next::recompute);
  connect(mpv, &MpvItem::hasPictureChanged, this, &Next::recompute);
  // `keep-open` holds the last frame, and eof-reached says so; a seek back
  // clears it. Not the position: a seek forward from the end steps back to
  // the last frame, seconds before a soundtrack that outlasts the picture.
  connect(mpv, &MpvItem::endedChanged, this, [this] {
    if (m_mpv->ended()) {
      onEnded();
      return;
    }
    m_fileEnded = false;
    m_endedAt = {};
    m_countdown.stop();
    recompute();
  });
  connect(downloads, &Downloads::changed, this, &Next::changed);
  m_countdown.setInterval(100);
  connect(&m_countdown, &QTimer::timeout, this, [this] {
    recompute();
    if (m_fill >= 1) {
      m_countdown.stop();
      advance();
    }
  });
}

QVariantMap Next::download() const {
  if (m_episode.isEmpty())
    return {};
  return m_downloads->of(m_playing.value("itemId").toString(), m_episode.value("season").toInt(),
                         m_episode.value("number").toInt());
}

double Next::grace() const {
  return m_preferences->current().value("nextCountdown", 5).toDouble() * second / 1000;
}

double Next::notice() const {
  return m_preferences->current().value("nextNotice", 0).toDouble() * second / 1000;
}

void Next::update(const QVariantMap &download) {
  m_playing = download;
  lookUp();
  prefetch();
}

// The episode after this one, not the progress's own `next`: near the end
// that already names the one after it.
void Next::lookUp() {
  const QString itemId = m_playing.value("itemId").toString();
  const int season = m_playing.value("season").toInt();
  const int number = m_playing.value("episode").toInt();
  if (m_asked || itemId.isEmpty() || (season <= 0 && number <= 0))
    return;
  m_asked = true;
  m_core->get("/api/v1/items/" + Core::segment(itemId) + "/after",
              QUrlQuery{{"season", QString::number(season)}, {"episode", QString::number(number)}},
              this, [this](const Core::Reply &reply) {
                // The core not answering is worth another ask; its answer,
                // even a refusal, stands for this episode.
                if (reply.status == 0) {
                  m_asked = false;
                  return;
                }
                m_episode = reply.json()["next"].toObject().toVariantMap();
                emit changed();
                recompute();
                prefetch();
                // An end that came before the answer.
                if (m_fileEnded && !m_episode.isEmpty()) {
                  m_fileEnded = false;
                  onEnded();
                }
              });
}

// Once this episode is on disk, the next one starts downloading: the copy
// Play would start for it. The core refuses one that does not fit inside the
// disk limit, and that refusal is the answer, not a failure.
void Next::prefetch() {
  if (m_prefetchAsked || m_playing.value("state") != "done" || m_episode.isEmpty() ||
      upcoming(m_episode))
    return;
  if (m_prefetchAgainAt.isValid() && QDateTime::currentDateTime() < m_prefetchAgainAt)
    return;
  m_prefetchAsked = true;
  if (!m_preferences->current().value("prefetch", true).toBool()) {
    m_fetch = Off;
    emit changed();
    return;
  }
  const QVariantMap existing = download();
  if (!existing.isEmpty() && existing.value("state") != "failed")
    return;
  fetchNext(true);
}

void Next::fetchNext(bool prefetch) {
  if (m_episode.isEmpty() || m_fetching)
    return;
  m_fetching = new SourceChoice(m_core, m_downloads, this);
  m_fetching->setItemId(m_playing.value("itemId").toString());
  m_fetching->setSeason(m_episode.value("season").toInt());
  m_fetching->setEpisode(m_episode.value("number").toInt());
  auto settle = [this, prefetch](Fetch outcome) {
    m_fetching->deleteLater();
    m_fetching = nullptr;
    // A failure is the network or a provider, not an answer: the prefetch
    // asks again, while a refusal for room or an empty list stands.
    if (prefetch && outcome == Failed) {
      m_prefetchAgainAt = QDateTime::currentDateTime().addMSecs(prefetchRetry);
      m_prefetchAsked = false;
    }
    m_fetch = outcome;
    m_downloads->refresh();
    emit changed();
  };
  connect(m_fetching, &SourceChoice::changed, this, [this, prefetch, settle] {
    if (!m_fetching->listed() && m_fetching->errorStatus() < 0)
      return;
    if (m_fetching->errorStatus() >= 0 || m_fetching->picked() < 0) {
      settle(m_fetching->errorStatus() >= 0 || !m_fetching->failed().isEmpty() ? Failed : NoCopy);
      return;
    }
    const QJsonObject source =
        QJsonObject::fromVariantMap(m_fetching->sources().at(m_fetching->picked()).toMap());
    QObject::disconnect(m_fetching, &SourceChoice::changed, this, nullptr);
    m_downloads->start(m_playing.value("itemId").toString(), source,
                       m_episode.value("season").toInt(), m_episode.value("number").toInt(),
                       prefetch, this, [settle](const QJsonObject &, int status) {
                         settle(status >= 200 && status < 300 ? Waiting
                                : status == 507             ? NoRoom
                                                            : Failed);
                       });
  });
  m_fetching->load();
}

// The end of the file. A named ending goes on at once; an unnamed end holds
// its last frame and counts down, or waits for a press when the countdown
// is off.
void Next::onEnded() {
  if (m_advancing || m_endedAt.isValid() || !m_opened || !m_mpv)
    return;
  m_endedPosition = m_mpv->position();
  m_fileEnded = true;
  if (m_episode.isEmpty())
    return;
  const Moment showing = moment(m_mpv->chapters(), m_mpv->position(), m_mpv->duration(), true,
                                notice());
  m_offerStart = showing.action == "next" ? showing.start : m_endedPosition;
  if (showing.action == "next" && showing.credits && grace() > 0) {
    advance();
    return;
  }
  m_endedAt = QDateTime::currentDateTime();
  recompute();
  if (grace() > 0)
    m_countdown.start();
}

void Next::recompute() {
  QString offer;
  double fill = 0;
  int secondsLeft = -1;
  const bool hasNext = !m_episode.isEmpty();
  if (m_mpv && m_mpv->hasPicture() && !m_advancing) {
    const double countdown = grace();
    if (m_endedAt.isValid() && hasNext) {
      offer = "next";
      if (countdown > 0) {
        const double since = m_endedAt.msecsTo(QDateTime::currentDateTime()) / 1000.0;
        const double played = m_endedPosition - m_offerStart;
        fill = std::clamp((played + since) / (played + countdown), 0.0, 1.0);
        secondsLeft = std::max(0, int(std::ceil(countdown - since)));
      }
    } else {
      const Moment now =
          moment(m_mpv->chapters(), m_mpv->position(), m_mpv->duration(), hasNext, notice());
      offer = now.action;
      fill = now.fill;
      m_target = now.end;
      if (offer == "next") {
        // Only credits count down to the next episode; the notice before an
        // unnamed end offers it, and the held last frame counts.
        const double length = now.end - now.start + (now.credits ? 0 : countdown);
        fill = length > 0 ? std::clamp((m_mpv->position() - now.start) / length, 0.0, 1.0) : 0;
        if (countdown > 0 && now.credits)
          secondsLeft = std::max(0, int(now.end - m_mpv->position()));
      }
    }
  }
  if (offer == m_offer && fill == m_fill && secondsLeft == m_secondsLeft)
    return;
  m_offer = offer;
  m_fill = fill;
  m_secondsLeft = secondsLeft;
  emit offerChanged();
}

void Next::skip() {
  if (m_mpv && (m_offer == "intro" || m_offer == "ending"))
    m_mpv->command({"seek", QString::number(m_target, 'f', 3), "absolute+exact"});
}

void Next::advance() {
  if (m_advancing || m_episode.isEmpty())
    return;
  m_countdown.stop();
  // Credits skipped count as watched before the core's 90%.
  emit watched();
  play(m_episode);
}

// One episode at a time: a second pick while one is starting would start a
// second download.
void Next::play(const QVariantMap &episode) {
  if (upcoming(episode) || (m_choice && m_choice->pending()))
    return;
  m_advancing = true;
  m_starting = episode;
  if (m_mpv && !m_mpv->paused())
    m_mpv->set("pause", true);
  if (m_choice)
    m_choice->deleteLater();
  m_choice = new SourceChoice(m_core, m_downloads, this);
  m_choice->setItemId(m_playing.value("itemId").toString());
  m_choice->setSeason(episode.value("season").toInt());
  m_choice->setEpisode(episode.value("number").toInt());
  m_choice->setProperty("startWhenReady", true);
  connect(m_choice, &SourceChoice::started, this, &Next::next);
  emit changed();
  recompute();
  m_choice->load();
}

void Next::retry() {
  if (!m_choice)
    return;
  if (m_choice->picked() >= 0) {
    m_choice->start();
    return;
  }
  m_choice->setProperty("startWhenReady", true);
  m_choice->load();
}
