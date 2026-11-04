#include "gamepad.h"

#include <QGuiApplication>
#include <QJSEngine>
#include <QLoggingCategory>
#include <qpa/qwindowsysteminterface.h>

#include <SDL3/SDL.h>

int Gamepad::repeatDelay = 400;
int Gamepad::repeatInterval = 60;

namespace {

Q_LOGGING_CATEGORY(lc, "lumeo.gamepad")

// SDL's buttons by mpv's names; the guide button is the system's, or
// Steam's, and has no mpv name.
const QHash<int, QString> buttons{
    {SDL_GAMEPAD_BUTTON_SOUTH, "ACTION_DOWN"},
    {SDL_GAMEPAD_BUTTON_EAST, "ACTION_RIGHT"},
    {SDL_GAMEPAD_BUTTON_WEST, "ACTION_LEFT"},
    {SDL_GAMEPAD_BUTTON_NORTH, "ACTION_UP"},
    {SDL_GAMEPAD_BUTTON_BACK, "BACK"},
    {SDL_GAMEPAD_BUTTON_START, "START"},
    {SDL_GAMEPAD_BUTTON_LEFT_STICK, "LEFT_STICK"},
    {SDL_GAMEPAD_BUTTON_RIGHT_STICK, "RIGHT_STICK"},
    {SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, "LEFT_SHOULDER"},
    {SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, "RIGHT_SHOULDER"},
    {SDL_GAMEPAD_BUTTON_DPAD_UP, "DPAD_UP"},
    {SDL_GAMEPAD_BUTTON_DPAD_DOWN, "DPAD_DOWN"},
    {SDL_GAMEPAD_BUTTON_DPAD_LEFT, "DPAD_LEFT"},
    {SDL_GAMEPAD_BUTTON_DPAD_RIGHT, "DPAD_RIGHT"},
};

// The keys the window answers, by the pad's names. The rest of the pad
// reaches the player only.
const QHash<QString, int> keys{
    {"DPAD_UP", Qt::Key_Up},          {"DPAD_DOWN", Qt::Key_Down},
    {"DPAD_LEFT", Qt::Key_Left},      {"DPAD_RIGHT", Qt::Key_Right},
    {"LEFT_STICK_UP", Qt::Key_Up},    {"LEFT_STICK_DOWN", Qt::Key_Down},
    {"LEFT_STICK_LEFT", Qt::Key_Left}, {"LEFT_STICK_RIGHT", Qt::Key_Right},
    {"ACTION_DOWN", Qt::Key_Return},  {"ACTION_RIGHT", Qt::Key_Escape},
    {"START", Qt::Key_Menu},
};

bool arrow(int key) { return key >= Qt::Key_Left && key <= Qt::Key_Down; }

// Half way out is a direction, and it is let go of nearer the middle, so a
// thumb resting on the line does not flicker it.
constexpr int pushed = 16384;
constexpr int letGo = 8192;

int direction(int was, int value) {
  if (value >= pushed || (was > 0 && value > letGo))
    return 1;
  if (value <= -pushed || (was < 0 && value < -letGo))
    return -1;
  return 0;
}

// The pump is quick while a pad is there to be read, and slow otherwise,
// for one being plugged in.
constexpr int reading = 8;
constexpr int waiting = 500;

Gamepad *made = nullptr;

} // namespace

Gamepad::Gamepad(QObject *parent) : QObject(parent) {
  connect(&m_poll, &QTimer::timeout, this, [this] { poll(QGuiApplication::focusWindow()); });
  m_repeat.setSingleShot(true);
  connect(&m_repeat, &QTimer::timeout, this, &Gamepad::repeat);
  // What was held when the window lost the keyboard is let go of there, and
  // what was pressed meanwhile, still queued, is not for us.
  connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, [this](QWindow *window) {
    if (!window)
      releaseAll();
    else if (m_started)
      poll(false);
    pace();
  });
  // Not in the way of the first frame.
  QTimer::singleShot(0, this, &Gamepad::start);
}

Gamepad::~Gamepad() {
  if (made == this)
    made = nullptr;
  if (!m_started)
    return;
  for (void *pad : std::as_const(m_pads))
    SDL_CloseGamepad(static_cast<SDL_Gamepad *>(pad));
  SDL_QuitSubSystem(SDL_INIT_GAMEPAD);
}

Gamepad *Gamepad::instance() {
  if (!made)
    made = new Gamepad(QCoreApplication::instance());
  return made;
}

Gamepad *Gamepad::create(QQmlEngine *, QJSEngine *) {
  Gamepad *pad = instance();
  QJSEngine::setObjectOwnership(pad, QJSEngine::CppOwnership);
  return pad;
}

void Gamepad::start() {
  // SDL drops a pad's events while none of its own windows has the focus,
  // and it has none: whether ours is active is decided here.
  SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
  if (!SDL_InitSubSystem(SDL_INIT_GAMEPAD)) {
    qCWarning(lc, "no gamepads: %s", SDL_GetError());
    return;
  }
  m_started = true;
  pace();
  m_poll.start();
}

void Gamepad::pace() {
  m_poll.setInterval(!m_pads.isEmpty() && QGuiApplication::focusWindow() ? reading : waiting);
}

void Gamepad::setPlayer(QObject *player) {
  if (m_player == player)
    return;
  releaseAll();
  m_player = player;
  emit playerChanged();
}

// Presses made while another program had the focus are not for us.
void Gamepad::poll(bool active) {
  SDL_Event event;
  while (SDL_PollEvent(&event)) {
    switch (event.type) {
    case SDL_EVENT_GAMEPAD_ADDED:
      if (SDL_Gamepad *pad = SDL_OpenGamepad(event.gdevice.which)) {
        m_pads.insert(event.gdevice.which, pad);
        qCInfo(lc, "connected: %s", SDL_GetGamepadName(pad));
        pace();
        emit connectedChanged();
      }
      break;
    case SDL_EVENT_GAMEPAD_REMOVED:
      if (void *pad = m_pads.take(event.gdevice.which)) {
        SDL_CloseGamepad(static_cast<SDL_Gamepad *>(pad));
        if (m_pads.isEmpty())
          releaseAll();
        pace();
        emit connectedChanged();
      }
      break;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
    case SDL_EVENT_GAMEPAD_BUTTON_UP:
      if (buttons.contains(event.gbutton.button) && (active || !event.gbutton.down))
        input(buttons.value(event.gbutton.button), event.gbutton.down);
      break;
    case SDL_EVENT_GAMEPAD_AXIS_MOTION:
      if (active || event.gaxis.value == 0)
        stick(event.gaxis.axis, event.gaxis.value);
      break;
    default:
      break;
    }
  }
}

void Gamepad::stick(int axis, int value) {
  if (axis != SDL_GAMEPAD_AXIS_LEFTX && axis != SDL_GAMEPAD_AXIS_LEFTY)
    return;
  int &was = axis == SDL_GAMEPAD_AXIS_LEFTX ? m_x : m_y;
  const int now = direction(was, value);
  if (now == was)
    return;
  const QString less = axis == SDL_GAMEPAD_AXIS_LEFTX ? "LEFT_STICK_LEFT" : "LEFT_STICK_UP";
  const QString more = axis == SDL_GAMEPAD_AXIS_LEFTX ? "LEFT_STICK_RIGHT" : "LEFT_STICK_DOWN";
  if (was)
    input(was < 0 ? less : more, false);
  was = now;
  if (now)
    input(now < 0 ? less : more, true);
}

void Gamepad::input(const QString &name, bool down) {
  if (!down) {
    if (!m_held.contains(name))
      return;
    const Held held = m_held.take(name);
    if (m_repeating == name) {
      m_repeating.clear();
      m_repeat.stop();
    }
    if (held.player)
      QMetaObject::invokeMethod(held.player, "gamepad", Q_ARG(QString, name), Q_ARG(bool, false));
    else if (held.window)
      key(held.window, QEvent::KeyRelease, held.key, false);
    return;
  }
  if (m_held.contains(name))
    return;
  if (m_player) {
    m_held.insert(name, {m_player, nullptr, 0});
    QMetaObject::invokeMethod(m_player, "gamepad", Q_ARG(QString, name), Q_ARG(bool, true));
    return;
  }
  QWindow *window = QGuiApplication::focusWindow();
  const int qtKey = keys.value(name);
  if (!window || !qtKey)
    return;
  m_held.insert(name, {nullptr, window, qtKey});
  key(window, QEvent::KeyPress, qtKey, false);
  if (arrow(qtKey)) {
    m_repeating = name;
    m_repeat.start(repeatDelay);
  }
}

void Gamepad::repeat() {
  const Held held = m_held.value(m_repeating);
  if (!held.window)
    return;
  key(held.window, QEvent::KeyPress, held.key, true);
  m_repeat.start(repeatInterval);
}

void Gamepad::releaseAll() {
  for (const QString &name : m_held.keys())
    input(name, false);
  m_x = m_y = 0;
}

// Through the window system's way in, as a keyboard's key comes: a shortcut
// (Esc for Back) is matched on that way only.
void Gamepad::key(QWindow *window, QEvent::Type type, int key, bool autoRepeat) {
  const QString text = key == Qt::Key_Return ? QStringLiteral("\r")
                       : key == Qt::Key_Escape ? QStringLiteral("\x1b")
                                               : QString();
  QWindowSystemInterface::handleKeyEvent(window, type, key, Qt::NoModifier, text, autoRepeat);
}
