#include "language.h"

#include <QCoreApplication>
#include <QTranslator>

void installTranslations(const QLocale &locale) {
  auto *english = new QTranslator(QCoreApplication::instance());
  if (english->load(":/i18n/lumeo_en.qm"))
    QCoreApplication::installTranslator(english);
  auto *chosen = new QTranslator(QCoreApplication::instance());
  if (locale.language() != QLocale::English && chosen->load(locale, "lumeo", "_", ":/i18n"))
    QCoreApplication::installTranslator(chosen);
  else
    delete chosen;
}
