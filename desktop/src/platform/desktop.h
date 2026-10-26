#pragma once

#include <QJSValue>
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

// What the desktop gives the app beyond the window: the clipboard, the
// system's file dialogs, and the system's name for a bug report.
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
  // The system's dialog for a folder, or a file; [done] gets the local path
  // chosen, and is not called on cancel. Not QtQuick.Dialogs: its fallback
  // dialog comes as a copy for every Qt style, five of them in the bundle.
  Q_INVOKABLE void pickFolder(const QString &title, const QString &start, const QJSValue &done) const;
  Q_INVOKABLE void pickFile(const QString &title, const QJSValue &done) const;
};
