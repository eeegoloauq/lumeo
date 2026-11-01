#include "mine.h"

#include "core.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QQmlEngine>

Mine::Mine(Core *core, const QString &itemId, QObject *parent, int season, int episode)
    : QObject(parent), m_core(core), m_itemId(itemId), m_season(season), m_episode(episode) {
  load();
}

void Mine::componentComplete() {
  m_core = qmlEngine(this)->singletonInstance<Core *>("Lumeo", "Core");
  load();
}

void Mine::load() {
  const QString id = Core::segment(m_itemId);
  m_core->get("/api/v1/list/" + id, {}, this, [this, id](const Core::Reply &list) {
    if (!list.ok())
      return;
    m_core->get("/api/v1/ratings/" + id, {}, this, [this, list](const Core::Reply &ratings) {
      if (!ratings.ok())
        return;
      m_inList = m_saved = list.json()["inList"].toBool();
      for (const QJsonValue &r : ratings.json()["ratings"].toArray())
        if (r["season"].toInt() == m_season && r["episode"].toInt() == m_episode)
          m_score = r["rating"].toInt();
      m_known = true;
      emit changed();
    });
  });
}

void Mine::toggle() {
  if (!m_known)
    return;
  m_inList = !m_inList;
  emit changed();
  if (!m_sending)
    sendList();
}

void Mine::sendList() {
  if (m_inList == m_saved) {
    m_sending = false;
    emit stored();
    return;
  }
  m_sending = true;
  const bool want = m_inList;
  m_core->send(want ? "PUT" : "DELETE", "/api/v1/list/" + Core::segment(m_itemId), {},
               want ? QJsonValue(QJsonObject()) : QJsonValue::Undefined, this,
               [this, want](const Core::Reply &reply) {
                 if (!reply.ok()) {
                   m_sending = false;
                   m_inList = m_saved;
                   emit changed();
                   emit refused(want ? "add" : "remove");
                   return;
                 }
                 m_saved = want;
                 sendList();
               });
}

void Mine::rate(int score) {
  const int was = m_score;
  m_score = score;
  emit changed();
  m_core->send("PUT", "/api/v1/ratings/" + Core::segment(m_itemId), {},
               QJsonObject{{"season", m_season}, {"episode", m_episode}, {"rating", score}}, this,
               [this, was](const Core::Reply &reply) {
                 if (!reply.ok()) {
                   m_score = was;
                   emit changed();
                   emit refused("rate");
                   return;
                 }
                 emit stored();
                 // The core puts a title scored before it was ever played
                 // on My list.
                 if (!m_inList && !m_sending)
                   readList();
               });
}

void Mine::readList() {
  m_core->get("/api/v1/list/" + Core::segment(m_itemId), {}, this, [this](const Core::Reply &reply) {
    if (!reply.ok() || m_sending)
      return;
    m_inList = m_saved = reply.json()["inList"].toBool();
    emit changed();
  });
}

void Mine::clear() {
  const int was = m_score;
  m_score = 0;
  emit changed();
  m_core->send("DELETE", "/api/v1/ratings/" + Core::segment(m_itemId),
               {{"season", QString::number(m_season)}, {"episode", QString::number(m_episode)}},
               QJsonValue::Undefined, this,
               [this, was](const Core::Reply &reply) {
                 if (reply.ok()) {
                   emit stored();
                   return;
                 }
                 m_score = was;
                 emit changed();
                 emit refused("clear");
               });
}
