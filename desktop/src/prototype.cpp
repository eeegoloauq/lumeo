#include "prototype.h"

#include "core.h"

#include <QJsonObject>
#include <QQmlEngine>

namespace {

QString gib(double bytes) { return QString::number(bytes / (1 << 30), 'f', 1) + " GB"; }

} // namespace

Prototype::Prototype(Core *core, QObject *parent) : QObject(parent), m_core(core) {
  m_poll.setInterval(1000);
  m_poll.setSingleShot(true);
  connect(&m_poll, &QTimer::timeout, this, [this] { waitForReady(m_waitingFor); });
}

Prototype *Prototype::create(QQmlEngine *qml, QJSEngine *) {
  return new Prototype(qml->singletonInstance<Core *>("Lumeo", "Core"));
}

bool Prototype::failed(const QByteArray &method, const QString &path, int status,
                       const QString &message) {
  if (status >= 200 && status < 300)
    return false;
  setStatus(QString("%1 %2 → %3 %4").arg(QString(method), path).arg(status).arg(message));
  return true;
}

void Prototype::search(const QString &query) {
  for (const QString kind : {"movie", "series"})
    m_core->get("/api/v1/search", QUrlQuery{{"q", query}, {"kind", kind}}, this,
                [this, query, kind](const Core::Reply &reply) {
                  QVariantList items;
                  if (!failed("GET", "/api/v1/search", reply.status, reply.message()))
                    for (const QJsonValue &item : reply.json()["items"].toArray())
                      items.append(item.toObject().toVariantMap());
                  emit searched(query, kind, items);
                });
}

void Prototype::sources(const QString &itemId, int season, int episode) {
  QUrlQuery query{{"item", itemId}};
  if (season > 0)
    query.addQueryItem("season", QString::number(season));
  if (episode > 0)
    query.addQueryItem("episode", QString::number(episode));
  setStatus("Asking for copies…");
  m_core->get("/api/v1/sources", query, this, [this](const Core::Reply &reply) {
    if (failed("GET", "/api/v1/sources", reply.status, reply.message()))
      return;
    m_sources = reply.json()["sources"].toArray();
    QVariantList rows;
    for (const QJsonValue &source : m_sources) {
      const QJsonObject release = source["release"].toObject();
      rows.append(QVariantMap{
          {"name", source["rawName"].toString()},
          {"resolution", release["resolution"].toString()},
          {"size", gib(source["size"].toDouble())},
          {"seeders", source["seeders"].toInt()},
      });
    }
    setStatus(rows.isEmpty() ? "No copies" : QString());
    emit sourcesListed(rows);
  });
}

void Prototype::play(const QString &itemId, int index, int season, int episode) {
  if (index < 0 || index >= m_sources.size())
    return;
  const QJsonObject body{
      {"itemId", itemId},
      {"season", season},
      {"episode", episode},
      {"source", m_sources[index]},
  };
  setStatus("Starting the download…");
  m_core->send("POST", "/api/v1/downloads", {}, body, this, [this](const Core::Reply &reply) {
    if (!failed("POST", "/api/v1/downloads", reply.status, reply.message()))
      waitForReady(reply.json()["id"].toString());
  });
}

void Prototype::openLocal(const QString &path) {
  m_core->send("POST", "/api/v1/local", {}, QJsonObject{{"path", path}}, this,
               [this](const Core::Reply &reply) {
                 if (!failed("POST", "/api/v1/local", reply.status, reply.message()))
                   waitForReady(reply.json()["id"].toString());
               });
}

// The core says `ready` once the front of the file is on disk; before that
// mpv would block on its first read (docs/decisions/player.md).
void Prototype::waitForReady(const QString &downloadId) {
  m_poll.stop();
  m_waitingFor = downloadId;
  const QString path = "/api/v1/downloads/" + Core::segment(downloadId);
  m_core->get(path, {}, this, [this, downloadId, path](const Core::Reply &reply) {
    if (downloadId != m_waitingFor || failed("GET", path, reply.status, reply.message()))
      return;
    const QJsonValue json = reply.json();
    if (json["ready"].toBool()) {
      setStatus({});
      emit playable(m_core->url(path + "/stream").toString());
      return;
    }
    const QJsonObject progress = json["progress"].toObject();
    setStatus(QString("Waiting: %1 peers, %2 of %3")
                  .arg(progress["peers"].toInt())
                  .arg(gib(progress["completed"].toDouble()), gib(progress["total"].toDouble())));
    m_poll.start();
  });
}

void Prototype::setStatus(const QString &status) {
  if (status == m_status)
    return;
  m_status = status;
  emit statusChanged();
}
