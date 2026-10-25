#pragma once

#include <QLocale>

// Installs the interface's text for [locale], over English, so a message a
// translation lacks reads in English and a language with no translation
// gets English throughout (decisions/interface.md).
void installTranslations(const QLocale &locale);
