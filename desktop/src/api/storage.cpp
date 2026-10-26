#include "storage.h"

#include "core.h"
#include "downloads.h"

#include <QJsonArray>
#include <QJsonObject>
#include <QQmlEngine>
#include <memory>

void Storage::componentComplete() {
  QQmlEngine *qml = qmlEngine(this);
  m_core = qml->singletonInstance<Core *>("Lumeo", "Core");
  m_downloads = qml->singletonInstance<Downloads *>("Lumeo", "Downloads");
  load();
}

QString Storage::keyOf(const QVariantMap &title) {
  const QString itemId = title.value("itemId").toString();
  return !itemId.isEmpty() ? itemId : "download:" + title.value("title").toString();
}

void Storage::load() {
  m_core->get("/api/v1/storage", {}, this, [this](const Core::Reply &reply) {
    if (reply.ok()) {
      const QJsonObject json = reply.json().toObject();
      m_used = json["used"].toDouble();
      m_diskTotal = json["disk"]["total"].toDouble();
      m_diskFree = json["disk"]["free"].toDouble();
      m_cache = json["cache"].toDouble();
      m_titles = json["titles"].toArray().toVariantList();
      for (QVariant &title : m_titles) {
        QVariantMap map = title.toMap();
        map["key"] = keyOf(map);
        title = map;
      }
      m_known = true;
    }
    m_error = reply.ok() ? QString() : reply.message();
    emit changed();
  });
}

void Storage::free(const QString &key) {
  for (const QVariant &t : m_titles) {
    const QVariantMap title = t.toMap();
    if (title.value("key") != key)
      continue;
    const QString itemId = title.value("itemId").toString();
    QList<std::pair<QString, QUrlQuery>> deletes;
    if (!itemId.isEmpty())
      deletes.append({"/api/v1/storage", QUrlQuery{{"item", itemId}}});
    else
      for (const QVariant &d : title.value("downloads").toList())
        deletes.append({"/api/v1/downloads/" + Core::segment(d.toMap().value("id").toString()),
                        QUrlQuery{{"data", "true"}}});
    act(key, deletes);
    return;
  }
}

void Storage::freeAll() { act("all", {{"/api/v1/storage", {}}}); }

void Storage::clearCache() { act("cache", {{"/api/v1/cache", {}}}); }

// The deletes one after another; the first refusal stops the rest and is
// said, and either way the list is read again.
void Storage::act(const QString &what, const QList<std::pair<QString, QUrlQuery>> &deletes) {
  if (!m_freeing.isEmpty() || deletes.isEmpty())
    return;
  m_freeing = what;
  m_error.clear();
  emit changed();
  auto next = std::make_shared<std::function<void(qsizetype)>>();
  *next = [this, deletes, next](qsizetype i) {
    if (i == deletes.size()) {
      m_freeing.clear();
      m_downloads->refresh();
      load();
      return;
    }
    m_core->send("DELETE", deletes[i].first, deletes[i].second, QJsonValue::Undefined, this,
                 [this, i, next](const Core::Reply &reply) {
                   if (reply.ok()) {
                     (*next)(i + 1);
                     return;
                   }
                   m_freeing.clear();
                   m_error = reply.message();
                   emit changed();
                   load();
                 });
  };
  (*next)(0);
}
