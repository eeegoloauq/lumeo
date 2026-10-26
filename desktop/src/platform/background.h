#pragma once

#include <QObject>
#include <QtQml/qqmlregistration.h>

class LocalSettings;
class QMenu;
class QSystemTrayIcon;
class QQmlEngine;
class QJSEngine;

// The app running with its window hidden (decisions/interface.md): a tray
// icon where the desktop shows one, a notification standing in for it where
// it does not (stock GNOME), and the login entry that starts the app hidden.
class Background : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  // This copy owns its core: a build without one quits when closed, since
  // another launch of it would not bring this one back.
  Q_PROPERTY(bool available READ available CONSTANT)
  // Closing the window hides it.
  Q_PROPERTY(bool enabled READ enabled NOTIFY enabledChanged)

public:
  // [installed]: this copy owns its core, so the login entry may start it.
  Background(LocalSettings *settings, bool installed, QObject *parent = nullptr);
  ~Background() override;
  // The one main() made, or one with no tray and no login entry, for tests.
  static Background *create(QQmlEngine *qml, QJSEngine *);

  bool available() const { return m_installed; }
  bool enabled() const;

  // The window was closed into the background, or started there.
  Q_INVOKABLE void hidden();
  // The window is back: the notification standing in for it goes.
  Q_INVOKABLE void shown();
  // The words, after the interface's language changed.
  void retranslate();

signals:
  void show();
  void quit();
  void enabledChanged();

private slots:
  void acted(uint id, const QString &key);
  void closed(uint id);

private:
  void configure();
  void setAutostart(bool on);
  void notify();
  void withdraw();

  LocalSettings *m_settings;
  bool m_installed;
  bool m_enabled = false;
  // The login entry as last written: -1 before the first.
  int m_autostart = -1;
  // Made with the first tray: a QMenu needs the app's QApplication, which
  // tests have none of.
  QSystemTrayIcon *m_tray = nullptr;
  QMenu *m_menu = nullptr;
  // The notification on screen, 0 for none.
  uint m_notification = 0;
};
