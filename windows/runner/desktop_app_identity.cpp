#include "desktop_app_identity.h"

#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <propkey.h>
#include <winrt/base.h>
#include <string>

namespace {
HRESULT SetAppId(IPropertyStore* properties, const std::wstring& app_id) {
  PROPVARIANT value{};
  value.vt = VT_LPWSTR;
  value.pwszVal = const_cast<wchar_t*>(app_id.c_str());
  const HRESULT result = properties->SetValue(PKEY_AppUserModel_ID, value);
  return SUCCEEDED(result) ? properties->Commit() : result;
}
void RegisterShortcut(const std::wstring& app_id, const std::wstring& display_name,
                     const std::wstring& executable) {
  PWSTR programs = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs))) return;
  const std::wstring directory = std::wstring(programs) + L"\\" + display_name;
  CoTaskMemFree(programs);
  if (!CreateDirectoryW(directory.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) return;
  const std::wstring path = directory + L"\\" + display_name + L".lnk";
  winrt::com_ptr<IShellLinkW> link;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(link.put())))) return;
  auto persist = link.as<IPersistFile>();
  const bool exists = GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
  if (exists) {
    if (FAILED(persist->Load(path.c_str(), STGM_READWRITE))) return;
    // Preserve the existing installation's target, arguments and custom icon.
    // Never redirect an installed shortcut to a development/portable checkout.
    wchar_t target[32768]{};
    if (FAILED(link->GetPath(target, ARRAYSIZE(target), nullptr, SLGP_RAWPATH))) return;
    const std::wstring target_path(target);
    const auto name = target_path.substr(target_path.find_last_of(L"\\/") + 1);
    const auto current_name = executable.substr(executable.find_last_of(L"\\/") + 1);
    if (_wcsicmp(name.c_str(), current_name.c_str()) != 0) return;
  } else {
    link->SetPath(executable.c_str());
    const auto parent = executable.substr(0, executable.find_last_of(L"\\/"));
    link->SetWorkingDirectory(parent.c_str());
    link->SetDescription(display_name.c_str());
    link->SetIconLocation(executable.c_str(), 0);
  }
  if (FAILED(SetAppId(link.as<IPropertyStore>().get(), app_id))) return;
  if (SUCCEEDED(persist->Save(path.c_str(), TRUE))) {
    SHChangeNotify(exists ? SHCNE_UPDATEITEM : SHCNE_CREATE, SHCNF_PATHW, path.c_str(), nullptr);
  }
}
}  // namespace

void InitializeDesktopAppIdentity() {
  // This must run before creating any HWND or SMTC object. Register per user,
  // including portable builds, so Explorer can resolve the name and app icon.
  wchar_t executable[32768]{};
  const DWORD length = GetModuleFileNameW(nullptr, executable, ARRAYSIZE(executable));
  if (length == 0 || length >= ARRAYSIZE(executable)) return;
  const std::wstring path(executable);
  const auto icon = path.substr(0, path.find_last_of(L"\\/")) +
      L"\\data\\flutter_assets\\android\\app\\src\\main\\res\\mipmap-xxxhdpi\\launcher_icon.png";
  RegisterDesktopAppIdentity(kDesktopAppId, L"Fluent Player", path, icon);
}

void RegisterDesktopAppIdentity(const std::wstring& app_id,
    const std::wstring& display_name, const std::wstring& executable,
    const std::wstring& icon) {
  SetCurrentProcessExplicitAppUserModelID(app_id.c_str());
  const std::wstring key_path = std::wstring(L"Software\\Classes\\AppUserModelId\\") + app_id;
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, key_path.c_str(), 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    RegSetValueExW(key, L"DisplayName", 0, REG_SZ, reinterpret_cast<const BYTE*>(display_name.c_str()),
        static_cast<DWORD>((display_name.size() + 1) * sizeof(wchar_t)));
    if (GetFileAttributesW(icon.c_str()) != INVALID_FILE_ATTRIBUTES) {
      RegSetValueExW(key, L"IconUri", 0, REG_SZ, reinterpret_cast<const BYTE*>(icon.c_str()),
          static_cast<DWORD>((icon.size() + 1) * sizeof(wchar_t)));
    }
    RegCloseKey(key);
  }
  try { RegisterShortcut(app_id, display_name, executable); } catch (const winrt::hresult_error&) {
    // Shell registration failure must not prevent playback or application start.
  }
}
