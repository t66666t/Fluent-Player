#ifndef RUNNER_DESKTOP_MEDIA_CONTROLS_H_
#define RUNNER_DESKTOP_MEDIA_CONTROLS_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <functional>
#include <memory>
#include <optional>

// Owns SMTC, thumbnail toolbar and optional RegisterHotKey registrations.
// Every native event is marshalled to the window thread before calling Dart.
class DesktopMediaControls {
 public:
  DesktopMediaControls(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopMediaControls();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif
