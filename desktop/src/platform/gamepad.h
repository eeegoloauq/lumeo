#pragma once

#include <QHash>
#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QWindow>
#include <QtQml/qqmlregistration.h>

class QQmlEngine;
class QJSEngine;

// A game controller, through SDL3's gamepad API alone, as the keys the
// window already answers (decisions/interface.md, Gamepad): the D-pad and
// the left stick are the arrows, the bottom face button Enter, the right one
// Esc, Start the Menu key. Only while one of our windows is active: SDL sees
// the pad whatever has the focus, and a game in front must not drive us.
//
// While the player holds the keyboard, as every key goes to mpv then, the
// pad goes to it too, as mpv's GAMEPAD_* keys, which our own bindings give
// meaning to (MpvFacts::ownBindings).
class Gamepad : public QObject {
  Q_OBJECT
  QML_ELEMENT
  QML_SINGLETON
  Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
  // The MpvItem the pad is for, or null for the window's keys.
  Q_PROPERTY(QObject *player READ player WRITE setPlayer NOTIFY playerChanged)

public:
  explicit Gamepad(QObject *parent = nullptr);
  ~Gamepad() override;
  static Gamepad *create(QQmlEngine *, QJSEngine *);
  static Gamepad *instance();

  bool connected() const { return !m_pads.isEmpty(); }
  QObject *player() const { return m_player; }
  void setPlayer(QObject *player);

  // A held arrow repeats after the first pause, then at the second, as a
  // keyboard's does; mpv repeats its own. In milliseconds; tests shorten them.
  static int repeatDelay;
  static int repeatInterval;

signals:
  void connectedChanged();
  void playerChanged();

private:
  // Where a press went, so that its release goes there too.
  struct Held {
    QPointer<QObject> player;
    QPointer<QWindow> window;
    int key = 0;
  };

  void start();
  void poll(bool active);
  // [name] is mpv's, without its GAMEPAD_ prefix.
  void input(const QString &name, bool down);
  void stick(int axis, int value);
  void repeat();
  void releaseAll();
  void key(QWindow *window, QEvent::Type type, int key, bool autoRepeat);
  void pace();

  bool m_started = false;
  QTimer m_poll;
  QTimer m_repeat;
  // SDL_JoystickID to SDL_Gamepad *.
  QHash<quint32, void *> m_pads;
  QHash<QString, Held> m_held;
  QString m_repeating;
  QPointer<QObject> m_player;
  // The left stick, -1, 0 or 1 on each axis.
  int m_x = 0;
  int m_y = 0;
};
