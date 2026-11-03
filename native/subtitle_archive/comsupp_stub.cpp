#include <windows.h>
#include <oleauto.h>

// UnRAR references the power API from unused UI code. Defining it locally
// keeps powrprof.dll out of the import table.
extern "C" int __stdcall SetSuspendState(int, int, int) { return 0; }

namespace _com_util {
BSTR ConvertStringToBSTR(const char* text) {
  if (text == nullptr) return nullptr;
  const int chars = MultiByteToWideChar(CP_ACP, 0, text, -1, nullptr, 0);
  if (chars <= 0) return nullptr;
  BSTR value = SysAllocStringLen(nullptr, static_cast<UINT>(chars - 1));
  if (value == nullptr) return nullptr;
  MultiByteToWideChar(CP_ACP, 0, text, -1, value, chars);
  return value;
}
}  // namespace _com_util
