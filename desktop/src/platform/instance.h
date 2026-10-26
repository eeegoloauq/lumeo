#pragma once

#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

class QLocalServer;
class QProcess;
class QQmlEngine;
class QJSEngine;

// The app as one instance per session, owning its core
// (decisions/shipping.md). The first launch starts the lumeo-core beside its
// binary as a child holding its stdin, and listens; a later launch hands it
// its file or link and exits. A build with no core beside it starts none and
// stays non-unique: it talks to whatever answers, a dev core started by hand
// included, and runs beside an installed copy.
class Instance : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // Started by the login entry: the window stays hidden.
  Q_PROPERTY(bool background READ background CONSTANT)

public:
  explicit Instance(const QStringList &arguments, QObject *parent = nullptr);
  ~Instance() override;
  // The one main() made, or one that only reads its arguments, for tests.
  static Instance *create(QQmlEngine *, QJSEngine *);

  // Takes this session's name and starts the core, when there is one beside
  // the binary. False when an instance was running and took this launch
  // over: exit at once.
  bool start();
  bool background() const { return m_background; }
  // What the launch asked to open: a file, as an absolute path, or a
  // lumeo:// link; empty for neither.
  Q_INVOKABLE QString target() const { return m_target; }

  // The last window is gone: a launch from now on starts its own instance,
  // whose core waits for this one's to let go of the data directory, rather
  // than handing its file to a process past handling it.
  void release();

signals:
  // A later launch: the window comes forward, with [target] to open.
  void opened(const QString &target);
  // The binary on disk is a newer install: the app should close as it
  // always does, and the new version starts once the name is released.
  void replaced();

private:
  bool handOver(const QString &name) const;
  bool listen(const QString &name);
  void startCore(const QString &path);
  bool isReplaced() const;

  QString m_target;
  bool m_background = false;
  QLocalServer *m_server = nullptr;
  // Never deleted: QProcess kills its child when destroyed, and the core is
  // to stop when the kernel closes its stdin with this process, after it
  // has finished what it was writing.
  QProcess *m_core = nullptr;
  QString m_exe;
  quint64 m_exeDevice = 0;
  quint64 m_exeInode = 0;
  // A launch that met an older install, started again once released.
  QString m_relaunch;
  bool m_relaunching = false;
};
