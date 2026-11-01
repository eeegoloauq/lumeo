#include "viewing.h"

#include "core.h"

#include <QJsonObject>
#include <QQmlEngine>

Viewing::Viewing(Core *core, QObject *parent) : QObject(parent), m_core(core) {
  m_undo.setSingleShot(true);
  m_undo.setInterval(5000);
  connect(&m_undo, &QTimer::timeout, this, &Viewing::commit);
}

Viewing *Viewing::create(QQmlEngine *qml, QJSEngine *) {
  return new Viewing(qml->singletonInstance<Core *>("Lumeo", "Core"));
}

Viewing::~Viewing() {
  // Told on the core's behalf, since this is going.
  if (!m_forgetting.isEmpty())
    m_core->send("DELETE", "/api/v1/progress/" + Core::segment(m_forgetting), {},
                 QJsonValue::Undefined, m_core, [](const Core::Reply &) {});
}

void Viewing::setUndoTime(int ms) {
  if (ms == m_undo.interval())
    return;
  m_undo.setInterval(ms);
  emit undoTimeChanged();
}

void Viewing::mark(const QString &itemId, int season, int episode, bool watched) {
  send("PUT", "/api/v1/progress/" + Core::segment(itemId),
       QJsonObject{{"season", season}, {"episode", episode}, {"watched", watched}}, itemId, "mark");
}

void Viewing::markThrough(const QString &itemId, int season, int episode) {
  QJsonObject body;
  if (season >= 0)
    body = {{"season", season}, {"episode", episode}};
  send("POST", "/api/v1/progress/" + Core::segment(itemId) + "/watched-through", body, itemId,
       "mark");
}

void Viewing::hide(const QString &itemId) {
  send("DELETE", "/api/v1/continue/" + Core::segment(itemId), QJsonValue::Undefined, itemId,
       "hide");
}

void Viewing::forget(const QString &itemId) {
  commit();
  m_forgetting = itemId;
  m_undo.start();
  emit forgettingChanged();
}

void Viewing::undo() {
  if (m_forgetting.isEmpty())
    return;
  m_undo.stop();
  m_forgetting.clear();
  emit forgettingChanged();
}

void Viewing::commit() {
  if (m_forgetting.isEmpty())
    return;
  m_undo.stop();
  const QString itemId = m_forgetting;
  m_forgetting.clear();
  emit forgettingChanged();
  send("DELETE", "/api/v1/progress/" + Core::segment(itemId), QJsonValue::Undefined, itemId,
       "forget");
}

void Viewing::send(const QByteArray &method, const QString &path, const QJsonValue &body,
                   const QString &itemId, const QString &what) {
  m_core->send(method, path, {}, body, this, [this, itemId, what](const Core::Reply &reply) {
    if (reply.ok())
      emit changed(itemId);
    else
      emit refused(what);
  });
}
