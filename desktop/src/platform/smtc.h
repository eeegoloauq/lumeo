#pragma once

#include "smtcnative.h"

#include <QObject>
#include <QString>
#include <limits>
#include <tuple>

class Playback;

class Smtc : public QObject {
public:
  explicit Smtc(Playback *playback);
  ~Smtc() override;

private:
  struct Dispatch;

  void schedule();
  void refresh();
  void closeSession();
  void buttonPressed(SmtcNative::Button button);

  Playback *m_playback;
  std::shared_ptr<Dispatch> m_dispatch;
  std::unique_ptr<SmtcNative> m_native;
  std::tuple<QString, QString, QString, int> m_metadata;
  std::tuple<bool, bool, bool> m_playbackState;
  double m_timelineSentAt = std::numeric_limits<double>::quiet_NaN();
  bool m_timelineChanged = true;
  bool m_attempted = false;
  bool m_queued = false;
};
