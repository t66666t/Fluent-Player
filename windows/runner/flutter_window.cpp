#include "flutter_window.h"

#include "ime_shortcut_gate.h"
#include "windows_process_arguments.h"

#include <Windows.h>
#include <shlobj.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <optional>
#include <filesystem>
#include <fstream>
#include <regex>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <flutter/event_stream_handler_functions.h>
#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr char kYtDlpChannelName[] = "com.example.video_player_app/yt_dlp";
constexpr char kYtDlpEventChannelName[] =
    "com.example.video_player_app/yt_dlp_events";
constexpr UINT kExecuteUiTasksMessage = WM_APP + 101;
constexpr DWORD kResolveTimeoutMs = 90000;

std::vector<wchar_t> CleanProxyEnvironment() {
  std::vector<wchar_t> result;
  wchar_t* environment = GetEnvironmentStringsW();
  if (!environment) return {L'\0', L'\0'};
  const std::set<std::wstring> proxy_keys = {L"http_proxy", L"https_proxy", L"all_proxy", L"ftp_proxy", L"no_proxy"};
  for (const wchar_t* entry = environment; *entry; entry += wcslen(entry) + 1) {
    std::wstring value(entry);
    const auto equals = value.find(L'=', value[0] == L'=' ? 1 : 0);
    std::wstring key = value.substr(0, equals);
    std::transform(key.begin(), key.end(), key.begin(), towlower);
    if (proxy_keys.count(key)) continue;
    result.insert(result.end(), value.begin(), value.end()); result.push_back(L'\0');
  }
  FreeEnvironmentStringsW(environment); result.push_back(L'\0'); return result;
}

std::filesystem::path GetExecutableDirectory() {
  wchar_t buffer[MAX_PATH];
  const auto length = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
  std::filesystem::path exe_path(std::wstring(buffer, length));
  return exe_path.parent_path();
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size = MultiByteToWideChar(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::string Trim(const std::string& value) {
  const auto start = value.find_first_not_of(" \r\n\t");
  if (start == std::string::npos) {
    return {};
  }
  const auto end = value.find_last_not_of(" \r\n\t");
  return value.substr(start, end - start + 1);
}

std::string EscapeJson(const std::string& value) {
  std::ostringstream output;
  for (const char ch : value) {
    switch (ch) {
      case '\\':
        output << "\\\\";
        break;
      case '"':
        output << "\\\"";
        break;
      case '\b':
        output << "\\b";
        break;
      case '\f':
        output << "\\f";
        break;
      case '\n':
        output << "\\n";
        break;
      case '\r':
        output << "\\r";
        break;
      case '\t':
        output << "\\t";
        break;
      default:
        output << ch;
        break;
    }
  }
  return output.str();
}

std::wstring QuoteArg(const std::wstring& arg) {
  return QuoteWindowsProcessArgument(arg);
}

std::optional<std::filesystem::path> FindExecutable(
    const std::vector<std::wstring>& candidates,
    const std::optional<std::filesystem::path>& configured_path = std::nullopt) {
  if (configured_path) {
    return std::filesystem::is_regular_file(*configured_path)
               ? configured_path
               : std::nullopt;
  }

  // Windows 桌面端的二进制文件只允许位于软件目录中。
  const auto exe_dir = GetExecutableDirectory();
  const std::vector<std::filesystem::path> software_roots = {
      exe_dir / L"yt_dlp", exe_dir / L"resources" / L"yt_dlp", exe_dir,
      exe_dir / L"resources"};

  for (const auto& root : software_roots) {
    for (const auto& candidate : candidates) {
      const auto local_path = root / candidate;
      if (std::filesystem::is_regular_file(local_path)) {
        return local_path;
      }
    }
  }
  return std::nullopt;
}

std::string BuildBinaryDiagnostic(
    const std::vector<std::wstring>& yt_dlp_candidates,
    const std::vector<std::wstring>& ffmpeg_candidates,
    const std::optional<std::filesystem::path>& configured_yt_dlp,
    const std::optional<std::filesystem::path>& configured_ffmpeg) {
  std::ostringstream output;
  output << "windows software-managed binary paths:";
  output << "\n- yt-dlp: "
         << (configured_yt_dlp ? WideToUtf8(configured_yt_dlp->wstring())
                               : "not configured");
  output << "\n- ffmpeg: "
         << (configured_ffmpeg ? WideToUtf8(configured_ffmpeg->wstring())
                               : "not configured");
  output << "\nsoftware directory search roots:";

  const auto exe_dir = GetExecutableDirectory();
  output << "\n- " << WideToUtf8((exe_dir / L"yt_dlp").wstring());
  output << "\n- " << WideToUtf8(exe_dir.wstring());
  output << "\n- " << WideToUtf8((exe_dir / L"resources").wstring());
  output << "\nyt-dlp candidates:";
  for (const auto& candidate : yt_dlp_candidates) {
    output << "\n- " << WideToUtf8(candidate);
  }
  output << "\nffmpeg candidates:";
  for (const auto& candidate : ffmpeg_candidates) {
    output << "\n- " << WideToUtf8(candidate);
  }
  return output.str();
}

struct ProcessResult {
  bool success = false;
  int exit_code = -1;
  std::string stdout_text;
  std::string stderr_text;
  bool timed_out = false;
};

struct StreamingProcess {
  PROCESS_INFORMATION process_info{};
  HANDLE output_read = nullptr;
  HANDLE job_handle = nullptr;

  bool valid() const { return process_info.hProcess != nullptr; }
};

ProcessResult RunProcess(const std::filesystem::path& executable,
                         const std::vector<std::wstring>& args,
                         DWORD timeout_ms = INFINITE) {
  SECURITY_ATTRIBUTES security_attributes{};
  security_attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
  security_attributes.bInheritHandle = TRUE;

  HANDLE output_read = nullptr;
  HANDLE output_write = nullptr;
  if (!CreatePipe(&output_read, &output_write, &security_attributes, 0)) {
    return {};
  }
  SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);

  std::wstring command = QuoteArg(executable.wstring());
  for (const auto& arg : args) {
    command += L" ";
    command += QuoteArg(arg);
  }

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(STARTUPINFOW);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdOutput = output_write;
  startup_info.hStdError = output_write;
  startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

  PROCESS_INFORMATION process_info{};
  std::vector<wchar_t> command_buffer(command.begin(), command.end());
  command_buffer.push_back(L'\0');

  auto clean_environment = CleanProxyEnvironment();
  const BOOL created = CreateProcessW(
      nullptr, command_buffer.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, clean_environment.data(), executable.parent_path().c_str(), &startup_info,
      &process_info);

  CloseHandle(output_write);

  if (!created) {
    CloseHandle(output_read);
    return {};
  }

  std::string combined_output;
  std::thread output_reader([output_read, &combined_output]() {
    char buffer[4096];
    DWORD read = 0;
    while (ReadFile(output_read, buffer, sizeof(buffer), &read, nullptr) &&
           read > 0) {
      combined_output.append(buffer, read);
    }
  });

  const DWORD wait_result = WaitForSingleObject(process_info.hProcess, timeout_ms);
  bool timed_out = false;
  if (wait_result == WAIT_TIMEOUT) {
    timed_out = true;
    TerminateProcess(process_info.hProcess, 124);
    WaitForSingleObject(process_info.hProcess, 5000);
  }
  if (output_reader.joinable()) {
    output_reader.join();
  }

  DWORD exit_code = 0;
  GetExitCodeProcess(process_info.hProcess, &exit_code);

  CloseHandle(output_read);
  CloseHandle(process_info.hThread);
  CloseHandle(process_info.hProcess);

  return {
      !timed_out && exit_code == 0,
      static_cast<int>(exit_code),
      combined_output,
      exit_code == 0 && !timed_out ? std::string() : combined_output,
      timed_out,
  };
}

StreamingProcess StartStreamingProcess(
    const std::filesystem::path& executable,
    const std::vector<std::wstring>& args,
    const std::filesystem::path& working_directory) {
  SECURITY_ATTRIBUTES security_attributes{};
  security_attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
  security_attributes.bInheritHandle = TRUE;

  HANDLE output_read = nullptr;
  HANDLE output_write = nullptr;
  if (!CreatePipe(&output_read, &output_write, &security_attributes, 0)) {
    return {};
  }
  SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0);

  std::wstring command = QuoteArg(executable.wstring());
  for (const auto& arg : args) {
    command += L" ";
    command += QuoteArg(arg);
  }

  STARTUPINFOW startup_info{};
  startup_info.cb = sizeof(STARTUPINFOW);
  startup_info.dwFlags = STARTF_USESTDHANDLES;
  startup_info.hStdOutput = output_write;
  startup_info.hStdError = output_write;
  startup_info.hStdInput = GetStdHandle(STD_INPUT_HANDLE);

  PROCESS_INFORMATION process_info{};
  HANDLE job_handle = CreateJobObjectW(nullptr, nullptr);
  if (job_handle == nullptr) {
    CloseHandle(output_read);
    CloseHandle(output_write);
    return {};
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_info{};
  job_info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job_handle, JobObjectExtendedLimitInformation,
                               &job_info, sizeof(job_info))) {
    CloseHandle(job_handle);
    CloseHandle(output_read);
    CloseHandle(output_write);
    return {};
  }
  std::vector<wchar_t> command_buffer(command.begin(), command.end());
  command_buffer.push_back(L'\0');

  const auto working_dir = working_directory.empty()
                               ? executable.parent_path()
                               : working_directory;
  auto clean_environment = CleanProxyEnvironment();
  const BOOL created = CreateProcessW(
      nullptr, command_buffer.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, clean_environment.data(), working_dir.c_str(), &startup_info,
      &process_info);

  CloseHandle(output_write);
  if (!created) {
    CloseHandle(job_handle);
    CloseHandle(output_read);
    return {};
  }

  if (!AssignProcessToJobObject(job_handle, process_info.hProcess)) {
    TerminateProcess(process_info.hProcess, 1);
    CloseHandle(process_info.hThread);
    CloseHandle(process_info.hProcess);
    CloseHandle(job_handle);
    CloseHandle(output_read);
    return {};
  }
  ResumeThread(process_info.hThread);

  return {process_info, output_read, job_handle};
}

void CloseStreamingProcess(StreamingProcess* process) {
  if (process == nullptr) {
    return;
  }
  if (process->output_read != nullptr) {
    CloseHandle(process->output_read);
    process->output_read = nullptr;
  }
  if (process->process_info.hThread != nullptr) {
    CloseHandle(process->process_info.hThread);
    process->process_info.hThread = nullptr;
  }
  if (process->process_info.hProcess != nullptr) {
    CloseHandle(process->process_info.hProcess);
    process->process_info.hProcess = nullptr;
  }
  if (process->job_handle != nullptr) {
    CloseHandle(process->job_handle);
    process->job_handle = nullptr;
  }
}

bool TerminateStreamingProcessTree(StreamingProcess* process,
                                   UINT exit_code) {
  if (process == nullptr) {
    return false;
  }
  if (process->job_handle != nullptr) {
    return TerminateJobObject(process->job_handle, exit_code) == TRUE;
  }
  if (process->process_info.hProcess != nullptr) {
    return TerminateProcess(process->process_info.hProcess, exit_code) == TRUE;
  }
  return false;
}

std::optional<std::string> ReadFileUtf8(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input.is_open()) {
    return std::nullopt;
  }
  std::ostringstream stream;
  stream << input.rdbuf();
  return stream.str();
}

std::filesystem::path GetSessionConfigPath() {
  return GetExecutableDirectory() / "yt_dlp_session_config.json";
}

std::vector<std::wstring> BuildSessionArgs(
    const flutter::EncodableMap* session_config) {
  std::vector<std::wstring> args;
  if (session_config == nullptr) {
    return args;
  }

  const auto find_bool = [&](const char* key) -> bool {
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return false;
    }
    if (const auto* value = std::get_if<bool>(&it->second)) {
      return *value;
    }
    return false;
  };
  const auto find_string = [&](const char* key) -> std::optional<std::wstring> {
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return std::nullopt;
    }
    if (const auto* text = std::get_if<std::string>(&it->second)) {
      if (!text->empty()) {
        return Utf8ToWide(*text);
      }
    }
    return std::nullopt;
  };
  const auto find_int = [&](const char* key) -> std::optional<int> {
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return std::nullopt;
    }
    if (const auto* value = std::get_if<int32_t>(&it->second)) {
      return static_cast<int>(*value);
    }
    if (const auto* value64 = std::get_if<int64_t>(&it->second)) {
      return static_cast<int>(*value64);
    }
    return std::nullopt;
  };
  const auto find_string_list =
      [&](const char* key) -> std::vector<std::wstring> {
    std::vector<std::wstring> values;
    const auto it = session_config->find(flutter::EncodableValue(key));
    if (it == session_config->end()) {
      return values;
    }
    const auto* list = std::get_if<flutter::EncodableList>(&it->second);
    if (list == nullptr) {
      return values;
    }
    for (const auto& entry : *list) {
      if (const auto* text = std::get_if<std::string>(&entry)) {
        const auto trimmed = Trim(*text);
        if (!trimmed.empty()) {
          values.push_back(Utf8ToWide(trimmed));
        }
      }
    }
    return values;
  };
  const auto build_extractor_args = [&]() -> std::optional<std::wstring> {
    std::vector<std::wstring> parts;

    const auto clients = find_string_list("enabledPlayerClients");
    if (!clients.empty()) {
      std::wstring joined;
      for (size_t index = 0; index < clients.size(); ++index) {
        if (index > 0) {
          joined += L",";
        }
        joined += clients[index];
      }
      parts.push_back(L"player_client=" + joined);
    }

    if (const auto visitor_data = find_string("visitorData")) {
      parts.push_back(L"visitor_data=" + *visitor_data);
    }

    const auto po_tokens_it =
        session_config->find(flutter::EncodableValue("poTokens"));
    if (po_tokens_it != session_config->end()) {
      const auto* po_tokens =
          std::get_if<flutter::EncodableList>(&po_tokens_it->second);
      if (po_tokens != nullptr) {
        std::vector<std::wstring> enabled_tokens;
        for (const auto& entry : *po_tokens) {
          const auto* token_map = std::get_if<flutter::EncodableMap>(&entry);
          if (token_map == nullptr) {
            continue;
          }
          const auto get_token_string =
              [&](const char* key) -> std::optional<std::wstring> {
            const auto item = token_map->find(flutter::EncodableValue(key));
            if (item == token_map->end()) {
              return std::nullopt;
            }
            if (const auto* text = std::get_if<std::string>(&item->second)) {
              const auto trimmed = Trim(*text);
              if (!trimmed.empty()) {
                return Utf8ToWide(trimmed);
              }
            }
            return std::nullopt;
          };
          bool enabled = true;
          const auto enabled_it = token_map->find(flutter::EncodableValue("enabled"));
          if (enabled_it != token_map->end()) {
            if (const auto* enabled_value = std::get_if<bool>(&enabled_it->second)) {
              enabled = *enabled_value;
            }
          }
          const auto client = get_token_string("client");
          const auto context = get_token_string("context");
          const auto token = get_token_string("token");
          if (!enabled || !client || !context || !token) {
            continue;
          }
          enabled_tokens.push_back(*client + L"." + *context + L"+" + *token);
        }
        if (!enabled_tokens.empty()) {
          std::wstring joined;
          for (size_t index = 0; index < enabled_tokens.size(); ++index) {
            if (index > 0) {
              joined += L",";
            }
            joined += enabled_tokens[index];
          }
          parts.push_back(L"po_token=" + joined);
        }
      }
    }

    if (parts.empty()) {
      return std::nullopt;
    }
    std::wstring joined = L"youtube:";
    for (size_t index = 0; index < parts.size(); ++index) {
      if (index > 0) {
        joined += L";";
      }
      joined += parts[index];
    }
    return joined;
  };

  if (find_bool("singleVideo")) args.push_back(L"--no-playlist");
  if (const auto referer = find_string("referer")) {
    args.push_back(L"--referer"); args.push_back(*referer);
  }
  if (find_bool("useCookies")) {
    if (const auto cookies_path = find_string("cookiesFilePath")) {
      args.push_back(L"--cookies");
      args.push_back(*cookies_path);
    }
  }
  if (find_bool("useCustomUserAgent")) {
    if (const auto user_agent = find_string("userAgent")) {
      args.push_back(L"--add-header");
      args.push_back(L"User-Agent:" + *user_agent);
    }
  }
  if (find_bool("useProxy")) {
    if (const auto proxy = find_string("proxy")) {
      args.push_back(L"--proxy");
      args.push_back(*proxy);
    }
  }
  if (const auto timeout = find_int("socketTimeoutSeconds")) {
    if (*timeout > 0) {
      args.push_back(L"--socket-timeout");
      args.push_back(std::to_wstring(*timeout));
    }
  }
  if (const auto retries = find_int("retries")) {
    if (*retries > 0) {
      args.push_back(L"--retries");
      args.push_back(std::to_wstring(*retries));
    }
  }
  if (const auto fragment_retries = find_int("fragmentRetries")) {
    if (*fragment_retries > 0) {
      args.push_back(L"--fragment-retries");
      args.push_back(std::to_wstring(*fragment_retries));
    }
  }
  if (const auto fragments = find_int("concurrentFragments")) {
    if (*fragments > 0) {
      args.push_back(L"-N");
      args.push_back(std::to_wstring(*fragments));
    }
  }
  if (const auto rate_limit = find_string("rateLimit")) {
    args.push_back(L"-r");
    args.push_back(*rate_limit);
  }
  if (find_bool("forceIpv4")) {
    args.push_back(L"-4");
  }
  if (const auto extractor_args = build_extractor_args()) {
    args.push_back(L"--extractor-args");
    args.push_back(*extractor_args);
  }
  return args;
}

std::string StripWrappingQuotes(std::string value) {
  value = Trim(value);
  if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
    return value.substr(1, value.size() - 2);
  }
  return value;
}

std::string NormalizeYtDlpMarkerPath(const std::string& marker,
                                     const std::string& line) {
  const auto pos = line.find(marker);
  if (pos == std::string::npos) {
    return {};
  }
  return StripWrappingQuotes(line.substr(pos + marker.size()));
}

bool LooksLikeTemporaryArtifact(const std::filesystem::path& path) {
  const auto extension = path.extension().wstring();
  return extension == L".part" || extension == L".ytdl" || extension == L".tmp";
}

bool DumpJsonHasThumbnailKey(const std::string& json) {
  // Keep this marker aligned with dumpSingleJsonHasThumbnailKey in Dart.
  return json.find("\"thumbnail\":") != std::string::npos;
}

bool LooksLikeSubtitleSidecar(const std::filesystem::path& path) {
  static const std::set<std::wstring> extensions = {
      L".srt", L".ass", L".ssa", L".vtt", L".lrc", L".json3", L".srv1",
      L".srv2", L".srv3", L".ttml"};
  return extensions.find(path.extension().wstring()) != extensions.end();
}

}  // namespace

struct WindowsYtDlpTask {
  std::string task_id;
  std::filesystem::path output_dir;
  std::string output_template;
  StreamingProcess process;
  std::string status = "queued";
  double progress = 0.0;
  std::string speed_text;
  std::string eta_text;
  std::string output_path;
  std::vector<std::string> produced_paths;
  std::string error_code;
  std::string message;
  std::string termination_reason;
  std::deque<std::string> log_tail;
  double last_emitted_progress = -1.0;
  std::chrono::steady_clock::time_point last_progress_emit_at{};
};

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // window_manager.destroy posts WM_QUIT without destroying the HWND. In that
  // path cleanup must run while derived members and the messenger still exist;
  // the base destructor cannot dispatch OnDestroy back to this derived class.
  ShutdownEngine();
}

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
  RegisterYtDlpChannel();
  clipboard_revision_ = std::make_unique<ClipboardRevisionBridge>(
      flutter_controller_->engine()->messenger());
  desktop_media_controls_ = std::make_unique<DesktopMediaControls>(
      GetHandle(), flutter_controller_->engine()->messenger());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ImeShortcutGate::Install(GetHandle(),
                           flutter_controller_->view()->GetNativeWindow(),
                           flutter_controller_->engine()->messenger());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterYtDlpChannel() {
  yt_dlp_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), kYtDlpChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  yt_dlp_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getStorageAvailableBytes") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          if (args != nullptr) {
            const auto it = args->find(flutter::EncodableValue("path"));
            if (it != args->end()) {
              const auto* path = std::get_if<std::string>(&it->second);
              ULARGE_INTEGER available{};
              if (path != nullptr && GetDiskFreeSpaceExW(Utf8ToWide(*path).c_str(), &available, nullptr, nullptr)) {
                result->Success(flutter::EncodableValue(static_cast<int64_t>(available.QuadPart)));
                return;
              }
            }
          }
          result->Error("STORAGE_UNAVAILABLE", "Cannot query free disk space");
          return;
        }
        if (call.method_name() == "getLocalAppDataPath") {
          PWSTR folder = nullptr;
          const HRESULT hr = SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder);
          if (SUCCEEDED(hr) && folder != nullptr) {
            result->Success(flutter::EncodableValue(WideToUtf8(folder)));
          } else {
            result->Error("STORAGE_UNAVAILABLE", "Cannot resolve LocalAppData");
          }
          CoTaskMemFree(folder);
          return;
        }
        result->NotImplemented();
      });
}

void FlutterWindow::OnDestroy() {
  ShutdownEngine();
  Win32Window::OnDestroy();
}

void FlutterWindow::ShutdownEngine() {
  if (!flutter_controller_ || engine_shutdown_started_) return;
  engine_shutdown_started_ = true;
  clipboard_revision_.reset();
  desktop_media_controls_.reset();
  ImeShortcutGate::Uninstall();
  {
    std::lock_guard<std::mutex> lock(yt_dlp_mutex_);
    for (auto& entry : yt_dlp_tasks_) {
      auto& task = entry.second;
      task->termination_reason = "cancel";
      TerminateStreamingProcessTree(&task->process, 1);
    }
    yt_dlp_tasks_.clear();
    yt_dlp_event_sink_.reset();
  }
  {
    std::lock_guard<std::mutex> lock(ui_task_mutex_);
    pending_ui_tasks_.clear();
  }
  if (flutter_controller_) {
    // Plugin destructors run after Flutter has started tearing down its native
    // messenger. Drain WebView resources/channels before that phase begins.
    // The optional local export keeps the runner independent of generated
    // plugin tables and leaves older plugin binaries' registration ABI intact.
    if (flutter_controller_->engine() && flutter_controller_->view()) {
      const auto module = GetModuleHandleW(L"flutter_inappwebview_windows_plugin.dll");
      if (module) {
        using PrepareForShutdown = void (*)(FlutterDesktopPluginRegistrarRef);
        const auto prepare = reinterpret_cast<PrepareForShutdown>(GetProcAddress(
          module, "FlutterInappwebviewWindowsPluginCApiPrepareForShutdown"));
        if (prepare) {
          prepare(flutter_controller_->engine()->GetRegistrarForPlugin(
            "FlutterInappwebviewWindowsPluginCApi"));
        }
      }
    }
    flutter_controller_ = nullptr;
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (desktop_media_controls_) {
    if (const auto result = desktop_media_controls_->HandleMessage(message, wparam, lparam)) return *result;
  }
  if (const std::optional<LRESULT> ime_result =
          ImeShortcutGate::HandleTopLevelMessage(hwnd, message, wparam,
                                                 lparam)) {
    return *ime_result;
  }

  switch (message) {
    case kExecuteUiTasksMessage:
      DrainUiTasks();
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
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

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::PostUiTask(std::function<void()> task) {
  HWND handle = nullptr;
  {
    std::lock_guard<std::mutex> lock(ui_task_mutex_);
    pending_ui_tasks_.push_back(std::move(task));
    handle = GetHandle();
  }
  if (handle != nullptr) {
    PostMessage(handle, kExecuteUiTasksMessage, 0, 0);
  }
}

void FlutterWindow::DrainUiTasks() {
  std::vector<std::function<void()>> tasks;
  {
    std::lock_guard<std::mutex> lock(ui_task_mutex_);
    tasks.swap(pending_ui_tasks_);
  }
  for (auto& task : tasks) {
    if (task) {
      task();
    }
  }
}

void FlutterWindow::EmitYtDlpEvent(const flutter::EncodableMap& payload) {}

bool FlutterWindow::StartYtDlpDownload(const flutter::EncodableMap& request,
                                       std::string* error_message) { return false; }

bool FlutterWindow::PauseYtDlpDownload(const std::string& task_id) { return false; }

bool FlutterWindow::CancelYtDlpDownload(const std::string& task_id) { return false; }

bool FlutterWindow::RemoveYtDlpTask(const std::string& task_id) { return false; }

std::unique_ptr<flutter::EncodableValue> FlutterWindow::GetYtDlpTaskStatus(
    const std::string& task_id) { return nullptr; }

void FlutterWindow::MonitorYtDlpTask(
    const std::shared_ptr<WindowsYtDlpTask>& task) {}

void FlutterWindow::HandleYtDlpOutput(
    const std::shared_ptr<WindowsYtDlpTask>& task,
    const std::string& line) {}
