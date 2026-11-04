#include "clipboard_revision.h"

#include <Windows.h>
#include <flutter/standard_method_codec.h>

#include <cstdint>

namespace {

// BootIdentifier distinguishes sequence numbers reused after a system reboot.
// Query dynamically and fall back to a process-scoped revision if unavailable.
std::string ClipboardScope(bool* persistent) {
  struct BootEnvironment {
    GUID identifier;
    ULONG firmware_type;
    ULONGLONG boot_flags;
  } boot{};
  using QuerySystemInformation = LONG(NTAPI*)(ULONG, PVOID, ULONG, PULONG);
  const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
  const auto query = ntdll == nullptr ? nullptr :
      reinterpret_cast<QuerySystemInformation>(
          GetProcAddress(ntdll, "NtQuerySystemInformation"));
  HANDLE process_token = nullptr;
  TOKEN_STATISTICS statistics{};
  DWORD size = 0;
  const bool has_token =
      OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &process_token) != FALSE;
  const bool has_logon = has_token &&
      GetTokenInformation(process_token, TokenStatistics, &statistics,
                          sizeof(statistics), &size) != FALSE;
  if (has_token) CloseHandle(process_token);
  if (query == nullptr || query(90, &boot, sizeof(boot), nullptr) < 0 ||
      !has_logon) {
    *persistent = false;
    return "windows/process/" + std::to_string(GetCurrentProcessId());
  }
  constexpr char hex[] = "0123456789abcdef";
  std::string scope = "windows/";
  const auto* bytes = reinterpret_cast<const unsigned char*>(&boot.identifier);
  for (size_t i = 0; i < sizeof(boot.identifier); ++i) {
    scope += hex[bytes[i] >> 4];
    scope += hex[bytes[i] & 15];
  }
  scope += "/" + std::to_string(statistics.AuthenticationId.HighPart) + ":" +
           std::to_string(statistics.AuthenticationId.LowPart);
  wchar_t station[256]{};
  if (!GetUserObjectInformationW(GetProcessWindowStation(), UOI_NAME, station,
                                 sizeof(station), &size)) {
    *persistent = false;
  } else {
    *persistent = true;
    for (const wchar_t* ch = station; *ch != L'\0'; ++ch) {
      scope += "/" + std::to_string(static_cast<unsigned int>(*ch));
    }
  }
  return scope;
}

}  // namespace

ClipboardRevisionBridge::ClipboardRevisionBridge(
    flutter::BinaryMessenger* messenger) {
  scope_ = ClipboardScope(&persistent_);
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.example.video_player_app/clipboard_revision",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "getRevision") {
          result->NotImplemented();
          return;
        }
        const DWORD sequence = GetClipboardSequenceNumber();
        if (sequence == 0) {
          result->Success();
          return;
        }
        flutter::EncodableMap value;
        value[flutter::EncodableValue("token")] = flutter::EncodableValue(
            scope_ + "/" + std::to_string(sequence));
        value[flutter::EncodableValue("persistent")] =
            flutter::EncodableValue(persistent_);
        result->Success(flutter::EncodableValue(value));
      });
}

ClipboardRevisionBridge::~ClipboardRevisionBridge() {
  channel_->SetMethodCallHandler(nullptr);
}
