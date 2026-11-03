#include "desktop_media_controls.h"
#include "desktop_media_toolbar_cache.h"

#include <shobjidl.h>
#include <shcore.h>
#include <roapi.h>
#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <array>
#include <cstring>
#include <algorithm>
#include <string>
#include <vector>

using namespace winrt::Windows::Media;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {
constexpr UINT kCommandMessage = WM_APP + 182;
constexpr int kFirstHotkey = 0x6170;
constexpr UINT kFirstButton = 0x6180;
enum Command { kToggle, kPrevious, kNext, kPlay, kPause, kStop,
               kRewind, kFastForward, kCycleMode, kShuffleOn, kShuffleOff,
               kRepeatOne, kRepeatList, kRepeatOff };
const char* CommandName(int command) {
  switch (command) {
    case kPrevious: return "previous";
    case kNext: return "next";
    case kPlay: return "play";
    case kPause: return "pause";
    case kStop: return "stop";
    case kRewind: return "rewind";
    case kFastForward: return "fastForward";
    case kCycleMode: return "cyclePlaybackMode";
    case kShuffleOn: return "shuffleOn";
    case kShuffleOff: return "shuffleOff";
    case kRepeatOne: return "repeatOne";
    case kRepeatList: return "repeatList";
    case kRepeatOff: return "repeatOff";
    default: return "playPause";
  }
}
template <typename T>
T Read(const EncodableMap& map, const char* key, T fallback = T{}) {
  const auto found = map.find(EncodableValue(key));
  if (found == map.end()) return fallback;
  const auto* value = std::get_if<T>(&found->second);
  return value ? *value : fallback;
}
int64_t Number(const EncodableMap& map, const char* key) {
  const auto found = map.find(EncodableValue(key));
  if (found == map.end()) return 0;
  if (const auto* value = std::get_if<int64_t>(&found->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&found->second)) return *value;
  return 0;
}
HICON RasterIcon(const std::vector<uint8_t>& bytes) {
  if (bytes.size() != 32 * 32 * 4) return nullptr;
  BITMAPV5HEADER header{};
  header.bV5Size = sizeof(header);
  header.bV5Width = 32;
  header.bV5Height = -32;
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00ff0000;
  header.bV5GreenMask = 0x0000ff00;
  header.bV5BlueMask = 0x000000ff;
  header.bV5AlphaMask = 0xff000000;
  void* pixels = nullptr;
  HDC dc = GetDC(nullptr);
  HBITMAP bitmap = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&header), DIB_RGB_COLORS, &pixels, nullptr, 0);
  ReleaseDC(nullptr, dc);
  if (!bitmap || !pixels) return nullptr;
  std::memcpy(pixels, bytes.data(), bytes.size());
  HBITMAP mask = CreateBitmap(32, 32, 1, 1, nullptr);
  ICONINFO info{};
  info.fIcon = TRUE;
  info.hbmMask = mask;
  info.hbmColor = bitmap;
  HICON icon = CreateIconIndirect(&info);
  DeleteObject(bitmap);
  DeleteObject(mask);
  return icon;
}

// Transport glyphs are native; playback modes arrive from the shared Flutter painter.
HICON TransportIcon(int command, bool playing) {
  std::vector<uint8_t> bytes(32 * 32 * 4);
  auto* rgba = reinterpret_cast<DWORD*>(bytes.data());
  for (int y = 0; y < 32; ++y) {
    for (int x = 0; x < 32; ++x) {
      bool fill = false;
      if (command == kToggle && playing) {
        fill = y >= 7 && y <= 25 && ((x >= 9 && x <= 13) || (x >= 19 && x <= 23));
      } else if (command == kToggle) {
        fill = x >= 10 && x <= 24 && abs(y - 16) <= (24 - x) * 3 / 4;
      } else if (command == kRewind || command == kFastForward) {
        const int tx = command == kRewind ? 31 - x : x;
        fill = (tx >= 4 && tx <= 15 && abs(y - 16) <= (15 - tx) * 3 / 4) ||
               (tx >= 16 && tx <= 27 && abs(y - 16) <= (27 - tx) * 3 / 4);
      } else {
        const int tx = command == kPrevious ? 31 - x : x;
        fill = (tx >= 23 && tx <= 26 && y >= 7 && y <= 25) ||
               (tx >= 7 && tx <= 22 && abs(y - 16) <= (22 - tx) * 3 / 4);
      }
      rgba[y * 32 + x] = fill ? 0xffe6e6e6 : 0;
    }
  }
  return RasterIcon(bytes);
}

// Snapshot bytes into a stream: the shell must not depend on Flutter's cache
// file remaining present, URI access rules or its support for WebP/AVIF.
winrt::Windows::Storage::Streams::RandomAccessStreamReference ArtworkStream(const std::string& path) {
  using namespace winrt::Windows::Storage::Streams;
  const auto wide = winrt::to_hstring(path);
  const HANDLE file = CreateFileW(wide.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
                                nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return nullptr;
  LARGE_INTEGER size{};
  const bool valid = GetFileSizeEx(file, &size) && size.QuadPart > 0 && size.QuadPart <= 4 * 1024 * 1024;
  std::vector<uint8_t> bytes(valid ? static_cast<size_t>(size.QuadPart) : 0);
  DWORD count = 0;
  const bool read = valid && ReadFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr);
  CloseHandle(file);
  if (!read || count != bytes.size()) return nullptr;
  winrt::com_ptr<IStream> stream;
  winrt::check_hresult(CreateStreamOnHGlobal(nullptr, TRUE, stream.put()));
  winrt::check_hresult(stream->Write(bytes.data(), count, nullptr));
  LARGE_INTEGER start{};
  winrt::check_hresult(stream->Seek(start, STREAM_SEEK_SET, nullptr));
  IRandomAccessStream random{nullptr};
  winrt::check_hresult(CreateRandomAccessStreamOverStream(stream.get(), BSOS_DEFAULT,
      winrt::guid_of<IRandomAccessStream>(), winrt::put_abi(random)));
  return RandomAccessStreamReference::CreateFromStream(random);
}
}  // namespace

struct DesktopMediaControls::Impl {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_token{};
  winrt::event_token shuffle_token{}, repeat_token{};
  winrt::com_ptr<ITaskbarList3> taskbar;
  std::array<HICON, 9> icons{};
  EncodableMap state;
  std::string metadata_identity, hotkey_identity, error, system_error;
  ToolbarUpdateCache toolbar_cache;
  bool runtime_initialized = false, hotkeys_registered = false;
  UINT taskbar_created = RegisterWindowMessageW(L"TaskbarButtonCreated");

  Impl(HWND hwnd, flutter::BinaryMessenger* messenger) : window(hwnd) {
    icons = {TransportIcon(kPrevious, false), TransportIcon(kToggle, false),
             TransportIcon(kToggle, true), TransportIcon(kNext, false),
             TransportIcon(kRewind, false), TransportIcon(kFastForward, false),
             nullptr, nullptr, nullptr};
    channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "com.example.video_player_app/desktop_media", &flutter::StandardMethodCodec::GetInstance());
    channel->SetMethodCallHandler([this](const auto& call, auto result) {
      try {
        if (call.method_name() == "initialize") {
          if (call.arguments() && std::holds_alternative<EncodableMap>(*call.arguments())) {
            const auto modes = Read<EncodableMap>(std::get<EncodableMap>(*call.arguments()), "modeIcons");
            const char* names[] = {"sequential", "shuffle", "repeatOne"};
            for (size_t i = 0; i < 3; ++i) {
              const auto icon = RasterIcon(Read<std::vector<uint8_t>>(modes, names[i]));
              if (icon) {
                if (icons[6 + i]) DestroyIcon(icons[6 + i]);
                icons[6 + i] = icon;
              }
            }
          }
          Initialize();
          result->Success(EncodableValue(Status()));
        } else if (call.method_name() == "update") {
          if (call.arguments() && std::holds_alternative<EncodableMap>(*call.arguments())) {
            state = std::get<EncodableMap>(*call.arguments());
            Apply();
          }
          result->Success(EncodableValue(Status()));
        } else if (call.method_name() == "dispose") {
          Clear();
          result->Success();
        } else { result->NotImplemented(); }
      } catch (const winrt::hresult_error& failure) {
        error = winrt::to_string(failure.message());
        result->Success(EncodableValue(Status()));
      }
    });
  }

  ~Impl() {
    channel->SetMethodCallHandler(nullptr);
    try { Clear(); } catch (const winrt::hresult_error&) {}
    try { if (controls) controls.ButtonPressed(button_token); } catch (const winrt::hresult_error&) {}
    try { if (controls) controls.ShuffleEnabledChangeRequested(shuffle_token); } catch (const winrt::hresult_error&) {}
    try { if (controls) controls.AutoRepeatModeChangeRequested(repeat_token); } catch (const winrt::hresult_error&) {}
    controls = nullptr;
    taskbar = nullptr;
    for (const auto icon : icons) if (icon) DestroyIcon(icon);
    if (runtime_initialized) RoUninitialize();
  }

  void Initialize() {
    if (!controls) {
      try {
      if (!runtime_initialized) {
        const HRESULT initialized = RoInitialize(RO_INIT_SINGLETHREADED);
        runtime_initialized = SUCCEEDED(initialized);
      }
      const auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
      winrt::check_hresult(interop->GetForWindow(window, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(controls)));
      // This is an external playback engine; do not create a Windows MediaPlayer.
      controls.IsEnabled(false);
      button_token = controls.ButtonPressed([hwnd = window](const auto&, const SystemMediaTransportControlsButtonPressedEventArgs& args) {
        int command = -1;
        switch (args.Button()) {
          case SystemMediaTransportControlsButton::Play: command = kPlay; break;
          case SystemMediaTransportControlsButton::Pause: command = kPause; break;
          case SystemMediaTransportControlsButton::Next: command = kNext; break;
          case SystemMediaTransportControlsButton::Previous: command = kPrevious; break;
          case SystemMediaTransportControlsButton::Stop: command = kStop; break;
          case SystemMediaTransportControlsButton::Rewind: command = kRewind; break;
          case SystemMediaTransportControlsButton::FastForward: command = kFastForward; break;
          default: break;
        }
        if (command >= 0) PostMessageW(hwnd, kCommandMessage, static_cast<WPARAM>(command), 0);
      });
      shuffle_token = controls.ShuffleEnabledChangeRequested([hwnd = window](const auto&, const auto& args) {
        PostMessageW(hwnd, kCommandMessage, args.RequestedShuffleEnabled() ? kShuffleOn : kShuffleOff, 0);
      });
      repeat_token = controls.AutoRepeatModeChangeRequested([hwnd = window](const auto&, const auto& args) {
        const auto mode = args.RequestedAutoRepeatMode();
        const int command = mode == MediaPlaybackAutoRepeatMode::Track ? kRepeatOne :
            mode == MediaPlaybackAutoRepeatMode::List ? kRepeatList : kRepeatOff;
        PostMessageW(hwnd, kCommandMessage, command, 0);
      });
      system_error.clear();
      } catch (const winrt::hresult_error& failure) {
        system_error = winrt::to_string(failure.message());
      }
    }
    if (!taskbar) {
      const HRESULT hr = CoCreateInstance(CLSID_TaskbarList, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(taskbar.put()));
      if (SUCCEEDED(hr)) taskbar->HrInit();
    }
  }

  EncodableMap Status() const {
    return {{EncodableValue("systemMedia"), EncodableValue(controls != nullptr)},
            {EncodableValue("taskbar"), EncodableValue(static_cast<bool>(taskbar))},
            {EncodableValue("globalHotkeys"), EncodableValue(true)},
            {EncodableValue("hotkeysRegistered"), EncodableValue(hotkeys_registered)},
            {EncodableValue("error"), EncodableValue(system_error.empty() ? error : system_error + " " + error)}};
  }

  void ReleaseHotkeys() {
    for (int i = 0; i < 3; ++i) UnregisterHotKey(window, kFirstHotkey + i);
    hotkeys_registered = false;
  }

  void ConfigureHotkeys() {
    const bool enabled = Read<bool>(state, "active") && Read<bool>(state, "canPlay") && Read<bool>(state, "hotkeysEnabled");
    const auto modifiers = Read<std::string>(state, "hotkeyModifiers");
    const auto identity = std::to_string(enabled) + modifiers;
    if (hotkey_identity == identity) return;
    hotkey_identity = identity;
    ReleaseHotkeys();
    error.clear();
    if (!enabled) return;
    const UINT mods = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT |
        (modifiers == "ctrl+alt+shift" ? MOD_SHIFT : 0);
    const UINT keys[] = {VK_SPACE, VK_LEFT, VK_RIGHT};
    for (int i = 0; i < 3; ++i) {
      if (!RegisterHotKey(window, kFirstHotkey + i, mods, keys[i])) {
        const auto code = GetLastError();
        ReleaseHotkeys();
        error = "Global shortcut registration failed (" + std::to_string(code) + "). Choose another modifier set.";
        return;
      }
    }
    hotkeys_registered = true;
  }

  void UpdateToolbar() {
    if (!taskbar) return;
    const bool visible = Read<bool>(state, "active") && Read<bool>(state, "taskbarEnabled");
    const bool playing = Read<bool>(state, "playing");
    const auto mode = Read<std::string>(state, "playbackMode");
    const bool can_play = Read<bool>(state, "canPlay"), can_seek = Read<bool>(state, "canSeek");
    const bool enabled[] = {Read<bool>(state, "canPrevious"), can_seek, can_play, can_seek, Read<bool>(state, "canNext"), can_play};
    const auto distance = Read<bool>(state, "subtitleSeek") ? std::wstring(L"\u4e00\u6761\u5b57\u5e55") :
        std::to_wstring(Number(state, "seekSeconds")) + L" \u79d2";
    const std::wstring labels[] = {L"\u4e0a\u4e00\u9879", L"\u540e\u9000 " + distance,
        playing ? L"\u6682\u505c" : L"\u64ad\u653e", L"\u524d\u8fdb " + distance, L"\u4e0b\u4e00\u9879",
        mode == "shuffle" ? L"\u968f\u673a\u64ad\u653e\uff1b\u70b9\u51fb\u5207\u6362\u5355\u96c6\u5faa\u73af" : mode == "repeatOne" ?
            L"\u5355\u96c6\u5faa\u73af\uff1b\u70b9\u51fb\u5207\u6362\u987a\u5e8f\u64ad\u653e" : L"\u987a\u5e8f\u64ad\u653e\uff1b\u70b9\u51fb\u5207\u6362\u968f\u673a\u64ad\u653e"};
    const HICON images[] = {icons[0], icons[4], icons[playing ? 2 : 1], icons[5], icons[3], icons[mode == "shuffle" ? 7 : mode == "repeatOne" ? 8 : 6]};
    const UINT ids[] = {0, 3, 1, 4, 2, 5};
    ToolbarUpdateCache::Buttons buttons{};
    for (UINT i = 0; i < 6; ++i) {
      auto& b = buttons[i];
      b.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
      b.iId = kFirstButton + ids[i];
      b.hIcon = images[i];
      wcscpy_s(b.szTip, labels[i].c_str());
      b.dwFlags = !visible ? THBF_HIDDEN : enabled[i] ? THBF_ENABLED : THBF_DISABLED;
    }
    toolbar_cache.Publish(buttons, [&](bool added) {
      return added ? taskbar->ThumbBarUpdateButtons(window, 6, buttons.data()) :
          taskbar->ThumbBarAddButtons(window, 6, buttons.data());
    });
  }

  void Apply() {
    ConfigureHotkeys();
    UpdateToolbar();
    if (!controls) return;
    const bool enabled = Read<bool>(state, "active") && Read<bool>(state, "systemEnabled");
    controls.IsEnabled(enabled);
    controls.IsPlayEnabled(enabled && Read<bool>(state, "canPlay"));
    controls.IsPauseEnabled(enabled && Read<bool>(state, "canPlay"));
    controls.IsPreviousEnabled(enabled && Read<bool>(state, "canPrevious"));
    controls.IsNextEnabled(enabled && Read<bool>(state, "canNext"));
    controls.IsStopEnabled(enabled && Read<bool>(state, "canPlay"));
    controls.IsRewindEnabled(enabled && Read<bool>(state, "canSeek"));
    controls.IsFastForwardEnabled(enabled && Read<bool>(state, "canSeek"));
    const auto mode = Read<std::string>(state, "playbackMode");
    controls.ShuffleEnabled(mode == "shuffle");
    controls.AutoRepeatMode(mode == "repeatOne" ? MediaPlaybackAutoRepeatMode::Track :
        Read<bool>(state, "playlistWrap") ? MediaPlaybackAutoRepeatMode::List : MediaPlaybackAutoRepeatMode::None);
    controls.PlaybackStatus(!enabled ? MediaPlaybackStatus::Closed : Read<bool>(state, "playing") ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused);
    if (!enabled) { controls.DisplayUpdater().ClearAll(); metadata_identity.clear(); return; }
    const auto title = Read<std::string>(state, "title");
    const auto subtitle = Read<std::string>(state, "subtitle");
    const auto artwork = Read<std::string>(state, "artworkPath");
    const auto media_type = Read<std::string>(state, "mediaType");
    const auto identity = Read<std::string>(state, "itemId") + title + subtitle + artwork + media_type;
    if (metadata_identity != identity) {
      auto updater = controls.DisplayUpdater();
      updater.ClearAll();
      if (media_type == "video") {
        updater.Type(MediaPlaybackType::Video);
        updater.VideoProperties().Title(winrt::to_hstring(title));
        updater.VideoProperties().Subtitle(winrt::to_hstring(subtitle));
      } else {
        updater.Type(MediaPlaybackType::Music);
        updater.MusicProperties().Title(winrt::to_hstring(title));
        updater.MusicProperties().Artist(winrt::to_hstring(subtitle));
      }
      if (!artwork.empty()) {
        // An inaccessible cover must never suppress the title or media controls.
        try { updater.Thumbnail(ArtworkStream(artwork)); } catch (const winrt::hresult_error&) {}
      }
      updater.Update();
      metadata_identity = identity;
    }
    SystemMediaTransportControlsTimelineProperties timeline;
    const auto end = std::max<int64_t>(0, Number(state, "durationMs"));
    const auto position = std::clamp<int64_t>(Number(state, "positionMs"), 0, end);
    timeline.StartTime(winrt::Windows::Foundation::TimeSpan{0});
    timeline.EndTime(winrt::Windows::Foundation::TimeSpan{end * 10000});
    timeline.Position(winrt::Windows::Foundation::TimeSpan{position * 10000});
    // Publish a read-only timeline. Do not advertise a seek range until the
    // engine's seek transaction is explicitly wired to the system controls.
    controls.UpdateTimelineProperties(timeline);
  }

  void Clear() {
    state.clear();
    hotkey_identity.clear();
    ReleaseHotkeys();
    if (controls) {
      controls.IsEnabled(false);
      controls.PlaybackStatus(MediaPlaybackStatus::Closed);
      controls.DisplayUpdater().ClearAll();
    }
    metadata_identity.clear();
    UpdateToolbar();
  }

  void Emit(int command, const char* source) {
    if (std::string(source) == "hotkey" && !hotkeys_registered) return;
    if (!Read<bool>(state, "active")) return;
    const bool enabled = std::string(source) == "hotkey" ? Read<bool>(state, "hotkeysEnabled") :
        std::string(source) == "taskbar" ? Read<bool>(state, "taskbarEnabled") : Read<bool>(state, "systemEnabled");
    if (!enabled || !Read<bool>(state, "canPlay")) return;
    if (command == kNext && !Read<bool>(state, "canNext")) return;
    if (command == kPrevious && !Read<bool>(state, "canPrevious")) return;
    if ((command == kRewind || command == kFastForward) && !Read<bool>(state, "canSeek")) return;
    channel->InvokeMethod("command", std::make_unique<EncodableValue>(EncodableMap{
      {EncodableValue("command"), EncodableValue(CommandName(command))},
      {EncodableValue("source"), EncodableValue(source)}}));
  }
};

DesktopMediaControls::DesktopMediaControls(HWND window, flutter::BinaryMessenger* messenger)
    : impl_(std::make_unique<Impl>(window, messenger)) {}
DesktopMediaControls::~DesktopMediaControls() = default;

std::optional<LRESULT> DesktopMediaControls::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  (void)lparam;
  if (message == impl_->taskbar_created) {
    impl_->toolbar_cache.Invalidate();
    impl_->UpdateToolbar();
  } else if (message == WM_HOTKEY && wparam >= kFirstHotkey && wparam < kFirstHotkey + 3) {
    impl_->Emit(static_cast<int>(wparam) - kFirstHotkey, "hotkey");
    return 0;
  } else if (message == kCommandMessage) {
    impl_->Emit(static_cast<int>(wparam), "system");
    return 0;
  } else if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED &&
             LOWORD(wparam) >= kFirstButton && LOWORD(wparam) < kFirstButton + 6) {
    const int index = LOWORD(wparam) - kFirstButton;
    const int commands[] = {kPrevious, kToggle, kNext, kRewind, kFastForward, kCycleMode};
    impl_->Emit(commands[index], "taskbar");
    return 0;
  }
  return std::nullopt;
}
