#include "gamepad.h"

#include <QKeySequence>
#include <QWindow>
#include <QtTest>
#include <qpa/qwindowsysteminterface.h>

#include <SDL3/SDL.h>

namespace {

// The keys a window was given: +Return pressed, *Down repeated, -Esc let go.
class Window : public QWindow {
public:
  QStringList keys;

protected:
  void keyPressEvent(QKeyEvent *event) override {
    keys << (event->isAutoRepeat() ? "*" : "+") + QKeySequence(event->key()).toString();
  }
  void keyReleaseEvent(QKeyEvent *event) override {
    keys << "-" + QKeySequence(event->key()).toString();
  }
};

} // namespace

// Stands in for the MpvItem: what mpv would be sent.
class Player : public QObject {
  Q_OBJECT

public:
  QStringList sent;
  Q_INVOKABLE void gamepad(const QString &name, bool down) { sent << (down ? "+" : "-") + name; }
};

// A virtual pad of SDL's own, so no controller is needed.
class GamepadTest : public QObject {
  Q_OBJECT

  std::unique_ptr<Window> window;
  std::unique_ptr<Gamepad> pad;
  SDL_JoystickID id = 0;
  SDL_Joystick *joystick = nullptr;

  // SDL tells a virtual pad's change at its next update, and one undone
  // before it not at all.
  void hold(SDL_GamepadButton button, bool down) {
    SDL_SetJoystickVirtualButton(joystick, button, down);
    SDL_UpdateJoysticks();
  }
  void press(SDL_GamepadButton button) {
    hold(button, true);
    hold(button, false);
  }
  void push(SDL_GamepadAxis axis, Sint16 value) {
    SDL_SetJoystickVirtualAxis(joystick, axis, value);
    SDL_UpdateJoysticks();
  }

private slots:
  void init() {
    Gamepad::repeatDelay = 40;
    Gamepad::repeatInterval = 20;
    window = std::make_unique<Window>();
    window->show();
    window->requestActivate();
    QTRY_COMPARE(QGuiApplication::focusWindow(), window.get());
    pad = std::make_unique<Gamepad>();
    QTRY_VERIFY(SDL_WasInit(SDL_INIT_GAMEPAD));
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.axis_mask = (1u << SDL_GAMEPAD_AXIS_COUNT) - 1;
    desc.button_mask = (1u << SDL_GAMEPAD_BUTTON_COUNT) - 1;
    desc.name = "Test pad";
    id = SDL_AttachVirtualJoystick(&desc);
    QVERIFY2(id, SDL_GetError());
    joystick = SDL_OpenJoystick(id);
    QVERIFY(joystick);
    QTRY_VERIFY(pad->connected());
  }

  void cleanup() {
    SDL_CloseJoystick(joystick);
    SDL_DetachVirtualJoystick(id);
    pad.reset();
    window.reset();
  }

  void theFaceButtonsAndStartAreTheKeysTheWindowAnswers() {
    press(SDL_GAMEPAD_BUTTON_SOUTH);
    press(SDL_GAMEPAD_BUTTON_EAST);
    press(SDL_GAMEPAD_BUTTON_START);
    QTRY_COMPARE(window->keys, QStringList({"+Return", "-Return", "+Esc", "-Esc", "+Menu", "-Menu"}));
  }

  void aHeldArrowRepeatsAsAKeyboardsDoes() {
    hold(SDL_GAMEPAD_BUTTON_DPAD_DOWN, true);
    QTRY_VERIFY(window->keys.count("*Down") >= 2);
    hold(SDL_GAMEPAD_BUTTON_DPAD_DOWN, false);
    QTRY_COMPARE(window->keys.last(), "-Down");
    QCOMPARE(window->keys.first(), "+Down");
  }

  // Pushed half way, not grazed; let go of nearer the middle.
  void theLeftStickIsTheArrows() {
    push(SDL_GAMEPAD_AXIS_LEFTX, 10000);
    push(SDL_GAMEPAD_AXIS_LEFTX, 30000);
    push(SDL_GAMEPAD_AXIS_LEFTX, 12000);
    push(SDL_GAMEPAD_AXIS_LEFTX, 0);
    push(SDL_GAMEPAD_AXIS_LEFTY, -30000);
    push(SDL_GAMEPAD_AXIS_LEFTY, 0);
    QTRY_COMPARE(window->keys.filter(QRegularExpression("^[+-]")),
                 QStringList({"+Right", "-Right", "+Up", "-Up"}));
  }

  // SDL sees the pad whatever has the focus; a game in front of us is not
  // driving us.
  void nothingReachesUsWhileAnotherWindowIsActive() {
    // As the window system says another program's window took the focus.
    QWindowSystemInterface::handleFocusWindowChanged(nullptr);
    QTRY_VERIFY(!QGuiApplication::focusWindow());
    press(SDL_GAMEPAD_BUTTON_SOUTH);
    QWindowSystemInterface::handleFocusWindowChanged(window.get());
    QTRY_COMPARE(QGuiApplication::focusWindow(), window.get());
    press(SDL_GAMEPAD_BUTTON_EAST);
    QTRY_COMPARE(window->keys, QStringList({"+Esc", "-Esc"}));
  }

  // The player holding the keyboard has the pad too, by mpv's names, and
  // what it held is let go of there when it gives the pad up.
  void thePlayerIsSentMpvsNames() {
    Player player;
    pad->setPlayer(&player);
    press(SDL_GAMEPAD_BUTTON_SOUTH);
    push(SDL_GAMEPAD_AXIS_LEFTY, -30000);
    QTRY_COMPARE(player.sent, QStringList({"+ACTION_DOWN", "-ACTION_DOWN", "+LEFT_STICK_UP"}));
    pad->setPlayer(nullptr);
    QCOMPARE(player.sent.last(), "-LEFT_STICK_UP");
    QVERIFY(window->keys.isEmpty());
  }
};

QTEST_MAIN(GamepadTest)
#include "gamepad_test.moc"
