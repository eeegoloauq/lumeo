#include "awake.h"

#include <utility>

#ifdef Q_OS_WIN
#include <windows.h>
#endif
#ifdef Q_OS_LINUX
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QPointer>
#endif

namespace {

#ifdef Q_OS_LINUX
constexpr char portal[] = "org.freedesktop.portal.Desktop";
constexpr char portalPath[] = "/org/freedesktop/portal/desktop";
// Inhibit's flag for the session going idle: the screen blanking and the
// suspend after it.
constexpr uint idle = 8;
#endif

} // namespace

void Awake::hold(bool on) {
  if (on == m_held)
    return;
  m_held = on;
#ifdef Q_OS_WIN
  // The thread's state, so set and cleared on the same one.
  SetThreadExecutionState(on ? ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
                             : ES_CONTINUOUS);
#elif defined(Q_OS_LINUX)
  if (on)
    inhibit();
  else if (!m_request.isEmpty()) {
    close(m_request);
    m_request.clear();
  }
#endif
}

#ifdef Q_OS_LINUX
// The portal, not a desktop's own screensaver interface: GNOME, KDE and a
// sandbox all answer it. Asked without waiting; a release that comes first
// closes the request as it arrives.
void Awake::inhibit() {
  if (m_asking || !m_request.isEmpty())
    return;
  m_asking = true;
  QDBusMessage call =
      QDBusMessage::createMethodCall(portal, portalPath, "org.freedesktop.portal.Inhibit", "Inhibit");
  call << QString() << idle << QVariantMap();
  // Not a child: a player closed before the answer still closes what it
  // asked for.
  auto *watcher = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(call));
  connect(watcher, &QDBusPendingCallWatcher::finished, watcher,
          [self = QPointer(this)](QDBusPendingCallWatcher *watcher) {
            watcher->deleteLater();
            const QDBusPendingReply<QDBusObjectPath> reply = *watcher;
            if (self)
              self->m_asking = false;
            if (reply.isError()) {
              // Once: a desktop without the portal says so on every film.
              static bool said = false;
              if (!std::exchange(said, true))
                qWarning("awake: no inhibition: %s", qPrintable(reply.error().message()));
              return;
            }
            if (self && self->m_held)
              self->m_request = reply.value().path();
            else
              close(reply.value().path());
          });
}

void Awake::close(const QString &request) {
  QDBusConnection::sessionBus().asyncCall(
      QDBusMessage::createMethodCall(portal, request, "org.freedesktop.portal.Request", "Close"));
}
#endif
