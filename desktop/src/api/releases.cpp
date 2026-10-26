#include "releases.h"

#include "core.h"
#include "settings.h"

#include <QCoreApplication>
#include <QFile>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QXmlStreamReader>
#include <optional>

namespace {

// A release ranks above all its betas.
constexpr int release = 1 << 30;

// "0.1.79", "0.1.79-beta.3" or "0.1.79~beta.3" as four numbers.
std::optional<std::array<int, 4>> parsed(const QString &text) {
  static const QRegularExpression form(R"(^(\d+)\.(\d+)\.(\d+)(?:[-~]beta\.(\d+))?$)");
  const QRegularExpressionMatch match = form.match(text);
  if (!match.hasMatch())
    return std::nullopt;
  return std::array<int, 4>{match.captured(1).toInt(), match.captured(2).toInt(),
                            match.captured(3).toInt(),
                            match.hasCaptured(4) ? match.captured(4).toInt() : release};
}

bool isBeta(const std::array<int, 4> &version) { return version[3] != release; }

} // namespace

Releases::Releases(Core *core, LocalSettings *settings, const QString &version,
                   const QString &bundled, QObject *parent)
    : QObject(parent), m_core(core), m_settings(settings), m_version(version), m_bundled(bundled) {
  // A first run has nothing to compare with: its notes are not news.
  if (settings->lastSeenVersion().isNull())
    settings->setLastSeenVersion(version);
}

Releases *Releases::create(QQmlEngine *qml, QJSEngine *) {
  QFile file(":/qt/qml/Lumeo/dev.lumeo.lumeo.metainfo.xml");
  file.open(QIODevice::ReadOnly);
  return new Releases(qml->singletonInstance<Core *>("Lumeo", "Core"),
                      qml->singletonInstance<LocalSettings *>("Lumeo", "LocalSettings"),
                      QCoreApplication::applicationVersion(), QString::fromUtf8(file.readAll()));
}

QStringList Releases::news() const {
  const QString seen = m_settings->lastSeenVersion();
  return seen == m_version ? QStringList() : between(m_bundled, seen, m_version, m_language);
}

bool Releases::newsTold() const {
  return toldInBetas(m_settings->lastSeenVersion(), m_version) ||
         m_settings->dismissedUpdate() == m_version;
}

void Releases::check() {
  m_core->get("/api/v1/update", {}, this, [this](const Core::Reply &reply) {
    if (reply.status != 200)
      return;
    const QString version = reply.json()["version"].toString();
    if (version == m_settings->dismissedUpdate())
      return;
    const QDateTime dismissed = m_settings->updateDismissedAt();
    if (dismissed.isValid() && dismissed.daysTo(QDateTime::currentDateTimeUtc()) < quietDays)
      return;
    m_update = version;
    m_updateUrl = reply.json()["url"].toString();
    m_updateSource = reply.json()["notes"].toString();
    emit changed();
  });
}

void Releases::dismissUpdate() {
  m_settings->dismissUpdate(m_update);
  m_update.clear();
  seen();
}

void Releases::seen() {
  m_settings->setLastSeenVersion(m_version);
  emit changed();
}

void Releases::setLanguage(const QString &language) {
  if (language == m_language)
    return;
  m_language = language;
  emit changed();
}

QStringList Releases::between(const QString &source, const QString &after, const QString &through,
                              const QString &language) {
  const auto last = parsed(through);
  if (!last)
    return {};
  const auto first = parsed(after);
  QStringList items;
  // One release's items: the translated ones, else the untagged.
  QStringList own, translated;
  bool counted = false;
  QXmlStreamReader xml(source);
  while (!xml.atEnd()) {
    xml.readNext();
    if (xml.isStartElement() && xml.name() == u"release") {
      const auto v = parsed(xml.attributes().value("version").toString());
      counted = v && (isBeta(*last) || !isBeta(*v)) && *v <= *last &&
                (first ? *v > *first : *v == *last);
      own.clear();
      translated.clear();
    } else if (counted && xml.isStartElement() && xml.name() == u"li") {
      const QString lang = xml.attributes().value("xml:lang").toString();
      const QString text = xml.readElementText(QXmlStreamReader::IncludeChildElements).simplified();
      if (lang.isEmpty())
        own.append(text);
      else if (lang == language)
        translated.append(text);
    } else if (xml.isEndElement() && xml.name() == u"release" && counted) {
      items += translated.isEmpty() ? own : translated;
      counted = false;
    }
  }
  return items;
}

bool Releases::toldInBetas(const QString &seen, const QString &version) {
  const auto a = parsed(seen), b = parsed(version);
  return a && b && isBeta(*a) && !isBeta(*b) && (*a)[0] == (*b)[0] && (*a)[1] == (*b)[1] &&
         (*a)[2] == (*b)[2];
}
