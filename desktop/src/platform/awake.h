#pragma once

#include <QObject>
#include <QString>

// Keeps the screen on and the system awake while held. mpv's
// `stop-screensaver` belongs to a window of mpv's own, which a render API
// client has none of.
class Awake : public QObject {
  Q_OBJECT

public:
  using QObject::QObject;
  ~Awake() override { hold(false); }

  void hold(bool on);

private:
#ifdef Q_OS_LINUX
  void inhibit();
  static void close(const QString &request);

  // The portal's request that holds the inhibition, while it does.
  QString m_request;
  bool m_asking = false;
#endif
  bool m_held = false;
};
