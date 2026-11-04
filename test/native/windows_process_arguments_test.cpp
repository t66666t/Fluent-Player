#include <windows.h>
#include <shellapi.h>

#include <iostream>
#include <string>
#include <vector>

#include "windows/runner/windows_process_arguments.h"

namespace {
const std::vector<std::wstring> kArguments = {
    L"", L"D:\\", L"C:\\a folder\\", L"中文路径\\视频\\",
    L"a\"b", L"a\\\"b", L"a\\\\\"b", L"end\\\\\\",
    L"\\\\server\\共享目录\\", L"--paths", L"https://example.test/video?q=a&b=c"};

std::wstring Quote(const std::wstring& argument) {
#ifdef VERIFY_LEGACY_QUOTING
  std::wstring result = L"\"";
  for (wchar_t value : argument) {
    if (value == L'"') result += L'\\';
    result += value;
  }
  return result + L'"';
#else
  return QuoteWindowsProcessArgument(argument);
#endif
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc > 1 && std::wstring(argv[1]) == L"--child") {
    if (argc != static_cast<int>(kArguments.size()) + 2) return 20;
    for (size_t index = 0; index < kArguments.size(); ++index) {
      if (argv[index + 2] != kArguments[index]) return 21;
    }
    return 0;
  }
  int failures = 0;
  for (const auto& argument : kArguments) {
    const auto command = L"test.exe " + Quote(argument) + L" after";
    int parsed_count = 0;
    auto parsed = CommandLineToArgvW(command.c_str(), &parsed_count);
    if (parsed == nullptr || parsed_count != 3 || parsed[1] != argument ||
        std::wstring(parsed[2]) != L"after") {
      ++failures;
    }
    if (parsed) LocalFree(parsed);
  }
  wchar_t executable[32768]{};
  GetModuleFileNameW(nullptr, executable, ARRAYSIZE(executable));
  std::wstring command = Quote(executable) + L" --child";
  for (const auto& argument : kArguments) command += L" " + Quote(argument);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    return 22;
  }
  const auto wait = WaitForSingleObject(process.hProcess, 10000);
  DWORD exit_code = 0;
  GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  if (wait != WAIT_OBJECT_0 || exit_code != 0) ++failures;
  std::cout << "Windows argv round trip: " << failures << " failures; "
            << kArguments.size() << " cases, Shell32 and actual CRT child\n";
  return failures == 0 ? 0 : 1;
}
