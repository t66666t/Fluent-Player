#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "ime_shortcut_gate.h"
#include "utils.h"
#include "desktop_app_identity.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  // The apartment must outlive the window, Flutter engine and all plugins,
  // including early returns when native window creation fails.
  struct ScopedComApartment {
    HRESULT result = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ~ScopedComApartment() {
      if (SUCCEEDED(result)) ::CoUninitialize();
    }
  } com_apartment;
  InitializeDesktopAppIdentity();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  
  // Get screen dimensions
  int screen_width = GetSystemMetrics(SM_CXSCREEN);
  int screen_height = GetSystemMetrics(SM_CYSCREEN);
  
  // Calculate window size as 80% of screen size
  int window_width = static_cast<int>(screen_width * 0.8);
  int window_height = static_cast<int>(screen_height * 0.8);
  
  // Calculate center position
  int window_x = (screen_width - window_width) / 2;
  int window_y = (screen_height - window_height) / 2;
  
  // Create window with calculated size and position
  Win32Window::Point origin(window_x, window_y);
  Win32Window::Size size(window_width, window_height);
  if (!window.Create(L"Fluent Player", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ImeShortcutGate::BeforeTranslateMessage(&msg);
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  return EXIT_SUCCESS;
}
