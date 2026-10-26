#pragma once

#include <QLocale>
#include <QVariantList>

// Installs the interface's text for [locale], over English, so a message a
// translation lacks reads in English and a language with no translation
// gets English throughout (decisions/interface.md). A later call replaces
// what an earlier one installed.
void installTranslations(const QLocale &locale);

// The languages there is a translation for, as {code, name}, each named in
// itself: the list is the translations shipped, so a new one appears by
// being added.
QVariantList interfaceLanguages();
