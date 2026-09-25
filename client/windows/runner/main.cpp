#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// The lumeo-core an installed copy ships with, next to this binary. A build
// from the source tree (flutter run) has none and talks to whatever core
// answers on the address it was built with.
std::wstring BundledCorePath() {
  wchar_t self[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, self, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    return std::wstring();
  }
  std::wstring core(self, length);
  core.resize(core.find_last_of(L'\\') + 1);
  core += L"lumeo-core.exe";
  return GetFileAttributesW(core.c_str()) == INVALID_FILE_ATTRIBUTES
             ? std::wstring()
             : core;
}

// Starts the core as this process's child, as the Linux runner does. Nothing
// is ever written to its stdin: the core stops when the pipe closes, which
// Windows does when this process ends, however it ends. Only the pipe and the
// log are inherited, so nothing else this process starts keeps the core
// alive after us.
void StartCore(const std::wstring& core) {
  SECURITY_ATTRIBUTES inheritable{sizeof(inheritable), nullptr, TRUE};
  HANDLE read = nullptr;
  HANDLE write = nullptr;
  if (!CreatePipe(&read, &write, &inheritable, 0)) {
    return;
  }
  // Ours: never inherited, never closed.
  SetHandleInformation(write, HANDLE_FLAG_INHERIT, 0);

  // The core logs to stderr, and a GUI process has none to give it.
  const std::wstring state = StateDir();
  HANDLE log = state.empty()
                   ? INVALID_HANDLE_VALUE
                   : CreateFileW((state + L"\\core.log").c_str(), GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE,
                                 &inheritable, CREATE_ALWAYS,
                                 FILE_ATTRIBUTE_NORMAL, nullptr);
  HANDLE inherited[] = {read, log};
  const DWORD inherited_count = log == INVALID_HANDLE_VALUE ? 1 : 2;

  SIZE_T size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
  std::vector<char> buffer(size);
  auto attributes =
      reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(buffer.data());
  if (InitializeProcThreadAttributeList(attributes, 1, 0, &size) &&
      UpdateProcThreadAttribute(attributes, 0,
                                PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited,
                                inherited_count * sizeof(HANDLE), nullptr,
                                nullptr)) {
    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = read;
    HANDLE output = log == INVALID_HANDLE_VALUE ? nullptr : log;
    startup.StartupInfo.hStdOutput = output;
    startup.StartupInfo.hStdError = output;
    startup.lpAttributeList = attributes;
    SetEnvironmentVariableW(L"LUMEO_EXIT_ON_STDIN_EOF", L"1");
    std::wstring command = L"\"" + core + L"\"";
    PROCESS_INFORMATION process{};
    if (CreateProcessW(core.c_str(), command.data(), nullptr, nullptr, TRUE,
                       CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT,
                       nullptr, nullptr, &startup.StartupInfo, &process)) {
      CloseHandle(process.hThread);
      CloseHandle(process.hProcess);
    }
    DeleteProcThreadAttributeList(attributes);
  }
  CloseHandle(read);
  if (log != INVALID_HANDLE_VALUE) {
    CloseHandle(log);
  }
}

// Hands this launch's file, if it has one, to the window of the instance
// already running, and brings that window forward.
void ForwardToRunningInstance() {
  HWND window = FindWindowW(kWindowClassName, nullptr);
  if (window == nullptr) {
    return;
  }
  DWORD process = 0;
  GetWindowThreadProcessId(window, &process);
  AllowSetForegroundWindow(process);

  std::wstring path;
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv != nullptr && argc > 1) {
    // Absolute, because the running instance stands in another directory.
    const DWORD length = GetFullPathNameW(argv[1], 0, nullptr, nullptr);
    if (length > 0) {
      path.resize(length);
      path.resize(GetFullPathNameW(argv[1], length, path.data(), nullptr));
    }
  }
  LocalFree(argv);

  COPYDATASTRUCT data{kOpenFileCopyData,
                      static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t)),
                      path.data()};
  SendMessageTimeoutW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data),
                      SMTO_ABORTIFHUNG, 5000, nullptr);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // One instance per session when the app owns its core, as on Linux: a
  // second launch hands its file to the first and exits, so there is never a
  // second core. A build without a core stays non-unique, so flutter run
  // starts beside an installed copy instead of waking it.
  const std::wstring core = BundledCorePath();
  HANDLE mutex = nullptr;
  if (!core.empty()) {
    // Held by the window, which closes it when it goes.
    mutex = CreateMutexW(nullptr, FALSE, L"Local\\dev.lumeo.lumeo");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
      ForwardToRunningInstance();
      return EXIT_SUCCESS;
    }
    StartCore(core);
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // A media app opens on artwork: wide enough for a hero and one full row of
  // posters under it. Centred, and shrunk to fit a smaller screen, on the
  // first launch; after that it opens where it was left.
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 900);
  if (!window.Create(L"Lumeo", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  window.HoldInstance(mutex);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
