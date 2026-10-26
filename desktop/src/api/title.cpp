#include "title.h"

#include "core.h"
#include "downloads.h"

#include <QQmlEngine>
#include <QTimer>

Title::Title(Core *core, const QString &itemId, QObject *parent)
    : QObject(parent), m_core(core), m_itemId(itemId) {
  load();
}

void Title::componentComplete() {
  m_core = qmlEngine(this)->singletonInstance<Core *>("Lumeo", "Core");
  load();
}

void Title::setItemId(const QString &itemId) {
  if (itemId == m_itemId)
    return;
  m_itemId = itemId;
  emit itemIdChanged();
  if (m_core)
    load();
}

QVariantMap Title::opening() const {
  const QJsonObject next = m_progress["next"].toObject();
  if (!next.isEmpty())
    return {{"season", next["season"].toInt()}, {"episode", next["episode"].toInt()}};
  const QJsonObject upcoming = m_progress["upcoming"].toObject();
  if (!upcoming.isEmpty())
    return {{"season", upcoming["season"].toInt()}, {"episode", upcoming["number"].toInt()}};
  QJsonObject latest;
  for (const QJsonValue &entry : m_progress["entries"].toArray())
    if (latest.isEmpty() || entry["updatedAt"].toString() > latest["updatedAt"].toString())
      latest = entry.toObject();
  if (latest.isEmpty())
    return {};
  return {{"season", latest["season"].toInt()}, {"episode", latest["episode"].toInt()}};
}

void Title::load() {
  const int load = ++m_load;
  m_status = Loading;
  m_error.clear();
  m_item = {};
  m_progress = {};
  emit changed();
  auto progressHere = std::make_shared<bool>(false);
  auto itemHere = std::make_shared<bool>(false);
  auto settle = [this, progressHere, itemHere] {
    if (*progressHere && *itemHere && m_status == Loading) {
      m_status = Ready;
      emit changed();
    }
  };
  const QString id = Core::segment(m_itemId);
  m_core->get("/api/v1/items/" + id, {}, this,
              [this, load, itemHere, settle](const Core::Reply &reply) {
                if (load != m_load)
                  return;
                if (!reply.ok()) {
                  m_status = Failed;
                  m_error = reply.message();
                  emit changed();
                  return;
                }
                m_item = reply.json().toObject();
                *itemHere = true;
                settle();
              });
  // Progress that fails leaves the page without it, not without the page.
  m_core->get("/api/v1/progress/" + id, {}, this,
              [this, load, progressHere, settle](const Core::Reply &reply) {
                if (load != m_load)
                  return;
                if (reply.ok())
                  m_progress = reply.json().toObject();
                *progressHere = true;
                settle();
              });
}

SourceChoice::SourceChoice(Core *core, Downloads *downloads, QObject *parent)
    : QObject(parent), m_core(core), m_downloads(downloads) {}

void SourceChoice::componentComplete() {
  QQmlEngine *engine = qmlEngine(this);
  m_core = engine->singletonInstance<Core *>("Lumeo", "Core");
  m_downloads = engine->singletonInstance<Downloads *>("Lumeo", "Downloads");
  m_complete = true;
  load();
}

void SourceChoice::setItemId(const QString &itemId) {
  if (itemId == m_itemId)
    return;
  m_itemId = itemId;
  emit keyChanged();
  reload();
}

void SourceChoice::setSeason(int season) {
  if (season == m_season)
    return;
  m_season = season;
  emit keyChanged();
  reload();
}

void SourceChoice::setEpisode(int episode) {
  if (episode == m_episode)
    return;
  m_episode = episode;
  emit keyChanged();
  reload();
}

QString SourceChoice::released() const {
  return m_released.isValid() ? m_released.toString(Qt::ISODate) : QString();
}

void SourceChoice::setReleased(const QString &released) {
  const QDateTime parsed = QDateTime::fromString(released, Qt::ISODate);
  if (parsed == m_released)
    return;
  m_released = parsed;
  emit keyChanged();
  emit changed();
}

// The page sets the season and the episode one after the other; one list is
// asked for the pair.
void SourceChoice::reload() {
  if (!m_complete || m_reloadQueued)
    return;
  m_reloadQueued = true;
  QTimer::singleShot(0, this, [this] {
    m_reloadQueued = false;
    // A Play held for the first list is for that one, not for whichever
    // episode is picked after.
    if (m_load > 0)
      m_startWhenReady = false;
    m_sources = {};
    m_failed = {};
    m_providers = 0;
    m_picked = -1;
    m_listed = false;
    m_errorStatus = -1;
    load();
  });
}

bool SourceChoice::upcoming() const { return m_released.isValid() && m_released > now(); }

QVariantMap SourceChoice::noRoom() const {
  if (m_errorStatus != 507 || !m_errorBody["size"].isDouble() || !m_errorBody["free"].isDouble())
    return {};
  return {{"size", m_errorBody["size"].toDouble()}, {"free", m_errorBody["free"].toDouble()}};
}

// Cinemeta's date is midnight UTC of the release day rather than an air time,
// so "today" is the whole of that day, and an empty list on it is normal:
// copies turn up in the hours after the episode airs.
QString SourceChoice::empty() const {
  if (!m_listed || !m_sources.isEmpty())
    return {};
  if (m_providers == 0)
    return "addons";
  // A refusal is the reason whatever the date: without it the list might
  // not have been empty.
  if (!m_failed.isEmpty())
    return "failed";
  if (m_released.isValid()) {
    const qint64 days = m_released.toUTC().date().daysTo(now().toUTC().date());
    if (days == 0)
      return "today";
    if (days == 1)
      return "yesterday";
  }
  return "none";
}

void SourceChoice::load(bool follow) {
  // The page names its title once the title is here.
  if (m_itemId.isEmpty())
    return;
  if (upcoming()) {
    m_startWhenReady = false;
    emit changed();
    return;
  }
  const int load = ++m_load;
  m_loading = true;
  emit changed();
  // A copy on disk needs no provider, and without a network the list would
  // keep Play waiting until they fail.
  if (m_startWhenReady && !onDisk().isEmpty())
    QTimer::singleShot(0, this, &SourceChoice::start);
  QUrlQuery query{{"item", m_itemId}};
  if (m_season > 0)
    query.addQueryItem("season", QString::number(m_season));
  if (m_episode > 0)
    query.addQueryItem("episode", QString::number(m_episode));
  m_core->get("/api/v1/sources", query, this, [this, load, follow](const Core::Reply &reply) {
    if (load != m_load)
      return;
    m_loading = false;
    if (reply.ok()) {
      const QJsonValue json = reply.json();
      m_sources = json["sources"].toArray();
      m_failed = json["failed"].toArray();
      m_providers = json["providers"].toInt();
      m_listed = true;
      m_errorStatus = -1;
      m_picked = m_sources.isEmpty() ? -1 : 0;
      if (follow)
        for (qsizetype i = 0; i < m_sources.size(); ++i)
          if (m_sources.at(i)["lastUsed"].toBool()) {
            m_picked = int(i);
            break;
          }
    } else {
      m_errorStatus = reply.status;
      m_errorMessage = reply.message();
      m_errorBody = reply.json().toObject();
      // Nothing to honour it with, and nothing to wait for either.
      m_startWhenReady = false;
    }
    emit changed();
    if (m_startWhenReady && m_picked >= 0) {
      m_startWhenReady = false;
      start();
    }
  });
}

void SourceChoice::pick(int index) {
  m_picked = index;
  m_errorStatus = -1;
  emit changed();
}

void SourceChoice::start() { begin(true); }

void SourceChoice::download() { begin(false); }

void SourceChoice::begin(bool play) {
  if (m_starting)
    return;
  const QString local = m_picked < 0 && play ? onDisk() : QString();
  if (!local.isEmpty()) {
    m_startWhenReady = false;
    emit started(local);
    return;
  }
  if (m_picked < 0) {
    // Still looking: hold the press. A look that found nothing has nothing
    // to hold.
    if (play && m_loading && !m_startWhenReady) {
      m_startWhenReady = true;
      emit changed();
    }
    return;
  }
  m_starting = true;
  m_errorStatus = -1;
  emit changed();
  m_downloads->start(m_itemId, m_sources.at(m_picked).toObject(), m_season, m_episode, false,
                     this, [this, play](const QJsonObject &answer, int status) {
                       m_starting = false;
                       if (status >= 200 && status < 300) {
                         emit changed();
                         if (play)
                           emit started(answer["id"].toString());
                         return;
                       }
                       m_errorStatus = status;
                       m_errorMessage = answer["error"].toString();
                       m_errorBody = answer;
                       emit changed();
                     });
}

QString SourceChoice::onDisk() const {
  const QVariantMap copy = m_downloads->of(m_itemId, m_season, m_episode);
  if (copy["state"] != "done")
    return {};
  for (const QVariant &d : m_downloads->all()) {
    const QVariantMap other = d.toMap();
    if (other["itemId"] == m_itemId && other["season"].toInt() == m_season &&
        other["episode"].toInt() == m_episode && other["state"] == "active")
      return {};
  }
  return copy["id"].toString();
}
