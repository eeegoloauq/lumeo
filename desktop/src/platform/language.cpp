#include "language.h"

#include <QCoreApplication>
#include <QDirIterator>
#include <QFileInfo>
#include <QTranslator>
#include <QVariantMap>

void installTranslations(const QLocale &locale) {
  static QTranslator *english = nullptr, *chosen = nullptr;
  for (QTranslator **installed : {&english, &chosen})
    if (*installed) {
      QCoreApplication::removeTranslator(*installed);
      delete std::exchange(*installed, nullptr);
    }
  english = new QTranslator(QCoreApplication::instance());
  if (english->load(":/i18n/lumeo_en.qm"))
    QCoreApplication::installTranslator(english);
  chosen = new QTranslator(QCoreApplication::instance());
  if (locale.language() != QLocale::English && chosen->load(locale, "lumeo", "_", ":/i18n"))
    QCoreApplication::installTranslator(chosen);
  else
    delete std::exchange(chosen, nullptr);
}

QVariantList interfaceLanguages() {
  QVariantList languages;
  QDirIterator files(":/i18n", {"lumeo_*.qm"});
  while (files.hasNext()) {
    const QString path = files.next();
    QTranslator translator;
    if (translator.load(path))
      languages.append(QVariantMap{
          {"code", QFileInfo(path).baseName().mid(6)},
          {"name", translator.translate(nullptr, "languageName")},
      });
  }
  std::sort(languages.begin(), languages.end(), [](const QVariant &a, const QVariant &b) {
    return a.toMap()["code"].toString() < b.toMap()["code"].toString();
  });
  return languages;
}
