#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

bool IsWindows11OrGreater() {
  OSVERSIONINFOEXW version{sizeof(version)};
  version.dwBuildNumber = 22000;
  return VerifyVersionInfoW(
      &version, VER_BUILDNUMBER,
      VerSetConditionMask(0, VER_BUILDNUMBER, VER_GREATER_EQUAL));
}

std::wstring PlacementFile() {
  std::wstring dir = StateDir();
  return dir.empty() ? dir : dir + L"\\window.ini";
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  // Recomputes the frame through WM_NCCALCSIZE below, which takes the title
  // bar away, before the view is sized to the client area.
  SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);
  LoadPlacement();

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  flutter::BinaryMessenger* messenger =
      flutter_controller_->engine()->messenger();
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  window_channel_ =
      std::make_unique<Channel>(messenger, "dev.lumeo/window", &codec);
  window_channel_->SetMethodCallHandler(
      [this](const Call& call, Result result) {
        OnWindowCall(call, std::move(result));
      });
  open_channel_ =
      std::make_unique<Channel>(messenger, "dev.lumeo/open", &codec);
  shell_channel_ =
      std::make_unique<Channel>(messenger, "dev.lumeo/shell", &codec);
  shell_channel_->SetMethodCallHandler([this](const Call& call, Result result) {
    OnShellCall(call, std::move(result));
  });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    ShowWindow(GetHandle(), open_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  open_channel_ = nullptr;
  shell_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  switch (message) {
    // No title bar of the system's making, for the reason the Linux runner
    // hides GTK's: the client draws its own at the top of the artwork. The
    // side and bottom borders stay the system's, so resizing, the shadow and
    // snapping are what every other window has.
    case WM_NCCALCSIZE:
      if (wparam && !fullscreen_) {
        RECT& client = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0];
        const LONG top = client.top;
        DefWindowProc(hwnd, message, wparam, lparam);
        if (IsZoomed(hwnd)) {
          // A maximised window hangs its frame off the screen; the screen's
          // top edge is that far below the window's.
          const UINT dpi = GetDpiForWindow(hwnd);
          client.top = top + GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
                       GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
        } else {
          // Windows 10 paints a white line over a window with no frame at
          // all at the top; one row of frame is the edge its windows have.
          static const bool windows11 = IsWindows11OrGreater();
          client.top = top + (windows11 ? 0 : 1);
        }
        return 0;
      }
      break;

    case WM_SIZE:
      PushState();
      break;

    case WM_DESTROY:
      SavePlacement();
      // The window gone is this instance ending, though the process has the
      // engine to tear down yet. A launch that found the mutex until then
      // would find no window to hand its file to and exit with nothing shown;
      // now it becomes the instance, and its core waits for this one's.
      if (instance_ != nullptr) {
        CloseHandle(instance_);
        instance_ = nullptr;
      }
      break;

    // A second launch, which exits once it has handed its file over.
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data->dwData != kOpenFileCopyData) {
        break;
      }
      if (IsIconic(hwnd)) {
        ShowWindow(hwnd, SW_RESTORE);
      }
      SetForegroundWindow(hwnd);
      std::wstring path;
      if (data->lpData != nullptr) {
        path.assign(static_cast<const wchar_t*>(data->lpData),
                    data->cbData / sizeof(wchar_t));
        path.resize(wcsnlen(path.c_str(), path.size()));
      }
      if (!path.empty() && open_channel_) {
        open_channel_->InvokeMethod(
            "open", std::make_unique<flutter::EncodableValue>(
                        Utf8FromUtf16(path.c_str())));
      }
      return TRUE;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::OnWindowCall(const Call& call, Result result) {
  HWND hwnd = GetHandle();
  const std::string& method = call.method_name();
  if (method == "state") {
    result->Success(State());
  } else if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
    result->Success();
  } else if (method == "toggleMaximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success();
  } else if (method == "close") {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    result->Success();
  } else if (method == "setFullscreen") {
    const auto* on = std::get_if<bool>(call.arguments());
    SetFullscreen(on != nullptr && *on);
    result->Success();
  } else if (method == "startDrag") {
    // Answered first: the move below is a modal loop that returns only when
    // the button is let go. From here Windows owns the pointer, which is what
    // makes snapping and drag-to-maximise work as for every other window.
    result->Success();
    POINT cursor;
    GetCursorPos(&cursor);
    ReleaseCapture();
    SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION,
                MAKELPARAM(cursor.x, cursor.y));
  } else {
    result->NotImplemented();
  }
}

void FlutterWindow::OnShellCall(const Call& call, Result result) {
  const auto* argument = std::get_if<std::string>(call.arguments());
  if (call.method_name() == "open" && argument != nullptr) {
    // A folder in Explorer, a web address in the default browser.
    ShellExecuteW(GetHandle(), L"open", Utf16FromUtf8(*argument).c_str(),
                  nullptr, nullptr, SW_SHOWNORMAL);
    result->Success();
  } else if (call.method_name() == "pictures") {
    PWSTR path = nullptr;
    HRESULT found = SHGetKnownFolderPath(FOLDERID_Pictures, KF_FLAG_DEFAULT,
                                         nullptr, &path);
    std::string pictures = SUCCEEDED(found) ? Utf8FromUtf16(path) : "";
    CoTaskMemFree(path);
    result->Success(flutter::EncodableValue(pictures));
  } else {
    result->NotImplemented();
  }
}

flutter::EncodableValue FlutterWindow::State() {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("maximized"),
       flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE)},
      {flutter::EncodableValue("fullscreen"),
       flutter::EncodableValue(fullscreen_)},
  });
}

void FlutterWindow::PushState() {
  if (!window_channel_) {
    return;
  }
  const bool maximized = IsZoomed(GetHandle()) != FALSE;
  if (maximized == pushed_maximized_ && fullscreen_ == pushed_fullscreen_) {
    return;
  }
  pushed_maximized_ = maximized;
  pushed_fullscreen_ = fullscreen_;
  window_channel_->InvokeMethod(
      "state", std::make_unique<flutter::EncodableValue>(State()));
}

// The window without its frame over the whole monitor, and back to where it
// was, maximised included.
void FlutterWindow::SetFullscreen(bool fullscreen) {
  if (fullscreen == fullscreen_) {
    return;
  }
  HWND hwnd = GetHandle();
  const LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  fullscreen_ = fullscreen;
  if (fullscreen) {
    MONITORINFO monitor{sizeof(monitor)};
    GetWindowPlacement(hwnd, &before_fullscreen_);
    GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    SetWindowLongPtr(hwnd, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left, monitor.rcMonitor.top,
                 monitor.rcMonitor.right - monitor.rcMonitor.left,
                 monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(hwnd, GWL_STYLE, style | WS_OVERLAPPEDWINDOW);
    SetWindowPlacement(hwnd, &before_fullscreen_);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                     SWP_FRAMECHANGED);
  }
  PushState();
}

// Position, free size and maximised, as Windows applications keep them.
// Fullscreen belongs to the player, not to the home screen the app opens on.
void FlutterWindow::LoadPlacement() {
  HWND hwnd = GetHandle();
  WINDOWPLACEMENT placement{sizeof(placement)};
  const std::wstring file = PlacementFile();
  if (!file.empty() &&
      GetPrivateProfileStructW(L"window", L"placement", &placement,
                               sizeof(placement), file.c_str()) &&
      placement.length == sizeof(placement)) {
    open_maximized_ = placement.showCmd == SW_SHOWMAXIMIZED ||
                      (placement.flags & WPF_RESTORETOMAXIMIZED) != 0;
    // Windows moves a window that would be off every screen back onto one.
    placement.showCmd = SW_HIDE;
    SetWindowPlacement(hwnd, &placement);
    return;
  }
  // The first launch: centred on the screen, and no bigger than it.
  RECT window;
  GetWindowRect(hwnd, &window);
  MONITORINFO monitor{sizeof(monitor)};
  GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), &monitor);
  const RECT& area = monitor.rcWork;
  const LONG width =
      std::min(window.right - window.left, area.right - area.left);
  const LONG height =
      std::min(window.bottom - window.top, area.bottom - area.top);
  SetWindowPos(hwnd, nullptr, area.left + (area.right - area.left - width) / 2,
               area.top + (area.bottom - area.top - height) / 2, width, height,
               SWP_NOZORDER | SWP_NOACTIVATE);
}

void FlutterWindow::SavePlacement() {
  WINDOWPLACEMENT placement{sizeof(placement)};
  if (fullscreen_) {
    placement = before_fullscreen_;
  } else if (!GetWindowPlacement(GetHandle(), &placement)) {
    return;
  }
  const std::wstring file = PlacementFile();
  if (!file.empty()) {
    WritePrivateProfileStructW(L"window", L"placement", &placement,
                               sizeof(placement), file.c_str());
  }
}
