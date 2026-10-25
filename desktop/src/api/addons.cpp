#include "addons.h"

#include <QJsonObject>
#include <QQmlEngine>

Addons::Addons(Core *core, QObject *parent) : QObject(parent), m_core(core) {}

Addons *Addons::create(QQmlEngine *qml, QJSEngine *) {
  return new Addons(qml->singletonInstance<Core *>("Lumeo", "Core"));
}

Core::Answer Addons::apply(std::function<void(const QJsonValue &)> change) {
  return [this, change](const Core::Reply &reply) {
    if (reply.ok())
      change(reply.json());
    m_error = reply.ok() ? QString() : reply.message();
    emit changed();
  };
}

void Addons::load() {
  m_core->get("/api/v1/addons", {}, this, apply([this](const QJsonValue &json) {
                m_current = json["addons"].toArray();
                m_loaded = true;
              }));
}

void Addons::replace(const QJsonObject &addon) {
  for (qsizetype i = 0; i < m_current.size(); ++i)
    if (m_current.at(i)["id"] == addon["id"]) {
      m_current[i] = addon;
      return;
    }
  m_current.append(addon);
}

void Addons::add(const QString &url) {
  m_adding = true;
  m_addError.clear();
  emit changed();
  m_core->send("POST", "/api/v1/addons", {}, QJsonObject{{"url", url}}, this,
               [this](const Core::Reply &reply) {
                 m_adding = false;
                 if (reply.ok()) {
                   replace(reply.json().toObject());
                   m_error.clear();
                 } else {
                   m_addError = reply.message();
                 }
                 emit changed();
               });
}

void Addons::setEnabled(const QString &id, bool enabled) {
  m_core->send("PATCH", "/api/v1/addons/" + Core::segment(id), {},
               QJsonObject{{"enabled", enabled}}, this,
               apply([this](const QJsonValue &addon) { replace(addon.toObject()); }));
}

// Every position after the moved one shifts, so the list is asked again.
void Addons::move(const QString &id, int to) {
  m_core->send("PATCH", "/api/v1/addons/" + Core::segment(id), {}, QJsonObject{{"position", to}},
               this, [this](const Core::Reply &reply) {
                 if (reply.ok())
                   load();
                 else
                   apply([](const QJsonValue &) {})(reply);
               });
}

void Addons::remove(const QString &id) {
  m_core->send("DELETE", "/api/v1/addons/" + Core::segment(id), {}, QJsonValue::Undefined, this,
               [this, id](const Core::Reply &reply) {
                 // Already gone is gone.
                 Core::Reply done = reply;
                 if (reply.status == 404)
                   done.status = 204;
                 apply([this, id](const QJsonValue &) {
                   for (qsizetype i = 0; i < m_current.size(); ++i)
                     if (m_current.at(i)["id"] == id)
                       m_current.removeAt(i--);
                 })(done);
               });
}
