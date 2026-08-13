#include "flutter_window.h"

#include <algorithm>
#include <commctrl.h>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool disable_accessibility,
                             bool constrain_to_work_area)
    : project_(project),
      disable_accessibility_(disable_accessibility),
      constrain_to_work_area_(constrain_to_work_area) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

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
  flutter_view_window_ = flutter_controller_->view()->GetNativeWindow();
  if (disable_accessibility_) {
    SetWindowSubclass(flutter_view_window_, FlutterViewSubclassProc, 1,
                      reinterpret_cast<DWORD_PTR>(this));
  }
  SetChildContent(flutter_view_window_);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_view_window_ && disable_accessibility_) {
    RemoveWindowSubclass(flutter_view_window_, FlutterViewSubclassProc, 1);
  }
  flutter_view_window_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (constrain_to_work_area_ && message == WM_MOVING) {
    auto* proposed = reinterpret_cast<RECT*>(lparam);
    MONITORINFO monitor_info{sizeof(MONITORINFO)};
    const HMONITOR monitor =
        MonitorFromRect(proposed, MONITOR_DEFAULTTONEAREST);
    if (GetMonitorInfo(monitor, &monitor_info)) {
      const LONG width = proposed->right - proposed->left;
      const LONG height = proposed->bottom - proposed->top;
      proposed->left =
          std::clamp(proposed->left, monitor_info.rcWork.left,
                     monitor_info.rcWork.right - width);
      proposed->top =
          std::clamp(proposed->top, monitor_info.rcWork.top,
                     monitor_info.rcWork.bottom - height);
      proposed->right = proposed->left + width;
      proposed->bottom = proposed->top + height;
      return TRUE;
    }
  }
  if (disable_accessibility_ && message == WM_GETOBJECT) {
    return 0;
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

LRESULT CALLBACK FlutterWindow::FlutterViewSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference_data) {
  auto* self = reinterpret_cast<FlutterWindow*>(reference_data);
  if (self && self->disable_accessibility_ && message == WM_GETOBJECT) {
    return 0;
  }
  return DefSubclassProc(window, message, wparam, lparam);
}
