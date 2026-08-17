#include "flutter_window.h"

#include <algorithm>
#include <atomic>
#include <commctrl.h>
#include <cstdint>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

std::atomic<ULONGLONG> g_last_keyboard_input_tick{0};

LRESULT CALLBACK KeyboardActivityHook(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HC_ACTION &&
      (wparam == WM_KEYDOWN || wparam == WM_SYSKEYDOWN)) {
    g_last_keyboard_input_tick.store(GetTickCount64(),
                                     std::memory_order_relaxed);
  }
  return CallNextHookEx(nullptr, code, wparam, lparam);
}

bool IsNativeTextCaretActive() {
  const HWND foreground_window = GetForegroundWindow();
  if (!foreground_window) {
    return false;
  }

  const DWORD thread_id = GetWindowThreadProcessId(foreground_window, nullptr);
  GUITHREADINFO info = {};
  info.cbSize = sizeof(GUITHREADINFO);
  if (!thread_id || !GetGUIThreadInfo(thread_id, &info)) {
    return false;
  }

  return info.hwndCaret != nullptr && (info.flags & GUI_CARETBLINKING) != 0;
}

int64_t GetKeyboardInputIdleMilliseconds() {
  const ULONGLONG last_input =
      g_last_keyboard_input_tick.load(std::memory_order_relaxed);
  if (last_input == 0) {
    return 0;
  }
  return static_cast<int64_t>(GetTickCount64() - last_input);
}

bool IsAutomationDescendantOf(IUIAutomation* automation,
                              IUIAutomationElement* element,
                              IUIAutomationElement* ancestor) {
  IUIAutomationTreeWalker* walker = nullptr;
  if (FAILED(automation->get_RawViewWalker(&walker)) || !walker) {
    return false;
  }

  IUIAutomationElement* current = element;
  current->AddRef();
  bool found_ancestor = false;
  for (int depth = 0; current && depth < 64; ++depth) {
    BOOL same_element = FALSE;
    if (SUCCEEDED(
            automation->CompareElements(current, ancestor, &same_element)) &&
        same_element != FALSE) {
      found_ancestor = true;
      break;
    }

    IUIAutomationElement* parent = nullptr;
    const HRESULT parent_result = walker->GetParentElement(current, &parent);
    current->Release();
    current = parent;
    if (FAILED(parent_result)) {
      break;
    }
  }

  if (current) {
    current->Release();
  }
  walker->Release();
  return found_ancestor;
}

bool IsAutomationTextCaretActive(IUIAutomation* automation) {
  if (!automation) {
    return false;
  }

  const HWND foreground_window = GetForegroundWindow();
  if (!foreground_window) {
    return false;
  }

  IUIAutomationElement* foreground_element = nullptr;
  if (FAILED(
          automation->ElementFromHandle(foreground_window, &foreground_element)) ||
      !foreground_element) {
    return false;
  }

  IUIAutomationElement* focused_element = nullptr;
  if (FAILED(automation->GetFocusedElement(&focused_element)) ||
      !focused_element) {
    foreground_element->Release();
    return false;
  }

  // Focus and foreground-window queries are separate cross-process calls.
  // Discard the sample if the user switched windows between them.
  if (GetForegroundWindow() != foreground_window ||
      !IsAutomationDescendantOf(automation, focused_element,
                                foreground_element)) {
    focused_element->Release();
    foreground_element->Release();
    return false;
  }
  foreground_element->Release();

  BOOL has_keyboard_focus = FALSE;
  focused_element->get_CurrentHasKeyboardFocus(&has_keyboard_focus);
  if (!has_keyboard_focus) {
    focused_element->Release();
    return false;
  }

  IUIAutomationTextPattern2* text_pattern = nullptr;
  const HRESULT pattern_result = focused_element->GetCurrentPatternAs(
      UIA_TextPattern2Id, IID_PPV_ARGS(&text_pattern));
  if (SUCCEEDED(pattern_result) && text_pattern) {
    BOOL caret_active = FALSE;
    IUIAutomationTextRange* caret_range = nullptr;
    const HRESULT caret_result =
        text_pattern->GetCaretRange(&caret_active, &caret_range);
    if (caret_range) {
      caret_range->Release();
    }
    text_pattern->Release();
    if (SUCCEEDED(caret_result)) {
      if (caret_active != FALSE) {
        const bool foreground_stable =
            GetForegroundWindow() == foreground_window;
        focused_element->Release();
        return foreground_stable;
      }
    }
  }

  CONTROLTYPEID control_type = 0;
  focused_element->get_CurrentControlType(&control_type);
  bool is_editable_text_control = false;
  if (control_type == UIA_EditControlTypeId) {
    IUIAutomationValuePattern* value_pattern = nullptr;
    if (SUCCEEDED(focused_element->GetCurrentPatternAs(
            UIA_ValuePatternId, IID_PPV_ARGS(&value_pattern))) &&
        value_pattern) {
      BOOL read_only = TRUE;
      value_pattern->get_CurrentIsReadOnly(&read_only);
      is_editable_text_control = read_only == FALSE;
      value_pattern->Release();
    } else {
      is_editable_text_control = true;
    }
  }

  bool is_editable_combo_box = false;
  if (control_type == UIA_ComboBoxControlTypeId) {
    IUIAutomationValuePattern* value_pattern = nullptr;
    if (SUCCEEDED(focused_element->GetCurrentPatternAs(
            UIA_ValuePatternId, IID_PPV_ARGS(&value_pattern))) &&
        value_pattern) {
      BOOL read_only = TRUE;
      value_pattern->get_CurrentIsReadOnly(&read_only);
      is_editable_combo_box = read_only == FALSE;
      value_pattern->Release();
    }
  }

  focused_element->Release();
  return GetForegroundWindow() == foreground_window &&
         (is_editable_text_control || is_editable_combo_box);
}

}  // namespace

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
  if (constrain_to_work_area_) {
    g_last_keyboard_input_tick.store(GetTickCount64(),
                                     std::memory_order_relaxed);
    keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardActivityHook,
                                      GetModuleHandle(nullptr), 0);
  }
  CoCreateInstance(CLSID_CUIAutomation8, nullptr, CLSCTX_INPROC_SERVER,
                   IID_PPV_ARGS(&ui_automation_));
  system_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "remielle/system",
          &flutter::StandardMethodCodec::GetInstance());
  system_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "isTextCaretActive") {
          result->Success(flutter::EncodableValue(IsTextCaretActive()));
          return;
        }
        if (call.method_name() == "getKeyboardInputIdleMilliseconds") {
          result->Success(
              flutter::EncodableValue(GetKeyboardInputIdleMilliseconds()));
          return;
        }
        result->NotImplemented();
      });
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
  if (keyboard_hook_) {
    UnhookWindowsHookEx(keyboard_hook_);
    keyboard_hook_ = nullptr;
  }
  system_channel_.reset();
  if (ui_automation_) {
    ui_automation_->Release();
    ui_automation_ = nullptr;
  }
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::IsTextCaretActive() const {
  return IsNativeTextCaretActive() ||
         IsAutomationTextCaretActive(ui_automation_);
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
