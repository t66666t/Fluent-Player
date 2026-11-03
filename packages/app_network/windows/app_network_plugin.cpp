#include "include/app_network/app_network_plugin_c_api.h"
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <winhttp.h>
#include <iphlpapi.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>
#include <deque>

namespace {
using Value = flutter::EncodableValue;
constexpr UINT kDispatch = WM_APP + 0x482;
std::wstring Wide(const std::string& s) {
  if (s.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring r(n, 0); MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), r.data(), n); return r;
}
std::string Utf8(const std::wstring& s) {
  if (s.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
  std::string r(n, 0); WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), r.data(), n, nullptr, nullptr); return r;
}
std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), towlower); return value;
}
bool Glob(const std::wstring& text, const std::wstring& pattern) {
  size_t t = 0, p = 0, star = std::wstring::npos, retry = 0;
  while (t < text.size()) {
    if (p < pattern.size() && (pattern[p] == L'?' || pattern[p] == text[t])) { ++t; ++p; }
    else if (p < pattern.size() && pattern[p] == L'*') { star = p++; retry = t; }
    else if (star != std::wstring::npos) { p = star + 1; t = ++retry; }
    else return false;
  }
  while (p < pattern.size() && pattern[p] == L'*') ++p;
  return p == pattern.size();
}
struct UserProxy {
  WINHTTP_CURRENT_USER_IE_PROXY_CONFIG value{};
  UserProxy() { if (!WinHttpGetIEProxyConfigForCurrentUser(&value)) throw std::runtime_error("proxy settings unavailable"); }
  ~UserProxy() {
    if (value.lpszAutoConfigUrl) GlobalFree(value.lpszAutoConfigUrl);
    if (value.lpszProxy) GlobalFree(value.lpszProxy);
    if (value.lpszProxyBypass) GlobalFree(value.lpszProxyBypass);
  }
};
bool Bypass(const std::wstring& host, const std::wstring& port, const wchar_t* rules) {
  if (!rules) return false;
  std::wstringstream input(Lower(rules)); std::wstring rule;
  while (std::getline(input, rule, L';')) {
    const auto first = rule.find_first_not_of(L" \t");
    if (first == std::wstring::npos) continue;
    rule = rule.substr(first, rule.find_last_not_of(L" \t") - first + 1);
    if (rule == L"<local>" && host.find(L'.') == std::wstring::npos && host.find(L':') == std::wstring::npos) return true;
    if (Glob(host, rule) || Glob(host + L":" + port, rule)) return true;
  }
  return false;
}
flutter::EncodableList ParseProxy(const std::wstring& proxy, const std::wstring& scheme) {
  flutter::EncodableList values;
  std::wstringstream input(proxy); std::wstring part;
  std::wstring selected, socks, unkeyed;
  while (std::getline(input, part, L';')) {
    const auto equal = part.find(L'=');
    if (equal == std::wstring::npos) { unkeyed += L" " + part; }
    else {
      auto key = Lower(part.substr(0, equal));
      if (key == scheme) selected = part.substr(equal + 1);
      if (key == L"socks") socks = part.substr(equal + 1);
    }
  }
  if (selected.empty()) selected = unkeyed;
  bool is_socks = selected.find_first_not_of(L" \t") == std::wstring::npos && !socks.empty();
  if (is_socks) selected = socks;
  std::wstringstream servers(selected);
  while (servers >> part) {
    if (Lower(part) == L"direct") values.emplace_back("DIRECT");
    else values.emplace_back(Utf8(part.find(L"://") != std::wstring::npos ? part :
      (is_socks ? L"socks5://" : L"http://") + part));
  }
  if (values.empty()) values.emplace_back("DIRECT");
  return values;
}
struct PacState {
  std::mutex mutex;
  std::condition_variable completed;
  std::atomic<int> references{2}; // Worker and asynchronous resolver handle.
  bool done = false;
  DWORD error = ERROR_SUCCESS;
  void Release() { if (--references == 0) delete this; }
};
void CALLBACK PacCallback(HINTERNET, DWORD_PTR context, DWORD status, void* information, DWORD) {
  auto* state = reinterpret_cast<PacState*>(context);
  if (!state) return;
  if (status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING) { state->Release(); return; }
  if (status != WINHTTP_CALLBACK_STATUS_GETPROXYFORURL_COMPLETE && status != WINHTTP_CALLBACK_STATUS_REQUEST_ERROR) return;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (status == WINHTTP_CALLBACK_STATUS_REQUEST_ERROR) state->error = static_cast<WINHTTP_ASYNC_RESULT*>(information)->dwError;
    state->done = true;
  }
  state->completed.notify_all();
}
flutter::EncodableList ResolvePAC(const std::wstring& url, WINHTTP_AUTOPROXY_OPTIONS& options, DWORD& error) {
  HINTERNET session = WinHttpOpen(L"FluentPlayer/1.0", WINHTTP_ACCESS_TYPE_NO_PROXY,
    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, WINHTTP_FLAG_ASYNC);
  if (!session) { error = GetLastError(); return {}; }
  WinHttpSetTimeouts(session, 5000, 5000, 10000, 10000);
  HINTERNET resolver = nullptr;
  error = WinHttpCreateProxyResolver(session, &resolver);
  if (error != ERROR_SUCCESS) { WinHttpCloseHandle(session); return {}; }
  auto* state = new PacState;
  DWORD_PTR context = reinterpret_cast<DWORD_PTR>(state);
  if (!WinHttpSetOption(resolver, WINHTTP_OPTION_CONTEXT_VALUE, &context, sizeof(context)) ||
      WinHttpSetStatusCallback(resolver, PacCallback,
        WINHTTP_CALLBACK_FLAG_REQUEST_ERROR | WINHTTP_CALLBACK_FLAG_GETPROXYFORURL_COMPLETE | WINHTTP_CALLBACK_FLAG_HANDLES, 0)
        == WINHTTP_INVALID_STATUS_CALLBACK) {
    error = GetLastError(); WinHttpCloseHandle(resolver); WinHttpCloseHandle(session); delete state; return {};
  }
  error = WinHttpGetProxyForUrlEx(resolver, url.c_str(), &options, context);
  if (error == ERROR_IO_PENDING) {
    std::unique_lock<std::mutex> lock(state->mutex);
    if (!state->completed.wait_for(lock, std::chrono::seconds(15), [state] { return state->done; })) error = ERROR_WINHTTP_TIMEOUT;
    else error = state->error;
  }
  flutter::EncodableList routes;
  if (error == ERROR_SUCCESS) {
    WINHTTP_PROXY_RESULT result{};
    error = WinHttpGetProxyResult(resolver, &result);
    if (error == ERROR_SUCCESS) {
      for (DWORD i = 0; i < result.cEntries; ++i) {
        const auto& entry = result.pEntries[i];
        if (!entry.fProxy || entry.fBypass) { routes.emplace_back("DIRECT"); continue; }
        std::wstring host = entry.pwszProxy ? entry.pwszProxy : L"";
        if (host.empty()) { error = ERROR_WINHTTP_INVALID_URL; break; }
        if (host.find(L':') != std::wstring::npos && host.front() != L'[') host = L"[" + host + L"]";
        const std::wstring protocol = entry.ProxyScheme == INTERNET_SCHEME_SOCKS ? L"socks5://" :
          entry.ProxyScheme == INTERNET_SCHEME_HTTPS ? L"https://" : L"http://";
        routes.emplace_back(Utf8(protocol + host + L":" + std::to_wstring(entry.ProxyPort)));
      }
      WinHttpFreeProxyResult(&result);
      if (routes.empty() && error == ERROR_SUCCESS) routes.emplace_back("DIRECT");
    }
  }
  WinHttpCloseHandle(resolver); WinHttpCloseHandle(session);
  state->Release(); // HANDLE_CLOSING releases the callback's reference.
  return routes;
}
flutter::EncodableList Resolve(const std::wstring& url) {
  URL_COMPONENTS parts{}; parts.dwStructSize = sizeof(parts);
  parts.dwHostNameLength = static_cast<DWORD>(-1); parts.dwSchemeLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(url.c_str(), 0, 0, &parts)) throw std::runtime_error("invalid URL");
  const std::wstring host = Lower(std::wstring(parts.lpszHostName, parts.dwHostNameLength));
  const std::wstring scheme = Lower(std::wstring(parts.lpszScheme, parts.dwSchemeLength));
  UserProxy user;
  if (Bypass(host, std::to_wstring(parts.nPort), user.value.lpszProxyBypass)) return {Value("DIRECT")};
  if (user.value.lpszAutoConfigUrl || user.value.fAutoDetect) {
    WINHTTP_AUTOPROXY_OPTIONS options{};
    options.fAutoLogonIfChallenged = TRUE;
    if (user.value.lpszAutoConfigUrl) { options.dwFlags |= WINHTTP_AUTOPROXY_CONFIG_URL; options.lpszAutoConfigUrl = user.value.lpszAutoConfigUrl; }
    if (user.value.fAutoDetect) { options.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT; options.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A; }
    DWORD error = ERROR_SUCCESS;
    auto result = ResolvePAC(url, options, error);
    if (error == ERROR_SUCCESS) return result;
    // No WPAD server is a normal device configuration. An explicit PAC failure
    // is reported instead of silently escaping a configured proxy.
    if (user.value.lpszAutoConfigUrl || error != ERROR_WINHTTP_AUTODETECTION_FAILED) {
      throw std::runtime_error("PAC resolution failed");
    }
  }
  return user.value.lpszProxy ? ParseProxy(user.value.lpszProxy, scheme) : flutter::EncodableList{Value("DIRECT")};
}
std::wstring Signature() {
  std::wstring result;
  try {
    UserProxy user; result = std::to_wstring(user.value.fAutoDetect);
    for (const auto s : {user.value.lpszAutoConfigUrl, user.value.lpszProxy, user.value.lpszProxyBypass}) if (s) result += s;
  } catch (...) {}
  ULONG size = 16384; std::vector<unsigned char> buffer(size);
  auto* adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  auto status = GetAdaptersAddresses(AF_UNSPEC, 0, nullptr, adapters, &size);
  if (status == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size); adapters = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    status = GetAdaptersAddresses(AF_UNSPEC, 0, nullptr, adapters, &size);
  }
  if (status == NO_ERROR) {
    for (auto* adapter = adapters; adapter; adapter = adapter->Next) {
      result += std::to_wstring(adapter->IfIndex) + L":" + std::to_wstring(adapter->OperStatus);
      auto appendAddress = [&result](const SOCKET_ADDRESS& address) {
        if (!address.lpSockaddr) return;
        const unsigned char* bytes = nullptr; size_t count = 0;
        if (address.lpSockaddr->sa_family == AF_INET) {
          bytes = reinterpret_cast<const unsigned char*>(&reinterpret_cast<const sockaddr_in*>(address.lpSockaddr)->sin_addr); count = 4;
        } else if (address.lpSockaddr->sa_family == AF_INET6) {
          bytes = reinterpret_cast<const unsigned char*>(&reinterpret_cast<const sockaddr_in6*>(address.lpSockaddr)->sin6_addr); count = 16;
        }
        result += L"/";
        for (size_t i = 0; i < count; ++i) result += std::to_wstring(bytes[i]) + L",";
      };
      for (auto* entry = adapter->FirstUnicastAddress; entry; entry = entry->Next) appendAddress(entry->Address);
      for (auto* entry = adapter->FirstDnsServerAddress; entry; entry = entry->Next) appendAddress(entry->Address);
    }
  }
  return result;
}

class AppNetworkPlugin : public flutter::Plugin {
 public:
  explicit AppNetworkPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {
    for (int i = 0; i < 4; ++i) workers_.emplace_back([this] {
      while (true) {
        std::function<void()> job;
        {
          std::unique_lock<std::mutex> lock(jobs_mutex_);
          jobs_ready_.wait(lock, [this] { return stopping_.load() || !jobs_.empty(); });
          if (stopping_) return;
          job = std::move(jobs_.front()); jobs_.pop_front();
        }
        job();
      }
    });
    // Registration precedes attaching Flutter's child HWND to the runner.
    // Resolve its root when dispatching, after SetChildContent has run.
    window_ = registrar->GetView()->GetNativeWindow();
    delegate_ = registrar->RegisterTopLevelWindowProcDelegate([this](HWND, UINT message, WPARAM wparam, LPARAM) -> std::optional<LRESULT> {
      if (message != kDispatch || wparam != reinterpret_cast<WPARAM>(this)) return std::nullopt;
      std::vector<std::function<void()>> tasks;
      { std::lock_guard<std::mutex> lock(mutex_); tasks.swap(pending_); }
      for (auto& task : tasks) task();
      return 0;
    });
    methods_ = std::make_unique<flutter::MethodChannel<Value>>(registrar->messenger(),
      "com.example.video_player_app/network", &flutter::StandardMethodCodec::GetInstance());
    methods_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
      if (call.method_name() != "resolveProxy") { result->NotImplemented(); return; }
      auto args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (!args || args->find(Value("url")) == args->end()) { result->Error("INVALID_URL", "缺少网址"); return; }
      const auto* url = std::get_if<std::string>(&args->at(Value("url")));
      if (!url) { result->Error("INVALID_URL", "缺少网址"); return; }
      auto reply = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
      std::wstring target = Wide(*url);
      {
        std::lock_guard<std::mutex> lock(jobs_mutex_);
        jobs_.emplace_back([this, reply, target] {
        try { auto routes = Resolve(target); Post([reply, routes] { reply->Success(Value(routes)); }); }
        catch (...) { Post([reply] { reply->Error("PROXY_RESOLUTION_FAILED", "无法读取系统代理"); }); }
        });
      }
      jobs_ready_.notify_one();
    });
    events_ = std::make_unique<flutter::EventChannel<Value>>(registrar->messenger(),
      "com.example.video_player_app/network_events", &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
      [this](const Value*, std::unique_ptr<flutter::EventSink<Value>>&& sink) {
        sink_ = std::move(sink); return nullptr;
      }, [this](const Value*) { sink_.reset(); return nullptr; }));
    monitor_ = std::thread([this] {
      auto last = Signature(); std::unique_lock<std::mutex> lock(wake_mutex_);
      while (!wake_.wait_for(lock, std::chrono::seconds(2), [this] { return stopping_.load(); })) {
        auto next = Signature();
        if (next != last) { last = next; Post([this] { if (sink_) sink_->Success(Value(true)); }); }
      }
    });
  }
  ~AppNetworkPlugin() override {
    stopping_ = true; wake_.notify_all(); jobs_ready_.notify_all();
    if (monitor_.joinable()) monitor_.join();
    for (auto& thread : workers_) if (thread.joinable()) thread.join();
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }
 private:
  void Post(std::function<void()> task) {
    if (stopping_) return;
    { std::lock_guard<std::mutex> lock(mutex_); pending_.push_back(std::move(task)); }
    PostMessage(GetAncestor(window_, GA_ROOT), kDispatch, reinterpret_cast<WPARAM>(this), 0);
  }
  flutter::PluginRegistrarWindows* registrar_;
  HWND window_; int delegate_;
  std::atomic<bool> stopping_{false};
  std::mutex mutex_, wake_mutex_;
  std::condition_variable wake_;
  std::mutex jobs_mutex_;
  std::condition_variable jobs_ready_;
  std::deque<std::function<void()>> jobs_;
  std::vector<std::function<void()>> pending_;
  std::vector<std::thread> workers_;
  std::thread monitor_;
  std::unique_ptr<flutter::MethodChannel<Value>> methods_;
  std::unique_ptr<flutter::EventChannel<Value>> events_;
  std::unique_ptr<flutter::EventSink<Value>> sink_;
};
}
void AppNetworkPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  auto* windows = flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar);
  windows->AddPlugin(std::make_unique<AppNetworkPlugin>(windows));
}
