#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "win32_window.h"

// WM_COPYDATA from a second launch: the file it was asked to open, as a
// null-terminated UTF-16 path, or nothing.
constexpr ULONG_PTR kOpenFileCopyData = 1;

// The toplevel window: a Flutter view with the client's own title bar, and
// the channels the Linux runner has too (dev.lumeo/window, dev.lumeo/open),
// plus dev.lumeo/shell for what lib/platform/folders.dart asks of Windows.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Hands the window the handle that makes this the running instance, to be
  // closed when the window goes rather than when the process exits.
  void HoldInstance(HANDLE instance) { instance_ = instance; }

  // Set before Create: a --background launch shows no window until asked,
  // and only a copy that owns its core may be what starts at login.
  void SetLaunch(bool start_hidden, bool owns_core) {
    start_hidden_ = start_hidden;
    awaiting_settings_ = start_hidden;
    owns_core_ = owns_core;
  }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  using Channel = flutter::MethodChannel<flutter::EncodableValue>;
  using Call = flutter::MethodCall<flutter::EncodableValue>;
  using Result =
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void OnWindowCall(const Call& call, Result result);
  void OnShellCall(const Call& call, Result result);
  void ConfigureBackground(const flutter::EncodableValue* settings);
  void Reveal();
  void Quit();
  void SetTray(bool on);
  void ShowTrayMenu(int x, int y);
  void SetAutostart(bool on);
  flutter::EncodableValue State();
  void PushState();
  void SetFullscreen(bool fullscreen);
  void LoadPlacement();
  void SavePlacement();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<Channel> window_channel_;
  std::unique_ptr<Channel> open_channel_;
  std::unique_ptr<Channel> shell_channel_;

  HANDLE instance_ = nullptr;

  // Whether the window opens maximised, from the saved placement.
  bool open_maximized_ = false;
  bool fullscreen_ = false;
  // Where the window was before fullscreen, to go back to.
  WINDOWPLACEMENT before_fullscreen_{sizeof(WINDOWPLACEMENT)};
  bool start_hidden_ = false;
  bool owns_core_ = false;
  // A --background launch whose settings have not arrived yet.
  bool awaiting_settings_ = false;
  bool shown_ = false;
  // Closing hides the window rather than quitting, unless quitting_.
  bool background_ = false;
  bool quitting_ = false;
  bool tray_ = false;
  std::wstring open_label_;
  std::wstring quit_label_;

  // The state Dart was last told, so a resize drag is not a message a pixel.
  bool pushed_maximized_ = false;
  bool pushed_fullscreen_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
