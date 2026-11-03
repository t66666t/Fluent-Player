#include "ime_shortcut_gate.h"

#include <imm.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <unordered_map>
#include <variant>

namespace {

constexpr char kChannelName[] = "com.example.video_player_app/ime_gate";

struct WindowImeState {
  WNDPROC previous = nullptr;
  HIMC saved_context = nullptr;
  bool detached = false;
};

std::unordered_map<HWND, WindowImeState> g_states;
HWND g_top_level = nullptr;
HWND g_flutter_view = nullptr;
bool g_text_input_active = false;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

bool IsOurWindow(HWND hwnd) {
  if (hwnd == nullptr) {
    return false;
  }
  if (hwnd == g_top_level || hwnd == g_flutter_view) {
    return true;
  }
  return g_top_level != nullptr && ::IsChild(g_top_level, hwnd) != FALSE;
}

void CancelComposition(HWND hwnd) {
  const HIMC context = ::ImmGetContext(hwnd);
  if (context == nullptr) {
    return;
  }
  ::ImmNotifyIME(context, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
  ::ImmNotifyIME(context, NI_CLOSECANDIDATE, 0, 0);
  ::ImmReleaseContext(hwnd, context);
}

void DetachWindow(HWND hwnd) {
  if (!IsOurWindow(hwnd)) {
    return;
  }
  WindowImeState& state = g_states[hwnd];
  if (state.detached) {
    return;
  }
  CancelComposition(hwnd);
  state.saved_context = ::ImmAssociateContext(hwnd, nullptr);
  state.detached = true;
}

void AttachWindow(HWND hwnd) {
  if (!IsOurWindow(hwnd)) {
    return;
  }
  const auto it = g_states.find(hwnd);
  if (it == g_states.end() || !it->second.detached) {
    return;
  }
  if (it->second.saved_context != nullptr) {
    ::ImmAssociateContext(hwnd, it->second.saved_context);
  } else {
    ::ImmAssociateContextEx(hwnd, nullptr, IACE_DEFAULT);
  }
  it->second.saved_context = nullptr;
  it->second.detached = false;
}

void ApplyTo(HWND hwnd) {
  if (hwnd == nullptr) {
    return;
  }
  if (g_text_input_active) {
    AttachWindow(hwnd);
  } else {
    DetachWindow(hwnd);
  }
}

void ApplyAll() {
  ApplyTo(g_flutter_view);
  ApplyTo(g_top_level);
  const HWND focused = ::GetFocus();
  if (focused != g_flutter_view && focused != g_top_level) {
    ApplyTo(focused);
  }
}

bool IsImeMessage(UINT message) {
  switch (message) {
    case WM_IME_SETCONTEXT:
    case WM_IME_STARTCOMPOSITION:
    case WM_IME_COMPOSITION:
    case WM_IME_ENDCOMPOSITION:
    case WM_IME_NOTIFY:
    case WM_IME_CHAR:
    case WM_IME_REQUEST:
    case WM_IME_SELECT:
    case WM_IME_KEYDOWN:
    case WM_IME_KEYUP:
      return true;
    default:
      return false;
  }
}

LRESULT CALLBACK FlutterViewImeProc(HWND hwnd,
                                   UINT message,
                                   WPARAM wparam,
                                   LPARAM lparam) {
  const auto it = g_states.find(hwnd);
  const WNDPROC previous =
      it == g_states.end() ? nullptr : it->second.previous;
  if (!g_text_input_active) {
    if (message == WM_SETFOCUS || message == WM_INPUTLANGCHANGE ||
        message == WM_KEYDOWN || message == WM_SYSKEYDOWN ||
        IsImeMessage(message)) {
      DetachWindow(hwnd);
    }
    if (IsImeMessage(message)) {
      return 0;
    }
  }
  if (previous != nullptr) {
    return ::CallWindowProc(previous, hwnd, message, wparam, lparam);
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

void SubclassFlutterView(HWND hwnd) {
  if (hwnd == nullptr) {
    return;
  }
  WindowImeState& state = g_states[hwnd];
  if (state.previous != nullptr) {
    return;
  }
  state.previous = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
      hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(FlutterViewImeProc)));
}

void Unsubclass(HWND hwnd) {
  const auto it = g_states.find(hwnd);
  if (it == g_states.end() || it->second.previous == nullptr) {
    return;
  }
  ::SetWindowLongPtr(hwnd, GWLP_WNDPROC,
                     reinterpret_cast<LONG_PTR>(it->second.previous));
  it->second.previous = nullptr;
}

}  // namespace

void ImeShortcutGate::Install(HWND top_level,
                              HWND flutter_view,
                              flutter::BinaryMessenger* messenger) {
  g_top_level = top_level;
  g_flutter_view = flutter_view;
  g_text_input_active = false;
  SubclassFlutterView(flutter_view);
  ApplyAll();

  if (messenger == nullptr) {
    return;
  }
  g_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "setTextInputActive") {
          result->NotImplemented();
          return;
        }
        const flutter::EncodableValue* args = call.arguments();
        const bool* active =
            args == nullptr ? nullptr : std::get_if<bool>(args);
        g_text_input_active = active != nullptr && *active;
        ApplyAll();
        result->Success();
      });
}

void ImeShortcutGate::BeforeTranslateMessage(const MSG* message) {
  if (g_text_input_active || message == nullptr) {
    return;
  }
  if (message->message != WM_KEYDOWN && message->message != WM_SYSKEYDOWN) {
    return;
  }
  if (!IsOurWindow(message->hwnd)) {
    return;
  }
  DetachWindow(message->hwnd);
  DetachWindow(g_flutter_view);
}

void ImeShortcutGate::Uninstall() {
  g_channel.reset();
  g_text_input_active = true;
  ApplyAll();
  Unsubclass(g_flutter_view);
  g_states.clear();
  g_top_level = nullptr;
  g_flutter_view = nullptr;
  g_text_input_active = false;
}

std::optional<LRESULT> ImeShortcutGate::HandleTopLevelMessage(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam) {
  if (g_text_input_active || !IsOurWindow(hwnd)) {
    return std::nullopt;
  }
  if (message == WM_ACTIVATE || message == WM_SETFOCUS ||
      message == WM_INPUTLANGCHANGE) {
    ApplyAll();
    return std::nullopt;
  }
  if (IsImeMessage(message)) {
    return 0;
  }
  return std::nullopt;
}
