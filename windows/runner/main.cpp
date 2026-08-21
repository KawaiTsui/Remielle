#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <algorithm>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr char kParentPidPrefix[] = "--parent-pid=";
constexpr wchar_t kControlPanelWindowTitle[] = L"Remielle 控制面板";

DWORD ParseParentProcessId(const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (argument.rfind(kParentPidPrefix, 0) != 0) continue;
    try {
      size_t parsed_length = 0;
      const std::string value_text =
          argument.substr(sizeof(kParentPidPrefix) - 1);
      const unsigned long value =
          std::stoul(value_text, &parsed_length);
      return parsed_length == value_text.size() && value > 0 &&
                     value <= MAXDWORD
                 ? static_cast<DWORD>(value)
                 : 0;
    } catch (...) {
      return 0;
    }
  }
  return 0;
}

struct ParentWindowSearch {
  DWORD process_id;
  bool found = false;
};

BOOL CALLBACK FindParentPetWindow(HWND window, LPARAM data) {
  auto* search = reinterpret_cast<ParentWindowSearch*>(data);
  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id != search->process_id) return TRUE;
  wchar_t title[128] = {};
  GetWindowTextW(window, title,
                 static_cast<int>(sizeof(title) / sizeof(title[0])));
  if (std::wstring(title) != L"remielle") return TRUE;
  search->found = true;
  return FALSE;
}

HANDLE OpenValidatedParentProcess(DWORD process_id) {
  if (process_id == 0 || process_id == GetCurrentProcessId()) return nullptr;
  HANDLE process = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION,
                               FALSE, process_id);
  if (!process) return nullptr;

  std::vector<wchar_t> parent_path(32768);
  DWORD parent_path_length = static_cast<DWORD>(parent_path.size());
  std::vector<wchar_t> current_path(32768);
  const DWORD current_path_length = GetModuleFileNameW(
      nullptr, current_path.data(), static_cast<DWORD>(current_path.size()));
  if (!QueryFullProcessImageNameW(process, 0, parent_path.data(),
                                  &parent_path_length) ||
      current_path_length == 0 ||
      current_path_length >= current_path.size() ||
      CompareStringOrdinal(parent_path.data(), parent_path_length,
                           current_path.data(), current_path_length, TRUE) !=
          CSTR_EQUAL) {
    CloseHandle(process);
    return nullptr;
  }

  ParentWindowSearch search{process_id};
  EnumWindows(FindParentPetWindow, reinterpret_cast<LPARAM>(&search));
  if (!search.found) {
    CloseHandle(process);
    return nullptr;
  }
  return process;
}

BOOL CALLBACK FindControlPanelWindow(HWND window, LPARAM data) {
  auto* result = reinterpret_cast<HWND*>(data);
  wchar_t title[256] = {};
  GetWindowTextW(window, title,
                 static_cast<int>(sizeof(title) / sizeof(title[0])));
  if (std::wstring(title) != kControlPanelWindowTitle) return TRUE;
  *result = window;
  return FALSE;
}

bool FocusExistingControlPanel() {
  HWND window = nullptr;
  EnumWindows(FindControlPanelWindow, reinterpret_cast<LPARAM>(&window));
  if (!window) return false;

  const DWORD current_thread_id = GetCurrentThreadId();
  const DWORD target_thread_id = GetWindowThreadProcessId(window, nullptr);
  const HWND foreground_window = GetForegroundWindow();
  const DWORD foreground_thread_id = foreground_window
                                         ? GetWindowThreadProcessId(
                                               foreground_window, nullptr)
                                         : 0;
  const bool attached_to_foreground =
      foreground_thread_id != 0 &&
      foreground_thread_id != current_thread_id &&
      AttachThreadInput(current_thread_id, foreground_thread_id, TRUE);
  const bool attached_to_target =
      target_thread_id != 0 && target_thread_id != current_thread_id &&
      AttachThreadInput(current_thread_id, target_thread_id, TRUE);

  ShowWindowAsync(window, SW_RESTORE);
  SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
  BringWindowToTop(window);
  SetForegroundWindow(window);
  SetFocus(window);

  if (attached_to_target) {
    AttachThreadInput(current_thread_id, target_thread_id, FALSE);
  }
  if (attached_to_foreground) {
    AttachThreadInput(current_thread_id, foreground_thread_id, FALSE);
  }
  return true;
}

HANDLE CreateControlPanelMutex(DWORD parent_process_id,
                               bool* already_exists) {
  const std::wstring name = L"Local\\RemielleControlPanel-" +
                            std::to_wstring(parent_process_id);
  HANDLE mutex = CreateMutexW(nullptr, FALSE, name.c_str());
  *already_exists = mutex && GetLastError() == ERROR_ALREADY_EXISTS;
  return mutex;
}

void RunMessageLoop(HANDLE parent_process) {
  if (!parent_process) {
    MSG msg;
    while (GetMessage(&msg, nullptr, 0, 0)) {
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }
    return;
  }

  bool running = true;
  while (running) {
    const DWORD result =
        MsgWaitForMultipleObjects(1, &parent_process, FALSE, INFINITE,
                                  QS_ALLINPUT);
    if (result == WAIT_OBJECT_0 || result == WAIT_FAILED) break;
    if (result != WAIT_OBJECT_0 + 1) continue;
    MSG msg;
    while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
      if (msg.message == WM_QUIT) {
        running = false;
        break;
      }
      TranslateMessage(&msg);
      DispatchMessage(&msg);
    }
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  const bool is_control_panel =
      std::find(command_line_arguments.begin(), command_line_arguments.end(),
                "--control-panel") != command_line_arguments.end();
  HANDLE parent_process = nullptr;
  HANDLE control_panel_mutex = nullptr;
  if (is_control_panel) {
    const DWORD parent_process_id =
        ParseParentProcessId(command_line_arguments);
    parent_process = OpenValidatedParentProcess(parent_process_id);
    if (!parent_process) {
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    bool control_panel_already_exists = false;
    control_panel_mutex = CreateControlPanelMutex(
        parent_process_id, &control_panel_already_exists);
    if (!control_panel_mutex) {
      CloseHandle(parent_process);
      ::CoUninitialize();
      return EXIT_FAILURE;
    }
    if (control_panel_already_exists) {
      for (int attempt = 0; attempt < 40; ++attempt) {
        if (FocusExistingControlPanel()) break;
        Sleep(50);
      }
      CloseHandle(control_panel_mutex);
      CloseHandle(parent_process);
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, is_control_panel, !is_control_panel);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  const wchar_t *window_title =
      is_control_panel ? kControlPanelWindowTitle : L"remielle";
  if (!window.Create(window_title, origin, size)) {
    if (control_panel_mutex) CloseHandle(control_panel_mutex);
    if (parent_process) CloseHandle(parent_process);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  RunMessageLoop(parent_process);
  if (control_panel_mutex) CloseHandle(control_panel_mutex);
  if (parent_process) CloseHandle(parent_process);

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
