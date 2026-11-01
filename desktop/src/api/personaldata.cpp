#include "personaldata.h"

#include "core.h"
#include "preferences.h"

#include <QFile>
#include <QJsonObject>
#include <QQmlEngine>
#include <QSaveFile>

PersonalData::PersonalData(Core *core, Preferences *preferences, QObject *parent)
    : QObject(parent), m_core(core), m_preferences(preferences) {}

void PersonalData::componentComplete() {
  QQmlEngine *qml = qmlEngine(this);
  m_core = qml->singletonInstance<Core *>("Lumeo", "Core");
  m_preferences = qml->singletonInstance<Preferences *>("Lumeo", "Preferences");
}

bool PersonalData::begin() {
  if (m_busy)
    return false;
  m_busy = true;
  m_error.clear();
  emit changed();
  return true;
}

void PersonalData::fail(const QString &why) {
  m_busy = false;
  m_error = why;
  emit changed();
}

void PersonalData::exportTo(const QString &path) {
  if (!begin())
    return;
  m_core->get("/api/v1/personal", {}, this, [this, path](const Core::Reply &reply) {
    if (!reply.ok()) {
      fail(reply.message());
      return;
    }
    // Whole or not at all: a file cut short by a full disk would be refused
    // by the import it was made for, long after.
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(reply.body) != reply.body.size() || !file.commit()) {
      fail(file.errorString());
      return;
    }
    m_busy = false;
    emit changed();
    emit exported();
  });
}

void PersonalData::importFrom(const QString &path) {
  if (!begin())
    return;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) {
    fail(file.errorString());
    return;
  }
  if (file.size() > largest) {
    fail(qtTrId("personalTooLarge"));
    return;
  }
  m_core->send("POST", "/api/v1/personal", {}, file.readAll(), this, [this](const Core::Reply &reply) {
    if (!reply.ok()) {
      fail(reply.message());
      return;
    }
    const QJsonObject counts = reply.json().toObject();
    int written = 0;
    // Titles are not entries: a title new to the catalogue comes with the
    // entries that brought it.
    for (const char *key : {"progress", "ratings", "list", "tracks", "searches", "preferences"})
      written += counts[key].toInt();
    // Screens read the core when they are shown; the preferences are held.
    if (counts["preferences"].toInt() > 0)
      m_preferences->load();
    m_busy = false;
    emit changed();
    emit imported(written);
  });
}
