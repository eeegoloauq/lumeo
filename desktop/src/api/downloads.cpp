#include "downloads.h"

#include "core.h"

#include <QQmlEngine>
#include <QUrlQuery>

Downloads::Downloads(Core *core, QObject *parent) : QObject(parent), m_core(core) {
  m_poll.setSingleShot(true);
  connect(&m_poll, &QTimer::timeout, this, &Downloads::refresh);
  refresh();
}

Downloads *Downloads::create(QQmlEngine *qml, QJSEngine *) {
  return new Downloads(qml->singletonInstance<Core *>("Lumeo", "Core"));
}

int Downloads::running() const {
  return std::count_if(m_downloads.begin(), m_downloads.end(),
                       [](const QJsonValue &d) { return d["state"] == "active"; });
}

QVariantMap Downloads::of(const QString &itemId, int season, int episode) const {
  QJsonObject found;
  for (const QJsonValue &d : m_downloads) {
    if (d["itemId"] != itemId || d["season"].toInt() != season || d["episode"].toInt() != episode)
      continue;
    if (d["state"] == "done")
      return d.toObject().toVariantMap();
    if (found.isEmpty())
      found = d.toObject();
  }
  return found.toVariantMap();
}

QVariantMap Downloads::itemOf(const QString &itemId) const {
  return m_items.value(itemId).toVariantMap();
}

void Downloads::start(const QString &itemId, const QJsonObject &source, int season, int episode,
                      bool prefetch, QObject *context,
                      std::function<void(const QJsonObject &, int)> answer) {
  QJsonObject body{{"itemId", itemId}, {"season", season}, {"episode", episode}, {"source", source}};
  if (prefetch)
    body["prefetch"] = true;
  m_core->send("POST", "/api/v1/downloads", {}, body, context,
               [this, answer](const Core::Reply &reply) {
                 if (reply.ok())
                   adopt(reply.json().toObject());
                 answer(reply.json().toObject(), reply.status);
               });
}

void Downloads::openLocal(const QString &path, QObject *context, Core::Answer answer) {
  m_core->send("POST", "/api/v1/local", {}, QJsonObject{{"path", path}}, context,
               [this, answer](const Core::Reply &reply) {
                 if (reply.ok())
                   adopt(reply.json().toObject());
                 answer(reply);
               });
}

// One the core already had (Play on a copy on disk) is updated where it is.
void Downloads::adopt(const QJsonObject &download) {
  ++m_adopted;
  const QString id = download["id"].toString();
  bool known = false;
  for (qsizetype i = 0; i < m_downloads.size(); ++i)
    if (m_downloads.at(i)["id"] == id) {
      m_downloads[i] = download;
      known = true;
    }
  if (!known)
    m_downloads.prepend(download);
  update();
  resolveTitles();
  // Polled at the pace of something moving from now, not after the idle
  // wait already running.
  schedule();
}

void Downloads::setPaused(const QString &id, bool paused) {
  m_core->send("PATCH", "/api/v1/downloads/" + Core::segment(id), {},
               QJsonObject{{"paused", paused}}, this, [this](const Core::Reply &reply) {
                 // A refusal changes nothing; the next poll shows the core's state.
                 if (reply.ok())
                   adopt(reply.json().toObject());
               });
}

void Downloads::stop(const QString &id) {
  // A poll already asked would put it back.
  ++m_adopted;
  for (qsizetype i = 0; i < m_downloads.size(); ++i)
    if (m_downloads.at(i)["id"] == id) {
      m_downloads.removeAt(i);
      update();
      break;
    }
  m_core->send("DELETE", "/api/v1/downloads/" + Core::segment(id), QUrlQuery{{"data", "true"}},
               QJsonValue::Undefined, this, [](const Core::Reply &) {});
}

void Downloads::refresh() {
  const int asked = m_adopted;
  m_core->get("/api/v1/downloads", {}, this, [this, asked](const Core::Reply &reply) {
    // A failed poll keeps the last known state; the screens say the core is
    // gone, since their own requests fail too.
    if (reply.ok() && asked == m_adopted) {
      const QJsonArray fresh = reply.json()["downloads"].toArray();
      // Most polls find the same numbers, and every change redraws the
      // posters on screen.
      if (fresh != m_downloads) {
        m_downloads = fresh;
        update();
      }
      resolveTitles();
    }
    schedule();
  });
}

void Downloads::resolveTitles() {
  for (const QJsonValue &d : m_downloads) {
    const QString itemId = d["itemId"].toString();
    if (itemId.isEmpty() || m_items.contains(itemId))
      continue;
    // Held empty while asked, so the next poll does not ask again; a title
    // that does not come costs a line of detail, and is asked for again.
    m_items.insert(itemId, {});
    m_core->get("/api/v1/items/" + Core::segment(itemId), {}, this,
                [this, itemId](const Core::Reply &reply) {
                  if (!reply.ok()) {
                    m_items.remove(itemId);
                    return;
                  }
                  m_items.insert(itemId, reply.json().toObject());
                  emit changed();
                });
  }
}

void Downloads::update() {
  struct Mark {
    bool arriving = false;
    bool onDisk = false;
    qint64 completed = 0;
    qint64 total = 0;
  };
  QHash<QString, Mark> marks;
  for (const QJsonValue &d : m_downloads) {
    const QString itemId = d["itemId"].toString();
    const QString episode =
        QString("%1/%2/%3").arg(itemId).arg(d["season"].toInt()).arg(d["episode"].toInt());
    for (const QString &key : {itemId, episode}) {
      Mark &mark = marks[key];
      if (d["state"] == "done")
        mark.onDisk = true;
      if (d["state"] == "active") {
        mark.arriving = true;
        mark.completed += d["progress"]["completed"].toInteger();
        mark.total += d["progress"]["total"].toInteger();
      }
    }
  }
  m_marks.clear();
  for (auto mark = marks.cbegin(); mark != marks.cend(); ++mark) {
    if (mark->arriving) {
      const double fraction = mark->total > 0 ? double(mark->completed) / mark->total : 0.0;
      m_marks.insert(mark.key(), QVariantMap{{"fraction", fraction}});
    }
    else if (mark->onDisk)
      m_marks.insert(mark.key(), QVariantMap{{"done", true}});
  }
  emit changed();
}

void Downloads::schedule() { m_poll.start(running() > 0 ? activeInterval : idleInterval); }
