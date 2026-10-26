#include "prototype.h"

#include "core.h"

#include <QFileInfo>
#include <QJsonObject>
#include <QQmlEngine>

Prototype::Prototype(Core *core, QObject *parent) : QObject(parent), m_core(core) {}

Prototype *Prototype::create(QQmlEngine *qml, QJSEngine *) {
  return new Prototype(qml->singletonInstance<Core *>("Lumeo", "Core"));
}

void Prototype::openLocal(const QString &path) {
  m_core->send("POST", "/api/v1/local", {}, QJsonObject{{"path", path}}, this,
               [this, path](const Core::Reply &reply) {
                 if (!reply.ok()) {
                   qWarning("could not open %s: %s", qPrintable(path), qPrintable(reply.message()));
                   return;
                 }
                 emit started(reply.json()["id"].toString(), QFileInfo(path).fileName());
               });
}
