#include "background.h"

#include "settings.h"

#include <QCoreApplication>
#include <QDir>
#include <QIcon>
#include <QMenu>
#include <QQmlEngine>
#include <QSaveFile>
#include <QSettings>
#include <QSystemTrayIcon>

#ifdef Q_OS_LINUX
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#endif

namespace {

Background *made = nullptr;

constexpr char appId[] = "dev.lumeo.lumeo";

#ifdef Q_OS_LINUX
constexpr char notifications[] = "org.freedesktop.Notifications";
constexpr char notificationsPath[] = "/org/freedesktop/Notifications";

// An Exec value as the desktop entry specification quotes it: inside double
// quotes, a backslash before ", `, $ and \, then the backslashes doubled again
// for the string itself, and % doubled for field codes.
QString quotedExec(const QString &path) {
  QString quoted = "\"";
  for (const QChar c : path) {
    if (c == '"' || c == '`' || c == '$')
      quoted += QString("\\\\") + c;
    else if (c == '\\')
      quoted += "\\\\\\\\";
    else if (c == '%')
      quoted += "%%";
    else
      quoted += c;
  }
  return quoted + "\"";
}
#endif

} // namespace

Background::Background(LocalSettings *settings, bool installed, QObject *parent)
    : QObject(parent), m_settings(settings), m_installed(installed) {
  if (!made)
    made = this;
  connect(settings, &LocalSettings::changed, this, &Background::configure);
  configure();
#ifdef Q_OS_LINUX
  QDBusConnection bus = QDBusConnection::sessionBus();
  bus.connect(notifications, notificationsPath, notifications, "ActionInvoked", this,
              SLOT(acted(uint, QString)));
  bus.connect(notifications, notificationsPath, notifications, "NotificationClosed", this,
              SLOT(closed(uint)));
#endif
}

Background::~Background() {
  withdraw();
  delete m_menu;
  if (made == this)
    made = nullptr;
}

Background *Background::create(QQmlEngine *qml, QJSEngine *) {
  if (made) {
    QQmlEngine::setObjectOwnership(made, QQmlEngine::CppOwnership);
    return made;
  }
  return new Background(qml->singletonInstance<LocalSettings *>("Lumeo", "LocalSettings"), false);
}

bool Background::enabled() const { return m_installed && m_settings->background(); }

void Background::retranslate() {
  if (!m_menu)
    return;
  const QList<QAction *> actions = m_menu->actions();
  actions[0]->setText(qtTrId("backgroundOpen"));
  actions[1]->setText(qtTrId("backgroundQuit"));
}

void Background::configure() {
  if (m_installed && m_autostart != m_settings->autostart()) {
    m_autostart = m_settings->autostart();
    setAutostart(m_autostart);
  }
  if (enabled() == m_enabled)
    return;
  m_enabled = enabled();
  emit enabledChanged();
  if (m_enabled && !m_tray) {
    m_menu = new QMenu;
    connect(m_menu->addAction(QString()), &QAction::triggered, this, &Background::show);
    connect(m_menu->addAction(QString()), &QAction::triggered, this, &Background::quit);
    retranslate();
    m_tray = new QSystemTrayIcon(
        QIcon::fromTheme(appId, QIcon(":/qt/qml/Lumeo/icons/lumeo.svg")), this);
    m_tray->setToolTip("Lumeo");
    m_tray->setContextMenu(m_menu);
    connect(m_tray, &QSystemTrayIcon::activated, this, [this](QSystemTrayIcon::ActivationReason why) {
      if (why == QSystemTrayIcon::Trigger)
        emit show();
    });
  }
  if (m_tray)
    m_tray->setVisible(m_enabled);
}

void Background::hidden() {
  if (!m_tray || !QSystemTrayIcon::isSystemTrayAvailable())
    notify();
}

void Background::shown() { withdraw(); }

// Written on every start, so the entry follows a copy that has moved.
void Background::setAutostart(bool on) {
  const QString self = QCoreApplication::applicationFilePath();
#ifdef Q_OS_WIN
  QSettings run("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                QSettings::NativeFormat);
  if (on)
    run.setValue("Lumeo", "\"" + QDir::toNativeSeparators(self) + "\" --background");
  else
    run.remove("Lumeo");
#else
  const QString dir = QDir(qEnvironmentVariable("XDG_CONFIG_HOME",
                                                QDir::homePath() + "/.config")).filePath("autostart");
  const QString path = dir + "/" + appId + ".desktop";
  if (!on) {
    QFile::remove(path);
    return;
  }
  // TryExec: an entry left behind by a removed copy is skipped, not run.
  const QString entry = QString("[Desktop Entry]\nType=Application\nName=Lumeo\nIcon=%1\n"
                                "TryExec=%2\nExec=%3 --background\n")
                            .arg(appId, self, quotedExec(self));
  QDir().mkpath(dir);
  QSaveFile file(path);
  if (!file.open(QIODevice::WriteOnly) || file.write(entry.toUtf8()) < 0 || !file.commit())
    qWarning("could not write %s", qPrintable(path));
#endif
}

// The one sign of the app where there is no tray to carry its icon: clicking
// it opens the window, its button quits.
void Background::notify() {
#ifdef Q_OS_LINUX
  QDBusMessage call =
      QDBusMessage::createMethodCall(notifications, notificationsPath, notifications, "Notify");
  call << QString("Lumeo") << m_notification << QString(appId) << qtTrId("backgroundRunning")
       << qtTrId("backgroundRunningBody")
       << QStringList{"default", qtTrId("backgroundOpen"), "quit", qtTrId("backgroundQuit")}
       << QVariantMap{{"desktop-entry", appId}, {"resident", true}} << -1;
  auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(call), this);
  connect(watcher, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
    const QDBusPendingReply<uint> reply = *w;
    if (reply.isValid())
      m_notification = reply.value();
    w->deleteLater();
  });
#endif
}

void Background::withdraw() {
#ifdef Q_OS_LINUX
  if (m_notification == 0)
    return;
  QDBusConnection::sessionBus().asyncCall(QDBusMessage::createMethodCall(
                                              notifications, notificationsPath, notifications,
                                              "CloseNotification")
                                          << m_notification);
  m_notification = 0;
#endif
}

void Background::acted(uint id, const QString &key) {
  if (id != m_notification)
    return;
  if (key == "quit")
    emit quit();
  else if (key == "default")
    emit show();
}

void Background::closed(uint id) {
  if (id == m_notification)
    m_notification = 0;
}
