#ifndef RUNNER_IME_SHORTCUT_GATE_H_
#define RUNNER_IME_SHORTCUT_GATE_H_

#include <windows.h>

#include <optional>

namespace flutter {
class BinaryMessenger;
}

// Detaches the Win32 IME from this window until a text field is focused, so
// Chinese and English modes both deliver raw shortcut keys.
class ImeShortcutGate {
 public:
  static void Install(HWND top_level,
                      HWND flutter_view,
                      flutter::BinaryMessenger* messenger);
  static void Uninstall();
  // Runs before TranslateMessage so a Chinese IME cannot turn the key into
  // composition. Already-detached windows return immediately.
  static void BeforeTranslateMessage(const MSG* message);
  static std::optional<LRESULT> HandleTopLevelMessage(HWND hwnd,
                                                      UINT message,
                                                      WPARAM wparam,
                                                      LPARAM lparam);
};

#endif  // RUNNER_IME_SHORTCUT_GATE_H_
