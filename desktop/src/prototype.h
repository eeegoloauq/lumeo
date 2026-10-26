#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

class Core;
class QQmlEngine;
class QJSEngine;

// The prototype's way to a film: a file on this machine made a download. It
// goes when step 4 of docs/qt-port.md hands files and links to the app.
class Prototype : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON

public:
  explicit Prototype(Core *core, QObject *parent = nullptr);
  static Prototype *create(QQmlEngine *qml, QJSEngine *);

  Q_INVOKABLE void openLocal(const QString &path);

signals:
  // A download to play, named as the player should say it until the core does.
  void started(const QString &downloadId, const QString &name);

private:
  Core *m_core;
};
