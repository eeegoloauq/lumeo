#include "settings.h"

#include "folders.h"
#include "language.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>

LocalSettings::LocalSettings(const QString &path, QObject *parent)
    : QObject(parent), m_path(path), m_languages(interfaceLanguages()) {
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
  return new LocalSettings(Folders::config() + "/client.json");
}

double LocalSettings::volume() const {
  return std::clamp(m_values.value("volume").toDouble(100), 0.0, 100.0);
}

void LocalSettings::setVolume(double volume) { set("volume", volume); }

// A code no translation answers to any more is the system's choice.
QString LocalSettings::language() const {
  const QString code = m_values.value("language").toString();
  for (const QVariant &language : m_languages)
    if (language.toMap()["code"] == code)
      return code;
  return {};
}

void LocalSettings::setLanguage(const QString &code) {
  if (code == language())
    return;
  for (const QVariant &language : m_languages)
    if (language.toMap()["code"] == code) {
      set("language", code);
      emit languageChanged();
    }
}

static const QStringList listSorts = {"added", "title", "year", "rating"};

QString LocalSettings::listSort() const {
  const QString order = m_values.value("listSort").toString();
  return listSorts.contains(order) ? order : listSorts.first();
}

void LocalSettings::setListSort(const QString &order) {
  if (listSorts.contains(order))
    set("listSort", order);
}

void LocalSettings::clearFinished() {
  set("downloadsClearedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
}

bool LocalSettings::showsFinished(const QDateTime &finishedAt) const {
  const QDateTime cleared =
      QDateTime::fromString(m_values.value("downloadsClearedAt").toString(), Qt::ISODateWithMs);
  if (cleared.isValid() && finishedAt <= cleared)
    return false;
  return finishedAt.secsTo(QDateTime::currentDateTimeUtc()) < 24 * 3600;
}

QLocale LocalSettings::locale() const {
  return language().isEmpty() ? QLocale() : QLocale(language());
}

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

void LocalSettings::resetChoices() {
  const QString language = this->language();
  for (const char *key : {"timelinePreviews", "screenshotsDir", "language"})
    m_values.remove(key);
  emit changed();
  if (!language.isEmpty())
    emit languageChanged();
  m_save.start();
}
