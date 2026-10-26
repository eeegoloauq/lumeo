#include "settings.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>

LocalSettings::LocalSettings(const QString &path, QObject *parent)
    : QObject(parent), m_path(path) {
  QFile file(path);
  if (file.open(QIODevice::ReadOnly))
    m_values = QJsonDocument::fromJson(file.readAll()).object();
  m_save.setInterval(500);
  m_save.setSingleShot(true);
  connect(&m_save, &QTimer::timeout, this, &LocalSettings::write);
}

LocalSettings::~LocalSettings() {
  if (m_save.isActive())
    write();
}

LocalSettings *LocalSettings::create(QQmlEngine *, QJSEngine *) {
  return new LocalSettings(configDir() + "/client.json");
}

QString LocalSettings::configDir() {
#ifdef Q_OS_WIN
  return qEnvironmentVariable("APPDATA") + "/Lumeo";
#else
  const QString xdg = qEnvironmentVariable("XDG_CONFIG_HOME");
  return (xdg.isEmpty() ? QDir::homePath() + "/.config" : xdg) + "/lumeo";
#endif
}

double LocalSettings::volume() const {
  return std::clamp(m_values.value("volume").toDouble(100), 0.0, 100.0);
}

void LocalSettings::setVolume(double volume) { set("volume", volume); }

void LocalSettings::set(const QString &key, const QJsonValue &value) {
  if (m_values.value(key) == value)
    return;
  m_values.insert(key, value);
  emit changed();
  m_save.start();
}

void LocalSettings::write() {
  m_save.stop();
  QDir().mkpath(QFileInfo(m_path).path());
  QSaveFile file(m_path);
  if (!file.open(QIODevice::WriteOnly) ||
      file.write(QJsonDocument(m_values).toJson(QJsonDocument::Compact)) < 0 || !file.commit())
    qWarning("settings: %s not written", qPrintable(m_path));
}
