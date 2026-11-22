#pragma once

#include <functional>
#include <memory>
#include <string_view>

class SmtcNative {
public:
  enum class Button { Play, Pause, Stop, Next, Previous };
  using ButtonHandler = std::function<void(Button)>;
  using SeekHandler = std::function<void(double)>;

  SmtcNative(void *window, ButtonHandler button, SeekHandler seek);
  ~SmtcNative();

  bool ready() const;
  long error() const;
  bool enable();
  void setPlayback(bool paused, bool canNext, bool canPrevious);
  void setMetadata(std::wstring_view title, std::wstring_view series, std::wstring_view poster);
  void setTimeline(double duration, double position, double rate, bool seekable);

private:
  struct State;
  std::unique_ptr<State> m_state;
};
