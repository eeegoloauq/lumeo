#include "instance.h"

#include "folders.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QProcess>
#include <QQmlEngine>
#include <QStandardPaths>
#include <QUrl>

#ifdef Q_OS_WIN
#include <windows.h>
#else
#include <sys/stat.h>
#endif

namespace {

Instance *made = nullptr;

// One name per user's session.
QString serverName() {
#ifdef Q_OS_WIN
  return "dev.lumeo.lumeo-" + qEnvironmentVariable("USERNAME");
#else
  return QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) + "/dev.lumeo.lumeo";
#endif
}

// The file or link among the arguments, as the desktop entry's %U gives them:
// a path, a file:// address, or a lumeo:// link. A link is never taken for a
// file, whatever is in it.
QString targetOf(const QStringList &arguments) {
  for (const QString &argument : arguments.mid(1)) {
    const QUrl url(argument);
    if (url.scheme() == "lumeo")
      return argument;
    const QFileInfo file(url.isLocalFile() ? url.toLocalFile() : argument);
    if (!argument.startsWith("--") && file.isFile())
      return file.absoluteFilePath();
  }
  return {};
}

#ifndef Q_OS_WIN
// The binary on disk, told apart from one installed over it.
std::pair<quint64, quint64> identity(const QString &path) {
  struct stat s;
  if (stat(QFile::encodeName(path).constData(), &s) != 0)
    return {0, 0};
  return {s.st_dev, s.st_ino};
}
#endif

} // namespace

Instance::Instance(const QStringList &arguments, QObject *parent)
    : QObject(parent), m_target(targetOf(arguments)),
      m_background(arguments.contains("--background")) {
  if (!made)
    made = this;
}

Instance::~Instance() {
  if (made == this)
    made = nullptr;
}

Instance *Instance::create(QQmlEngine *, QJSEngine *) {
  if (made) {
    QQmlEngine::setObjectOwnership(made, QQmlEngine::CppOwnership);
    return made;
  }
  return new Instance({});
}

bool Instance::start() {
  const QString core = QCoreApplication::applicationDirPath() + "/lumeo-core"
#ifdef Q_OS_WIN
                       + ".exe"
#endif
      ;
  if (!QFileInfo(core).isExecutable())
    return true;
  const QString name = serverName();
  if (handOver(name))
    return false;
  if (!listen(name)) {
    // Another launch took the name between our two tries.
    if (handOver(name))
      return false;
    qWarning("could not listen on %s: %s", qPrintable(name), qPrintable(m_server->errorString()));
  }
  m_exe = QCoreApplication::applicationFilePath();
#ifndef Q_OS_WIN
  std::tie(m_exeDevice, m_exeInode) = identity(m_exe);
#endif
  startCore(core);
  return true;
}

// A login launch that finds the app running shows nothing extra
// (decisions/interface.md), so it says nothing; any other launch says what
// it opens, nothing being the window alone. Wayland lets a window come
// forward only with the token the desktop gave the launch, so that goes too.
bool Instance::handOver(const QString &name) const {
  QLocalSocket socket;
  socket.connectToServer(name);
  if (!socket.waitForConnected(1000))
    return false;
  if (!m_background) {
    const QJsonObject launch{{"target", m_target},
                             {"token", qEnvironmentVariable("XDG_ACTIVATION_TOKEN")}};
    socket.write(QJsonDocument(launch).toJson(QJsonDocument::Compact) + '\n');
    socket.waitForBytesWritten(1000);
  }
  socket.disconnectFromServer();
  if (socket.state() != QLocalSocket::UnconnectedState)
    socket.waitForDisconnected(1000);
  return true;
}

bool Instance::listen(const QString &name) {
  m_server = new QLocalServer(this);
  m_server->setSocketOptions(QLocalServer::UserAccessOption);
  if (!m_server->listen(name)) {
    if (m_server->serverError() != QAbstractSocket::AddressInUseError)
      return false;
    // Taken since we looked, or left by an instance that ended without
    // closing it: only one that answers is running.
    QLocalSocket probe;
    probe.connectToServer(name);
    if (probe.waitForConnected(1000))
      return false;
    QLocalServer::removeServer(name);
    if (!m_server->listen(name))
      return false;
  }
  connect(m_server, &QLocalServer::newConnection, this, [this] {
    while (QLocalSocket *socket = m_server->nextPendingConnection()) {
      connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
      connect(socket, &QLocalSocket::readyRead, this, [this, socket] {
        if (!socket->canReadLine())
          return;
        const QJsonObject launch = QJsonDocument::fromJson(socket->readLine()).object();
        socket->disconnectFromServer();
        const QString target = launch["target"].toString();
        // Qt's Wayland window reads it when asked to come forward.
        if (const QString token = launch["token"].toString(); !token.isEmpty())
          qputenv("XDG_ACTIVATION_TOKEN", token.toUtf8());
        if (isReplaced()) {
          m_relaunch = target;
          m_relaunching = true;
          emit replaced();
          return;
        }
        emit opened(target);
      });
    }
  });
  return true;
}

// Nothing is ever written to the core's stdin: it stops when the pipe
// closes, which the kernel does however this process ends, kill -9 included.
// Qt's end of the pipe is close-on-exec, so nothing started from here keeps
// the core alive after us.
void Instance::startCore(const QString &path) {
  m_core = new QProcess;
  QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
  environment.insert("LUMEO_EXIT_ON_STDIN_EOF", "1");
  m_core->setProcessEnvironment(environment);
#ifdef Q_OS_WIN
  // The core logs to stderr, and a GUI process has none to give it.
  const QString log = Folders::state() + "/core.log";
  QDir().mkpath(Folders::state());
  m_core->setStandardOutputFile(log, QIODevice::Append);
  m_core->setStandardErrorFile(log, QIODevice::Append);
  // Detached rather than windowless: the core gets no console at all, so no
  // console host runs beside it.
  m_core->setCreateProcessArgumentsModifier(
      [](QProcess::CreateProcessArguments *arguments) { arguments->flags |= DETACHED_PROCESS; });
#else
  m_core->setProcessChannelMode(QProcess::ForwardedChannels);
#endif
  connect(m_core, &QProcess::finished, this,
          [] { qWarning("lumeo-core stopped while the app was running"); });
  connect(m_core, &QProcess::errorOccurred, this, [this, path](QProcess::ProcessError error) {
    if (error == QProcess::FailedToStart)
      qWarning("could not start %s: %s", qPrintable(path), qPrintable(m_core->errorString()));
  });
  m_core->start(path, {});
}

void Instance::release() {
  if (!m_server)
    return;
  m_server->close();
  delete m_server;
  m_server = nullptr;
  if (m_relaunching && !QProcess::startDetached(m_exe, m_relaunch.isEmpty() ? QStringList() : QStringList{m_relaunch}))
    qWarning("could not start the new version");
}

// A package upgrade replaced the binary while this instance ran in the
// background: a launch is the person asking for the version now installed.
bool Instance::isReplaced() const {
#ifdef Q_OS_WIN
  return false;
#else
  return identity(m_exe) != std::pair{m_exeDevice, m_exeInode};
#endif
}
