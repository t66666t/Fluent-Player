#ifndef RUNNER_WINDOWS_PROCESS_ARGUMENTS_H_
#define RUNNER_WINDOWS_PROCESS_ARGUMENTS_H_

#include <string>

// CreateProcessW takes a command line, not an argv array. Backslashes before
// a quote (including the final quote) must follow the Windows CRT rules.
inline std::wstring QuoteWindowsProcessArgument(const std::wstring& argument) {
  std::wstring quoted(1, L'"');
  size_t backslashes = 0;
  for (const wchar_t character : argument) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'"') {
      quoted.append(backslashes * 2 + 1, L'\\');
    } else {
      quoted.append(backslashes, L'\\');
    }
    backslashes = 0;
    quoted += character;
  }
  quoted.append(backslashes * 2, L'\\');
  quoted += L'"';
  return quoted;
}

#endif  // RUNNER_WINDOWS_PROCESS_ARGUMENTS_H_
