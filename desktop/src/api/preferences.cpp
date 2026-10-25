#include "preferences.h"

#include "core.h"

#include <QJsonArray>
#include <QQmlEngine>

Preferences::Preferences(Core *core, QObject *parent) : QObject(parent), m_core(core) {
  m_rememberTimer.setSingleShot(true);
  connect(&m_rememberTimer, &QTimer::timeout, this, [this] {
    const QVariantMap latest = std::exchange(m_remembered, {});
    if (!latest.isEmpty())
      patch(latest);
  });
}

// The accent is on the first frame, so the app asks as it starts.
Preferences *Preferences::create(QQmlEngine *qml, QJSEngine *) {
  auto *preferences = new Preferences(qml->singletonInstance<Core *>("Lumeo", "Core"));
  preferences->load();
  return preferences;
}

void Preferences::load() {
  m_core->get("/api/v1/preferences", {}, this, [this](const Core::Reply &reply) {
    if (reply.ok())
      m_current = reply.json().toObject();
    m_error = reply.ok() ? QString() : reply.message();
    emit changed();
  });
  m_core->get("/api/v1/preferences/languages", {}, this, [this](const Core::Reply &reply) {
    // Left as it was, and asked for again on the next load.
    if (!reply.ok())
      return;
    m_languages = reply.json()["languages"].toArray().toVariantList();
    emit changed();
  });
}

void Preferences::patch(const QVariantMap &patch) {
  write("PATCH", QJsonObject::fromVariantMap(patch), patch.keys());
}

void Preferences::reset() {
  m_rememberTimer.stop();
  m_remembered.clear();
  write("DELETE", {}, {});
}

void Preferences::remember(const QString &key, const QVariant &value) {
  m_remembered.insert(key, value);
  m_rememberTimer.start(rememberDelay);
}

void Preferences::write(const QByteArray &method, const QJsonObject &body,
                        const QStringList &keys) {
  m_writes.push_back([this, method, body, keys] {
    const QJsonValue sent = method == "DELETE" ? QJsonValue::Undefined : QJsonValue(body);
    m_core->send(method, "/api/v1/preferences", {}, sent, this,
                 [this, keys](const Core::Reply &reply) {
                   if (reply.ok())
                     m_current = reply.json().toObject();
                   m_error = reply.ok() ? QString() : reply.message();
                   m_failedKeys = reply.ok() ? QStringList() : keys;
                   emit changed();
                   m_writing = false;
                   next();
                 });
  });
  next();
}

void Preferences::next() {
  if (m_writing || m_writes.empty())
    return;
  m_writing = true;
  const Write send = std::move(m_writes.front());
  m_writes.pop_front();
  send();
}
