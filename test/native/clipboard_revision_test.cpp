#include <windows.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <cstring>
#include <iostream>
#include <map>
#include <stdexcept>

#include "../../windows/runner/clipboard_revision.h"

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;
constexpr char kChannel[] = "com.example.video_player_app/clipboard_revision";

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

class Messenger : public flutter::BinaryMessenger {
 public:
  std::map<std::string, flutter::BinaryMessageHandler> handlers;
  void Send(const std::string&, const uint8_t*, size_t,
            flutter::BinaryReply reply) const override {
    if (reply) reply(nullptr, 0);
  }
  void SetMessageHandler(const std::string& channel,
                         flutter::BinaryMessageHandler handler) override {
    handlers[channel] = std::move(handler);
  }
  EncodableMap Read() {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    const auto bytes = codec.EncodeMethodCall(
        flutter::MethodCall<EncodableValue>("getRevision", nullptr));
    EncodableMap result;
    bool completed = false;
    flutter::MethodResultFunctions<EncodableValue> capture(
        [&](const EncodableValue* value) {
          completed = true;
          Check(value != nullptr && std::holds_alternative<EncodableMap>(*value),
                "No clipboard revision returned");
          result = std::get<EncodableMap>(*value);
        },
        [](const auto&, const auto&, const auto*) {
          throw std::runtime_error("Native revision error");
        },
        []() { throw std::runtime_error("Revision channel is not registered"); });
    handlers.at(kChannel)(bytes->data(), bytes->size(),
        [&](const uint8_t* data, size_t size) {
          codec.DecodeAndProcessResponseEnvelope(data, size, &capture);
        });
    Check(completed, "Missing method reply");
    return result;
  }
};

void Copy(HWND owner, const wchar_t* text) {
  const size_t size = (wcslen(text) + 1) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
  Check(memory != nullptr, "Clipboard allocation failed");
  void* bytes = GlobalLock(memory);
  Check(bytes != nullptr, "Clipboard memory lock failed");
  std::memcpy(bytes, text, size);
  GlobalUnlock(memory);
  Check(OpenClipboard(owner) != FALSE, "Cannot open private clipboard");
  const bool success = EmptyClipboard() != FALSE &&
      SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
  CloseClipboard();
  if (!success) GlobalFree(memory);
  Check(success, "Cannot write private clipboard");
}

std::string Token(const EncodableMap& value) {
  Check(std::get<bool>(value.at(EncodableValue("persistent"))),
        "Boot/logon scope should be durable on this Windows host");
  return std::get<std::string>(value.at(EncodableValue("token")));
}
}  // namespace

int main() {
  // Test in an invisible, private window station. The user's clipboard is
  // never opened, copied, cleared, backed up or restored by this probe.
  const HWINSTA original_station = GetProcessWindowStation();
  const HDESK original_desktop = GetThreadDesktop(GetCurrentThreadId());
  HWINSTA station = nullptr;
  HDESK desktop = nullptr;
  HWND owner = nullptr;
  auto cleanup = [&]() {
    if (owner) DestroyWindow(owner);
    SetProcessWindowStation(original_station);
    SetThreadDesktop(original_desktop);
    if (desktop) CloseDesktop(desktop);
    if (station) CloseWindowStation(station);
  };
  try {
    station = CreateWindowStationW(nullptr, 0, WINSTA_ALL_ACCESS, nullptr);
    Check(station != nullptr, "Cannot create isolated window station");
    Check(SetProcessWindowStation(station) != FALSE, "Cannot select private station");
    desktop = CreateDesktopW(L"clipboard-probe", nullptr, nullptr, 0,
                              GENERIC_ALL, nullptr);
    Check(desktop != nullptr && SetThreadDesktop(desktop) != FALSE,
          "Cannot select private desktop");
    owner = CreateWindowExW(0, L"STATIC", L"clipboard-probe", WS_POPUP,
                            0, 0, 1, 1, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    Check(owner != nullptr, "Cannot create private clipboard owner");
    Messenger messenger;
    std::string last_token;
    {
      ClipboardRevisionBridge bridge(&messenger);
      Copy(owner, L"https://example.org/a?signature=Ab%2bCd%3d");
      const auto first = Token(messenger.Read());
      Check(Token(messenger.Read()) == first, "Reading changed the revision");
      Copy(owner, L"https://example.org/a?signature=Ab%2bCd%3d");
      const auto recopied = Token(messenger.Read());
      Check(recopied != first, "Recopying the same text did not change revision");
      Copy(owner, L"https://example.org/b");
      const auto other = Token(messenger.Read());
      Copy(owner, L"https://example.org/a?signature=Ab%2bCd%3d");
      last_token = Token(messenger.Read());
      Check(last_token != other, "A-B-A reused an old revision");
    }
    Check(!messenger.handlers.at(kChannel), "Disposed channel retained its handler");
    {
      ClipboardRevisionBridge recreated(&messenger);
      const auto current = Token(messenger.Read());
      Check(current == last_token, "Recreating the bridge changed its boot/logon scope");
      Check(Token(messenger.Read()) == current, "Recreated bridge changed revision");
    }
    cleanup();
    std::cout << "Windows clipboard revision checks passed (isolated clipboard).\n";
    return 0;
  } catch (const std::exception& error) {
    cleanup();
    std::cerr << error.what() << '\n';
    return 1;
  }
}
