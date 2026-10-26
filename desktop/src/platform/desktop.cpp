#include "desktop.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QSysInfo>

QString Desktop::system() const {
  return QSysInfo::prettyProductName() + ", " + QSysInfo::kernelType() + " " + QSysInfo::kernelVersion();
}

void Desktop::copy(const QString &text) const { QGuiApplication::clipboard()->setText(text); }
