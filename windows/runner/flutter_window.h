#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <UIAutomation.h>

#include <memory>
#include <atomic>
#include <thread>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  FlutterWindow(const flutter::DartProject& project, bool disable_accessibility,
                bool constrain_to_work_area);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool IsTextCaretActive();
  void RequestCaretStateQuery();
  void StartCaretStateQuery();
  void PublishCaretState(bool active);

  static LRESULT CALLBACK FlutterViewSubclassProc(
      HWND window, UINT message, WPARAM wparam, LPARAM lparam,
      UINT_PTR subclass_id, DWORD_PTR reference_data);

  // The project to run.
  flutter::DartProject project_;
  bool disable_accessibility_ = false;
  bool constrain_to_work_area_ = false;
  HWND flutter_view_window_ = nullptr;
  HHOOK keyboard_hook_ = nullptr;
  HWINEVENTHOOK foreground_event_hook_ = nullptr;
  HWINEVENTHOOK focus_event_hook_ = nullptr;
  HWINEVENTHOOK caret_show_event_hook_ = nullptr;
  HWINEVENTHOOK caret_hide_event_hook_ = nullptr;
  bool caret_active_ = false;
  std::atomic<bool> caret_query_running_{false};
  std::atomic<bool> caret_query_cancelled_{false};
  bool caret_query_dirty_ = false;
  bool keyboard_activity_pending_ = false;
  bool caret_query_result_active_ = false;
  HWND caret_query_result_foreground_ = nullptr;
  std::thread caret_query_thread_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      system_channel_;
  IUIAutomation* ui_automation_ = nullptr;
  HANDLE control_panel_job_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
