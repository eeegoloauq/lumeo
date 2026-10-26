#include "desktop.h"

#include "folders.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QSysInfo>

QString Desktop::system() const {
  return QSysInfo::prettyProductName() + ", " + QSysInfo::kernelType() + " " + QSysInfo::kernelVersion();
}

QString Desktop::playerLog() const { return Folders::playerLog(); }

void Desktop::copy(const QString &text) const { QGuiApplication::clipboard()->setText(text); }
