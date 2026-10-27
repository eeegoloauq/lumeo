#include "settings.h"

#include "folders.h"
#include "language.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonDocument>
#include <QSaveFile>

LocalSettings::LocalSettings(const QString &path, QObject *parent)
    : QObject(parent), m_path(path), m_languages(interfaceLanguages()) {
  QFile file(path);
  m_existed = file.exists();
  if (file.open(QIODevice::ReadOnly))
    m_values = QJsonDocument::fromJson(file.readAll()).object();
  m_startScale = textScale();
  m_save.setInterval(500);
  m_save.setSingleShot(true);
  connect(&m_save, &QTimer::timeout, this, &LocalSettings::write);
}

LocalSettings::~LocalSettings() {
  if (m_save.isActive())
    write();
}

LocalSettings *LocalSettings::create(QQmlEngine *, QJSEngine *) {
  return new LocalSettings(file());
}

QString LocalSettings::file() { return Folders::config() + "/client.json"; }

// The earlier client's choices, which scaled its text alone.
static const QHash<QString, double> textScales = {{"small", 0.9}, {"default", 1}, {"large", 1.15}};

// Read before the application exists, so not through an instance.
double LocalSettings::scaleIn(const QString &path) {
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly))
    return 1;
  return textScales.value(QJsonDocument::fromJson(file.readAll())["textScale"].toString(), 1);
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

QString LocalSettings::lastSeenVersion() const {
  if (!m_existed && !m_values.contains("lastSeenVersion"))
    return {};
  return m_values.value("lastSeenVersion").toString("");
}

QDateTime LocalSettings::updateDismissedAt() const {
  return QDateTime::fromString(m_values.value("updateDismissedAt").toString(), Qt::ISODateWithMs);
}

void LocalSettings::dismissUpdate(const QString &version) {
  m_values.insert("updateDismissedAt", QDateTime::currentDateTimeUtc().toString(Qt::ISODateWithMs));
  set("dismissedUpdate", version);
}

void LocalSettings::setBackground(bool on) {
  if (!on)
    m_values.remove("autostart");
  set("background", on);
}

void LocalSettings::setAutostart(bool on) {
  if (on)
    m_values.insert("background", true);
  set("autostart", on);
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

QString LocalSettings::textScale() const {
  const QString scale = m_values.value("textScale").toString();
  return textScales.contains(scale) ? scale : "default";
}

void LocalSettings::setTextScale(const QString &scale) {
  if (textScales.contains(scale))
    set("textScale", scale);
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
  for (const char *key : {"timelinePreviews", "screenshotsDir", "language", "background", "autostart", "textScale"})
    m_values.remove(key);
  emit changed();
  if (!language.isEmpty())
    emit languageChanged();
  m_save.start();
}
