#ifndef RUNNER_DESKTOP_APP_IDENTITY_H_
#define RUNNER_DESKTOP_APP_IDENTITY_H_

#include <string>

// Must match the installer shortcuts. This is Shell identity, not a media title.
inline constexpr wchar_t kDesktopAppId[] = L"cn.teezy.fluentplayer.standard";
inline constexpr wchar_t kDesktopShortcutGroup[] = L"Fluent Player";
void InitializeDesktopAppIdentity();
void RegisterDesktopAppIdentity(const std::wstring& app_id,
    const std::wstring& display_name, const std::wstring& executable,
    const std::wstring& icon);

#endif
