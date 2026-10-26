#include "corestatus.h"

#include "core.h"

#include <QQmlEngine>

void CoreStatus::componentComplete() {
  m_core = qmlEngine(this)->singletonInstance<Core *>("Lumeo", "Core");
  load();
}

QString CoreStatus::address() const {
  if (!m_addr.isEmpty() || !m_core)
    return m_addr;
  return m_core->address().authority();
}

void CoreStatus::load() {
  m_asking = true;
  emit changed();
  m_core->get("/healthz", {}, this, [this](const Core::Reply &reply) {
    m_asking = false;
    m_answering = reply.ok();
    m_error = reply.ok() ? QString() : reply.message();
    m_providers = reply.ok() ? reply.json()["providers"].toInt() : -1;
    emit changed();
  });
  m_core->get("/api/v1/about", {}, this, [this](const Core::Reply &reply) {
    if (!reply.ok())
      return;
    m_addr = reply.json()["addr"].toString();
    m_logPath = reply.json()["logPath"].toString();
    m_downloadDir = reply.json()["downloadDir"].toString();
    emit changed();
  });
}
