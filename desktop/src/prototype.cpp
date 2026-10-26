#include "prototype.h"

#include "core.h"

#include <QFileInfo>
#include <QJsonObject>
#include <QQmlEngine>

namespace {

QString gib(double bytes) { return QString::number(bytes / (1 << 30), 'f', 1) + " GB"; }

} // namespace

Prototype::Prototype(Core *core, QObject *parent) : QObject(parent), m_core(core) {}

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
  const QString name = m_sources[index].toObject()["rawName"].toString();
  m_core->send("POST", "/api/v1/downloads", {}, body, this, [this, name](const Core::Reply &reply) {
    if (failed("POST", "/api/v1/downloads", reply.status, reply.message()))
      return;
    setStatus({});
    emit started(reply.json()["id"].toString(), name);
  });
}

void Prototype::openLocal(const QString &path) {
  m_core->send("POST", "/api/v1/local", {}, QJsonObject{{"path", path}}, this,
               [this, path](const Core::Reply &reply) {
                 if (!failed("POST", "/api/v1/local", reply.status, reply.message()))
                   emit started(reply.json()["id"].toString(), QFileInfo(path).fileName());
               });
}

void Prototype::setStatus(const QString &status) {
  if (status == m_status)
    return;
  m_status = status;
  emit statusChanged();
}
