#pragma once

#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// What the desktop gives the app beyond the window: the clipboard, and the
// system's name for a bug report.
class Desktop : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(QString system READ system CONSTANT)
  // Where mpv's log is, for a bug report.
  Q_PROPERTY(QString playerLog READ playerLog CONSTANT)

public:
  using QObject::QObject;

  QString system() const;
  QString playerLog() const;
  Q_INVOKABLE void copy(const QString &text) const;
};
