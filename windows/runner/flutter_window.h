#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/standard_method_codec.h>
#include <flutter/standard_message_codec.h>

#include <atomic>
#include <chrono>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "win32_window.h"
#include "desktop_media_controls.h"
#include "clipboard_revision.h"

struct WindowsYtDlpTask;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void ShutdownEngine();
  bool engine_shutdown_started_ = false;
  void RegisterYtDlpChannel();
  void PostUiTask(std::function<void()> task);
  void DrainUiTasks();
  void EmitYtDlpEvent(const flutter::EncodableMap& payload);
  void JoinBackgroundThreads();
  bool StartYtDlpDownload(const flutter::EncodableMap& request,
                          std::string* error_message);
  bool PauseYtDlpDownload(const std::string& task_id);
  bool CancelYtDlpDownload(const std::string& task_id);
  bool RemoveYtDlpTask(const std::string& task_id);
  std::unique_ptr<flutter::EncodableValue> GetYtDlpTaskStatus(
      const std::string& task_id);
  void MonitorYtDlpTask(const std::shared_ptr<WindowsYtDlpTask>& task);
  void HandleYtDlpOutput(const std::shared_ptr<WindowsYtDlpTask>& task,
                         const std::string& line);

  // The project to run.
  flutter::DartProject project_;
  std::unique_ptr<DesktopMediaControls> desktop_media_controls_;
  std::unique_ptr<ClipboardRevisionBridge> clipboard_revision_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      yt_dlp_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      yt_dlp_event_channel_;
  std::optional<std::filesystem::path> configured_yt_dlp_path_;
  std::optional<std::filesystem::path> configured_ffmpeg_path_;
  std::shared_ptr<flutter::EventSink<flutter::EncodableValue>> yt_dlp_event_sink_;
  std::mutex yt_dlp_mutex_;
  std::unordered_map<std::string, std::shared_ptr<WindowsYtDlpTask>>
      yt_dlp_tasks_;
  std::mutex yt_dlp_worker_threads_mutex_;
  std::vector<std::thread> yt_dlp_worker_threads_;
  std::mutex ui_task_mutex_;
  std::vector<std::function<void()>> pending_ui_tasks_;
  std::shared_ptr<int> lifetime_token_ = std::make_shared<int>(0);
  std::atomic<bool> is_shutting_down_{false};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
