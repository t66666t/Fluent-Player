#include <windows.h>
#include <roapi.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <propkey.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Media.Control.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <cstdint>
#include <iostream>
#include <map>
#include <stdexcept>
#include "../../windows/runner/desktop_media_controls.h"
#include "../../windows/runner/desktop_media_toolbar_cache.h"
#include "../../windows/runner/desktop_app_identity.h"

using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace winrt::Windows::Media;

void Check(bool valid, const char* message) {
  if (!valid) throw std::runtime_error(message);
}
template <typename Operation>
auto Await(const Operation& operation) {
  const auto deadline = GetTickCount64() + 10000;
  while (operation.Status() == winrt::Windows::Foundation::AsyncStatus::Started && GetTickCount64() < deadline) {
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessage(&message);
    Sleep(1);
  }
  Check(operation.Status() == winrt::Windows::Foundation::AsyncStatus::Completed, "Windows asynchronous media operation failed or timed out");
  return operation.GetResults();
}
class Messenger : public flutter::BinaryMessenger {
 public:
  std::map<std::string, flutter::BinaryMessageHandler> handlers;
  mutable std::vector<EncodableMap> events;
  void Send(const std::string&, const uint8_t* message, size_t size, flutter::BinaryReply reply) const override {
    const auto call = flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(message, size);
    if (call && call->method_name() == "command") events.push_back(std::get<EncodableMap>(*call->arguments()));
    if (reply) {
      const auto envelope = flutter::StandardMethodCodec::GetInstance().EncodeSuccessEnvelope();
      reply(envelope->data(), envelope->size());
    }
  }
  void SetMessageHandler(const std::string& channel, flutter::BinaryMessageHandler handler) override {
    handlers[channel] = std::move(handler);
  }
  EncodableMap Call(const std::string& name, const EncodableMap& args = {}) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    const auto bytes = codec.EncodeMethodCall(flutter::MethodCall<EncodableValue>(name, std::make_unique<EncodableValue>(args)));
    EncodableMap result;
    bool completed = false;
    flutter::MethodResultFunctions<EncodableValue> capture(
      [&](const EncodableValue* value) { completed = true; if (value && std::holds_alternative<EncodableMap>(*value)) result = std::get<EncodableMap>(*value); },
      [](const auto&, const auto&, const auto*) { throw std::runtime_error("native method error"); },
      []() { throw std::runtime_error("native method missing"); });
    handlers.at("com.example.video_player_app/desktop_media")(bytes->data(), bytes->size(), [&](const uint8_t* data, size_t size) {
      codec.DecodeAndProcessResponseEnvelope(data, size, &capture);
    });
    Check(completed, "method reply missing");
    return result;
  }
};

DesktopMediaControls* control = nullptr;
LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  if (control) if (const auto result = control->HandleMessage(message, wparam, lparam)) return *result;
  return DefWindowProc(hwnd, message, wparam, lparam);
}
bool Flag(const EncodableMap& map, const char* key) { return std::get<bool>(map.at(EncodableValue(key))); }
void Set(EncodableMap& map, const char* key, const EncodableValue& value) { map[EncodableValue(key)] = value; }

void CheckToolbarPublicationCache() {
  ToolbarUpdateCache cache;
  ToolbarUpdateCache::Buttons buttons{};
  for (size_t i = 0; i < buttons.size(); ++i) {
    buttons[i].dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    buttons[i].iId = static_cast<UINT>(i);
    buttons[i].hIcon = reinterpret_cast<HICON>(static_cast<uintptr_t>(1));
    wcscpy_s(buttons[i].szTip, L"Play");
    buttons[i].dwFlags = THBF_ENABLED;
  }
  std::vector<bool> updates;
  HRESULT next_result = S_OK;
  const auto submit = [&](bool added) {
    updates.push_back(added);
    return next_result;
  };
  cache.Publish(buttons, submit);
  Check(updates.size() == 1 && !updates.back(), "first toolbar publication must add buttons");
  for (int i = 0; i < 100; ++i) cache.Publish(buttons, submit);
  Check(updates.size() == 1, "position-only updates republish unchanged toolbar buttons");

  const auto changed = [&](const ToolbarUpdateCache::Buttons& value, const char* message) {
    const auto before = updates.size();
    cache.Publish(value, submit);
    Check(updates.size() == before + 1 && updates.back(), message);
    cache.Publish(value, submit);
    Check(updates.size() == before + 1, "successful toolbar state was not cached");
    buttons = value;
  };
  auto value = buttons;
  value[5].dwMask = THB_BITMAP | THB_ICON | THB_TOOLTIP | THB_FLAGS;
  changed(value, "toolbar mask change was lost");
  value[5].iId += 10;
  changed(value, "toolbar command ID change was lost");
  value[5].iBitmap = 2;
  changed(value, "toolbar bitmap change was lost");
  for (size_t i = 0; i < buttons.size(); ++i) {
    value[i].hIcon = reinterpret_cast<HICON>(static_cast<uintptr_t>(2));
    changed(value, "toolbar icon change was lost");
    wcscpy_s(value[i].szTip, L"Pause");
    changed(value, "toolbar tooltip change was lost");
    value[i].dwFlags = THBF_DISABLED;
    changed(value, "toolbar capability change was lost");
  }
  value[0].dwFlags = THBF_HIDDEN;
  next_result = E_FAIL;
  auto before = updates.size();
  cache.Publish(value, submit);
  cache.Publish(value, submit);
  Check(updates.size() == before + 2 && updates.back(), "failed toolbar updates must retry");
  cache.Publish(buttons, submit);
  Check(updates.size() == before + 2, "failed update must retain the last successful toolbar state");
  next_result = S_OK;
  cache.Publish(value, submit);
  cache.Publish(value, submit);
  Check(updates.size() == before + 3, "successful retry was not cached");

  cache.Invalidate();
  next_result = E_FAIL;
  before = updates.size();
  cache.Publish(value, submit);
  Check(updates.size() == before + 1 && !updates.back(), "Explorer recreation must add the toolbar again");
  cache.Publish(value, submit);
  Check(updates.size() == before + 2 && !updates.back(), "failed toolbar adds must retry as adds");
  next_result = S_OK;
  cache.Publish(value, submit);
  cache.Publish(value, submit);
  Check(updates.size() == before + 3 && !updates.back(), "successful toolbar add retry was not cached");
  std::cout << "PASS: unchanged toolbar publication suppressed; button changes, failure retries and Explorer recreation preserved\n";
}

int main() {
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  HWND window = nullptr, other = nullptr;
  const auto test_id = std::wstring(kDesktopAppId) + L".Test." + std::to_wstring(GetCurrentProcessId());
  const auto test_name = L"Fluent Player media test " + std::to_wstring(GetCurrentProcessId());
  const auto test_key = std::wstring(L"Software\\Classes\\AppUserModelId\\") + test_id;
  std::wstring test_link, test_directory;
  auto cleanup_identity = [&]() {
    RegDeleteTreeW(HKEY_CURRENT_USER, test_key.c_str());
    if (!test_link.empty()) DeleteFileW(test_link.c_str());
    if (!test_directory.empty()) RemoveDirectoryW(test_directory.c_str());
  };
  try {
    CheckToolbarPublicationCache();
    wchar_t executable[32768]{}, artwork[32768]{};
    GetModuleFileNameW(nullptr, executable, ARRAYSIZE(executable));
    GetFullPathNameW(L"android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png", ARRAYSIZE(artwork), artwork, nullptr);
    RegisterDesktopAppIdentity(test_id, test_name, executable, artwork);
    PWSTR process_id = nullptr;
    Check(SUCCEEDED(GetCurrentProcessExplicitAppUserModelID(&process_id)) && test_id == process_id, "process identity missing");
    CoTaskMemFree(process_id);
    PWSTR programs = nullptr;
    winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs));
    test_directory = std::wstring(programs) + L"\\" + test_name;
    CoTaskMemFree(programs);
    test_link = test_directory + L"\\" + test_name + L".lnk";
    winrt::com_ptr<IShellLinkW> shortcut;
    winrt::check_hresult(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(shortcut.put())));
    winrt::check_hresult(shortcut.as<IPersistFile>()->Load(test_link.c_str(), STGM_READ));
    PROPVARIANT value{};
    winrt::check_hresult(shortcut.as<IPropertyStore>()->GetValue(PKEY_AppUserModel_ID, &value));
    Check(value.vt == VT_LPWSTR && test_id == value.pwszVal, "shortcut identity missing");
    PropVariantClear(&value);
    wchar_t registered_name[256]{}, registered_icon[32768]{};
    DWORD size = sizeof(registered_name);
    Check(RegGetValueW(HKEY_CURRENT_USER, test_key.c_str(), L"DisplayName", RRF_RT_REG_SZ, nullptr, registered_name, &size) == ERROR_SUCCESS && test_name == registered_name, "Shell display name missing");
    size = sizeof(registered_icon);
    Check(RegGetValueW(HKEY_CURRENT_USER, test_key.c_str(), L"IconUri", RRF_RT_REG_SZ, nullptr, registered_icon, &size) == ERROR_SUCCESS && std::wstring(artwork) == registered_icon, "Shell icon missing");
    winrt::com_ptr<IShellItem> shell_app;
    const auto shell_deadline = GetTickCount64() + 10000;
    while (GetTickCount64() < shell_deadline) {
      if (SUCCEEDED(SHCreateItemInKnownFolder(FOLDERID_AppsFolder, 0, test_id.c_str(), IID_PPV_ARGS(shell_app.put())))) break;
      MSG message;
      while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessage(&message);
      Sleep(50);
    }
    Check(shell_app != nullptr, "Shell cannot resolve the application ID");
    PWSTR shell_name = nullptr;
    winrt::check_hresult(shell_app->GetDisplayName(SIGDN_NORMALDISPLAY, &shell_name));
    const bool name_resolved = test_name == shell_name;
    CoTaskMemFree(shell_name);
    Check(name_resolved, "Shell application name differs from the registered name");
    WNDCLASSW type{};
    type.lpfnWndProc = WindowProc;
    type.hInstance = GetModuleHandle(nullptr);
    type.lpszClassName = L"FluentDesktopMediaTest";
    RegisterClassW(&type);
    window = CreateWindowW(type.lpszClassName, L"Fluent media native test", WS_OVERLAPPEDWINDOW, 0, 0, 320, 180, nullptr, nullptr, type.hInstance, nullptr);
    other = CreateWindowW(type.lpszClassName, L"conflict owner", WS_OVERLAPPEDWINDOW, 0, 0, 100, 100, nullptr, nullptr, type.hInstance, nullptr);
    Check(window && other, "test windows not created");
    Messenger messenger;
    {
      DesktopMediaControls bridge(window, &messenger);
      control = &bridge;
      auto status = messenger.Call("initialize");
      Check(Flag(status, "systemMedia"), "SMTC unavailable");
      Check(Flag(status, "taskbar"), "taskbar unavailable");
      EncodableMap state;
      for (const auto key : {"active", "playing", "canPlay", "canPrevious", "canNext", "systemEnabled", "taskbarEnabled"}) Set(state, key, EncodableValue(true));
      Set(state, "title", EncodableValue("Native probe title"));
      Set(state, "itemId", EncodableValue("probe"));
      Set(state, "subtitle", EncodableValue("Native probe artist"));
      Set(state, "durationMs", EncodableValue(int64_t{60000}));
      Set(state, "positionMs", EncodableValue(int64_t{12000}));
      Set(state, "hotkeyModifiers", EncodableValue("ctrl+alt+shift"));
      Set(state, "hotkeysEnabled", EncodableValue(false));
      Set(state, "canSeek", EncodableValue(true));
      Set(state, "playbackMode", EncodableValue("shuffle"));
      Set(state, "playlistWrap", EncodableValue(true));
      Set(state, "artworkPath", EncodableValue("android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png"));
      status = messenger.Call("update", state);
      auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
      SystemMediaTransportControls smtc{nullptr};
      winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(smtc)));
      Check(smtc.IsEnabled(), "SMTC did not enable");
      Check(smtc.PlaybackStatus() == MediaPlaybackStatus::Playing, "SMTC playing state mismatch");
      Check(smtc.DisplayUpdater().MusicProperties().Title() == L"Native probe title", "SMTC metadata mismatch");
      Check(smtc.IsRewindEnabled() && smtc.IsFastForwardEnabled(), "seek capabilities missing");
      Check(smtc.ShuffleEnabled() && smtc.AutoRepeatMode() == MediaPlaybackAutoRepeatMode::List, "queue state mismatch");
      auto thumbnail = smtc.DisplayUpdater().Thumbnail();
      Check(thumbnail != nullptr, "artwork stream missing");
      Check(Await(thumbnail.OpenReadAsync()).Size() > 0, "OS cannot read the artwork snapshot");
      // Read the actual OS session, including the app identity Windows exposes
      // to media clients, then request changes through the real SMTC API.
      using namespace winrt::Windows::Media::Control;
      const auto manager = Await(GlobalSystemMediaTransportControlsSessionManager::RequestAsync());
      GlobalSystemMediaTransportControlsSession session{nullptr};
      const auto session_deadline = GetTickCount64() + 10000;
      while (!session && GetTickCount64() < session_deadline) {
        for (const auto& candidate : manager.GetSessions()) {
          if (candidate.SourceAppUserModelId() == test_id) { session = candidate; break; }
        }
        MSG message;
        while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessage(&message);
        Sleep(20);
      }
      Check(session != nullptr, "OS media session application ID mismatch");
      auto published = Await(session.TryGetMediaPropertiesAsync());
      Check(published.Title() == L"Native probe title", "OS media client title mismatch");
      const auto artwork_deadline = GetTickCount64() + 10000;
      while (!published.Thumbnail() && GetTickCount64() < artwork_deadline) {
        MSG message;
        while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessage(&message);
        Sleep(50);
        published = Await(session.TryGetMediaPropertiesAsync());
      }
      Check(published.Thumbnail() != nullptr, "OS media client received no artwork reference");
      Check(Await(published.Thumbnail().OpenReadAsync()).Size() > 0, "OS media client artwork is empty");
      Check(Await(session.TryChangeShuffleActiveAsync(false)), "system shuffle request rejected");
      Check(Await(session.TryChangeAutoRepeatModeAsync(MediaPlaybackAutoRepeatMode::Track)), "system repeat request rejected");
      const auto commands_deadline = GetTickCount64() + 10000;
      while (messenger.events.size() < 2 && GetTickCount64() < commands_deadline) {
        MSG message;
        while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessage(&message);
        Sleep(1);
      }
      bool shuffle_requested = false, repeat_requested = false;
      for (const auto& event : messenger.events) {
        const auto command = std::get<std::string>(event.at(EncodableValue("command")));
        shuffle_requested |= command == "shuffleOff";
        repeat_requested |= command == "repeatOne";
      }
      Check(shuffle_requested && repeat_requested, "system mode requests did not reach Dart");
      messenger.events.clear();
      Set(state, "playbackMode", EncodableValue("repeatOne"));
      Set(state, "mediaType", EncodableValue("video"));
      messenger.Call("update", state);
      Check(!smtc.ShuffleEnabled() && smtc.AutoRepeatMode() == MediaPlaybackAutoRepeatMode::Track, "repeat-one state mismatch");
      Check(smtc.DisplayUpdater().Type() == MediaPlaybackType::Video &&
          smtc.DisplayUpdater().VideoProperties().Title() == L"Native probe title", "video metadata mismatch");
      auto video_published = Await(session.TryGetMediaPropertiesAsync());
      const auto video_artwork_deadline = GetTickCount64() + 10000;
      while (!video_published.Thumbnail() && GetTickCount64() < video_artwork_deadline) {
        MSG message;
        while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) DispatchMessage(&message);
        Sleep(50);
        video_published = Await(session.TryGetMediaPropertiesAsync());
      }
      Check(video_published.Thumbnail() && Await(video_published.Thumbnail().OpenReadAsync()).Size() > 0,
          "video session artwork missing");
      Set(state, "playing", EncodableValue(false));
      messenger.Call("update", state);
      Check(smtc.PlaybackStatus() == MediaPlaybackStatus::Paused, "SMTC pause state mismatch");
      // Occupy the exact shortcut through the OS, then verify all-or-nothing registration.
      Check(RegisterHotKey(other, 0x6001, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, VK_LEFT), "test chord already occupied; close conflicting software before retry");
      Set(state, "hotkeysEnabled", EncodableValue(true));
      status = messenger.Call("update", state);
      Check(!Flag(status, "hotkeysRegistered"), "occupied chord was silently accepted");
      Check(!std::get<std::string>(status.at(EncodableValue("error"))).empty(), "registration failure was not reported");
      Check(RegisterHotKey(other, 0x6002, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, VK_SPACE), "partial registration leaked");
      UnregisterHotKey(other, 0x6001); UnregisterHotKey(other, 0x6002);
      Set(state, "hotkeysEnabled", EncodableValue(false)); messenger.Call("update", state);
      Set(state, "hotkeysEnabled", EncodableValue(true)); status = messenger.Call("update", state);
      Check(Flag(status, "hotkeysRegistered"), "real hotkey registration failed");
      ShowWindow(window, SW_MINIMIZE);
      Check(IsIconic(window), "test window did not minimize");
      SendMessage(window, WM_HOTKEY, 0x6170, 0);
      SendMessage(window, WM_HOTKEY, 0x6171, 0);
      SendMessage(window, WM_HOTKEY, 0x6172, 0);
      Check(messenger.events.size() == 3, "minimized command dispatch failed");
      Check(std::get<std::string>(messenger.events[1].at(EncodableValue("command"))) == "previous", "previous maps incorrectly");
      Set(state, "canNext", EncodableValue(false)); messenger.Call("update", state);
      SendMessage(window, WM_HOTKEY, 0x6172, 0);
      Check(messenger.events.size() == 3, "queue boundary was not guarded");
      SendMessage(window, WM_COMMAND, MAKEWPARAM(0x6181, THBN_CLICKED), 0);
      Check(messenger.events.size() == 4, "taskbar command not delivered");
      Check(std::get<std::string>(messenger.events.back().at(EncodableValue("source"))) == "taskbar", "taskbar source mismatch");
      for (int i = 3; i <= 5; ++i) SendMessage(window, WM_COMMAND, MAKEWPARAM(0x6180 + i, THBN_CLICKED), 0);
      Check(messenger.events.size() == 7, "extended toolbar commands missing");
      Check(std::get<std::string>(messenger.events[4].at(EncodableValue("command"))) == "rewind", "rewind mapping incorrect");
      Check(std::get<std::string>(messenger.events[5].at(EncodableValue("command"))) == "fastForward", "forward mapping incorrect");
      Check(std::get<std::string>(messenger.events[6].at(EncodableValue("command"))) == "cyclePlaybackMode", "mode mapping incorrect");
      Set(state, "canSeek", EncodableValue(false)); messenger.Call("update", state);
      SendMessage(window, WM_COMMAND, MAKEWPARAM(0x6183, THBN_CLICKED), 0);
      Check(messenger.events.size() == 7, "unseekable media accepted seek");
      messenger.Call("dispose");
      Check(!smtc.IsEnabled(), "session survived disposal");
      Check(RegisterHotKey(other, 0x6001, MOD_CONTROL | MOD_ALT | MOD_SHIFT | MOD_NOREPEAT, VK_SPACE), "hotkey survived disposal");
      UnregisterHotKey(other, 0x6001);
      SendMessage(window, WM_HOTKEY, 0x6170, 0);
      Check(messenger.events.size() == 7, "inactive session still accepted commands");
      control = nullptr;
    }
    DestroyWindow(window); DestroyWindow(other);
    cleanup_identity();
    CoUninitialize();
    std::cout << "PASS: Windows app identity/name/icon/shortcut, SMTC artwork stream and queue modes, hotkey conflict/release, minimized commands and seek guards\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << "\n";
  } catch (const winrt::hresult_error& error) {
    std::cerr << "FAIL: " << winrt::to_string(error.message()) << "\n";
  }
  control = nullptr;
  if (window) DestroyWindow(window);
  if (other) DestroyWindow(other);
  cleanup_identity();
  CoUninitialize();
  return 1;
}
