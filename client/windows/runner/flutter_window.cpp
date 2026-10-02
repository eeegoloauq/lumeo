#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "utils.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayOpen = 1;
constexpr UINT kTrayQuit = 2;
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Lumeo";

// Sent to every top-level window when Explorer starts again, which takes the
// tray's icons with it.
UINT TaskbarCreated() {
  static const UINT message = RegisterWindowMessageW(L"TaskbarCreated");
  return message;
}

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
    if (!start_hidden_) {
      ShowWindow(GetHandle(),
                 open_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
      shown_ = true;
    }
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
  // Also the first chance when the icon could not be added: a login launch
  // can start before Explorer does.
  if (message == TaskbarCreated() && background_) {
    tray_ = false;
    SetTray(true);
  }
  switch (message) {
    // Ahead of Flutter, which would ask the client and quit.
    case WM_CLOSE:
      if (background_ && !quitting_) {
        // Left first, while the window is still shown: leaving it later puts
        // back a placement that would show the window again.
        SetFullscreen(false);
        ShowWindow(hwnd, SW_HIDE);
        if (window_channel_) {
          window_channel_->InvokeMethod("hidden", nullptr);
        }
        return 0;
      }
      break;

    // Logging off, or an installer's Restart Manager asking the app to make
    // way: the close that follows is a real one.
    case WM_QUERYENDSESSION:
      quitting_ = true;
      break;

    // Another application refused, and the session goes on.
    case WM_ENDSESSION:
      if (!wparam) {
        quitting_ = false;
      }
      break;

    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
          Reveal();
          break;
        case WM_CONTEXTMENU:
          // Version 4 puts the anchor in wparam, as signed screen coordinates.
          ShowTrayMenu(static_cast<short>(LOWORD(wparam)),
                       static_cast<short>(HIWORD(wparam)));
          break;
      }
      return 0;

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
      SetTray(false);
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
      Reveal();
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
  } else if (method == "configureBackground") {
    ConfigureBackground(call.arguments());
    result->Success();
  } else if (method == "quit") {
    result->Success();
    Quit();
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
  if (call.method_name() == "pictures") {
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

void FlutterWindow::ConfigureBackground(
    const flutter::EncodableValue* settings) {
  const auto* map =
      settings == nullptr ? nullptr
                          : std::get_if<flutter::EncodableMap>(settings);
  if (map == nullptr) {
    return;
  }
  auto flag = [map](const char* key) {
    const auto found = map->find(flutter::EncodableValue(key));
    const bool* value = found == map->end()
                            ? nullptr
                            : std::get_if<bool>(&found->second);
    return value != nullptr && *value;
  };
  auto text = [map](const char* key) {
    const auto found = map->find(flutter::EncodableValue(key));
    const std::string* value = found == map->end()
                                   ? nullptr
                                   : std::get_if<std::string>(&found->second);
    return value == nullptr ? std::wstring() : Utf16FromUtf8(*value);
  };
  background_ = flag("enabled");
  open_label_ = text("open");
  quit_label_ = text("quit");
  if (owns_core_) {
    SetAutostart(flag("autostart"));
  }
  SetTray(background_);
  if (awaiting_settings_) {
    awaiting_settings_ = false;
    // A login entry left behind by a setting since turned off.
    if (!background_) {
      Reveal();
    }
  }
}

// Shows the window wherever it is: hidden in the background, never shown
// after a --background launch, or minimised.
void FlutterWindow::Reveal() {
  HWND hwnd = GetHandle();
  if (!IsWindowVisible(hwnd)) {
    ShowWindow(hwnd, shown_ ? SW_SHOW
                            : (open_maximized_ ? SW_SHOWMAXIMIZED
                                               : SW_SHOWNORMAL));
    shown_ = true;
  } else if (IsIconic(hwnd)) {
    ShowWindow(hwnd, SW_RESTORE);
  }
  SetForegroundWindow(hwnd);
}

// The close goes on to Flutter, which lets the client save what it has.
void FlutterWindow::Quit() {
  quitting_ = true;
  PostMessage(GetHandle(), WM_CLOSE, 0, 0);
}

void FlutterWindow::SetTray(bool on) {
  NOTIFYICONDATAW icon{sizeof(icon)};
  icon.hWnd = GetHandle();
  icon.uID = 1;
  if (!on) {
    if (tray_) {
      Shell_NotifyIconW(NIM_DELETE, &icon);
      tray_ = false;
    }
    return;
  }
  if (tray_) {
    return;
  }
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_SHARED));
  wcscpy_s(icon.szTip, L"Lumeo");
  tray_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  if (tray_) {
    // Version 4 sends NIN_SELECT and WM_CONTEXTMENU with the click's place.
    icon.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon);
  }
}

void FlutterWindow::ShowTrayMenu(int x, int y) {
  HWND hwnd = GetHandle();
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kTrayOpen, open_label_.c_str());
  AppendMenuW(menu, MF_STRING, kTrayQuit, quit_label_.c_str());
  // Without the window in front, a click elsewhere does not close the menu;
  // the WM_NULL after it is the documented other half of that.
  SetForegroundWindow(hwnd);
  const UINT chosen = static_cast<UINT>(TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, x, y, 0, hwnd,
      nullptr));
  PostMessage(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (chosen == kTrayOpen) {
    Reveal();
  } else if (chosen == kTrayQuit) {
    Quit();
  }
}

// The per-user Run key, written on every start so it follows a copy that has
// moved. The uninstaller removes it.
void FlutterWindow::SetAutostart(bool on) {
  if (!on) {
    RegDeleteKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue);
    return;
  }
  wchar_t self[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, self, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    return;
  }
  const std::wstring command =
      L"\"" + std::wstring(self, length) + L"\" --background";
  RegSetKeyValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, REG_SZ,
                  command.c_str(),
                  static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
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
