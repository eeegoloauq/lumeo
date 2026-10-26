#pragma once

#include <QObject>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

class Core;
class Downloads;
class QQmlEngine;
class QJSEngine;

// What the app was handed to open, at start or by a later launch: a file on
// this machine ("Open with Lumeo"), which plays, or a lumeo:// title link,
// which only opens the title's page. Nothing plays, downloads or changes from
// a link, so a page that hands one over can do no more than a click.
class Opening : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON

public:
  Opening(Core *core, Downloads *downloads, QObject *parent = nullptr);
  static Opening *create(QQmlEngine *qml, QJSEngine *);

  Q_INVOKABLE void open(const QString &target);

signals:
  void title(const QVariantMap &item);
  // A file made a download, named by the title the core found for it, else
  // by the file's own name.
  void play(const QString &downloadId, const QString &name);
  // [what] could not be opened for [reason]; an empty reason is a link
  // naming no title.
  void failed(const QString &what, const QString &reason);

private:
  void openFile(const QString &path);
  void openLink(const QString &link);

  Core *m_core;
  Downloads *m_downloads;
};
