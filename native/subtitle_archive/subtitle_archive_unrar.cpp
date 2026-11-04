// Extraction-only bridge over UnRAR 7.13 (RARDLL).
//
// UnRAR source code may be used in any software to handle RAR archives
// without limitations free of charge, but cannot be used to develop a RAR
// (WinRAR) compatible archiver and to re-create the RAR compression
// algorithm, which is proprietary. Distribution of modified UnRAR source
// must keep this paragraph. See third_party/unrar-src/unrar/license.txt.
//
// This wrapper never creates archives, never launches SFX modules, and never
// writes an entry under the name stored inside the archive. Callers pass a
// directory and a generated file name. C++ exceptions stay inside UnRAR's
// DLL entry points; this file still catches anything that escapes so a C++
// exception cannot cross into Dart.

#include <windows.h>

// Vendored UnRAR public header. The compiler include path points at
// third_party/unrar-src/unrar so this stays the upstream header.
#include "dll.hpp"

#include <atomic>
#include <cstdint>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <new>
#include <string>
#include <unordered_set>

namespace {

constexpr int kMissingVolume = 30;
constexpr int kCancelled = 31;
constexpr int kLimit = 33;
constexpr uint64_t kDefaultDictLimit = 64ull * 1024ull * 1024ull;

struct Archive {
  HANDLE handle = nullptr;
  bool pending = false;
  std::atomic<int> cancel{0};
  int password_offers = 0;
  std::wstring password;
  std::wstring diagnostic;
  uint64_t dict_limit = kDefaultDictLimit;
  int last_error = 0;
};

std::mutex g_live_mu;
std::unordered_set<Archive*> g_live;

bool live(Archive* archive) {
  std::lock_guard<std::mutex> lock(g_live_mu);
  return g_live.find(archive) != g_live.end();
}

void set_diagnostic(Archive* archive, const wchar_t* text) {
  archive->diagnostic = text == nullptr ? L"" : text;
}

int CALLBACK on_unrar(UINT msg, LPARAM user, LPARAM p1, LPARAM p2) {
  auto* archive = reinterpret_cast<Archive*>(user);
  if (archive == nullptr || !live(archive) || archive->cancel.load() != 0) {
    return -1;
  }
  switch (msg) {
    case UCM_PROCESSDATA:
      return archive->cancel.load() != 0 ? -1 : 1;
    case UCM_LARGEDICT: {
      // UnRAR passes dictionary size in KiB, not bytes.
      const auto kib = static_cast<uint64_t>(p1);
      if (kib > archive->dict_limit / 1024ull) {
        archive->last_error = kLimit;
        set_diagnostic(archive, L"dictionary");
        return -1;
      }
      return 1;
    }
    case UCM_CHANGEVOLUMEW: {
      archive->last_error = kMissingVolume;
      set_diagnostic(archive, reinterpret_cast<const wchar_t*>(p1));
      return -1;
    }
    case UCM_CHANGEVOLUME:
      archive->last_error = kMissingVolume;
      set_diagnostic(archive, L"");
      return -1;
    case UCM_NEEDPASSWORDW: {
      if (archive->password.empty() || archive->password_offers > 0) {
        archive->last_error = archive->password.empty()
                                   ? ERAR_MISSING_PASSWORD
                                   : ERAR_BAD_PASSWORD;
        return -1;
      }
      archive->password_offers++;
      auto* buffer = reinterpret_cast<wchar_t*>(p1);
      const auto capacity = static_cast<size_t>(p2);
      if (buffer == nullptr || capacity < 2) return -1;
      const auto count = archive->password.size() < capacity - 1
                             ? archive->password.size()
                             : capacity - 1;
      wmemcpy(buffer, archive->password.c_str(), count);
      buffer[count] = L'\0';
      return 1;
    }
    case UCM_NEEDPASSWORD:
      archive->last_error = archive->password.empty() ? ERAR_MISSING_PASSWORD
                                                      : ERAR_BAD_PASSWORD;
      return -1;
    default:
      return 1;
  }
}

int map_error(Archive* archive, int code) {
  if (archive->cancel.load() != 0) return kCancelled;
  if (archive->last_error != 0) return archive->last_error;
  return code;
}

void wipe_password(Archive* archive) {
  if (!archive->password.empty()) {
    SecureZeroMemory(&archive->password[0],
                     archive->password.size() * sizeof(wchar_t));
    archive->password.clear();
  }
}

}  // namespace

extern "C" {

__declspec(dllexport) const char* sub_unrar_version(void) {
  return "UnRAR 7.13 RARDLL extract-only";
}

__declspec(dllexport) void* sub_unrar_open(const wchar_t* path,
                                           const wchar_t* password,
                                           uint64_t dict_limit_bytes,
                                           int* error) {
  auto* archive = new (std::nothrow) Archive();
  if (archive == nullptr) {
    if (error != nullptr) *error = ERAR_NO_MEMORY;
    return nullptr;
  }
  if (password != nullptr && password[0] != L'\0') {
    archive->password = password;
  }
  if (dict_limit_bytes != 0) archive->dict_limit = dict_limit_bytes;
  {
    std::lock_guard<std::mutex> lock(g_live_mu);
    g_live.insert(archive);
  }
  try {
    RAROpenArchiveDataEx opened{};
    opened.ArcNameW = const_cast<wchar_t*>(path);
    opened.OpenMode = RAR_OM_EXTRACT;
    opened.Callback = on_unrar;
    opened.UserData = reinterpret_cast<LPARAM>(archive);
    archive->handle = RAROpenArchiveEx(&opened);
    if (archive->handle == nullptr || opened.OpenResult != ERAR_SUCCESS) {
      const int code = opened.OpenResult == 0 ? ERAR_EOPEN : opened.OpenResult;
      if (error != nullptr) *error = map_error(archive, code);
      wipe_password(archive);
      {
        std::lock_guard<std::mutex> lock(g_live_mu);
        g_live.erase(archive);
      }
      delete archive;
      return nullptr;
    }
    if (error != nullptr) *error = 0;
    return archive;
  } catch (...) {
    if (error != nullptr) *error = ERAR_UNKNOWN;
    wipe_password(archive);
    {
      std::lock_guard<std::mutex> lock(g_live_mu);
      g_live.erase(archive);
    }
    delete archive;
    return nullptr;
  }
}

__declspec(dllexport) void sub_unrar_cancel(void* handle) {
  auto* archive = static_cast<Archive*>(handle);
  if (archive == nullptr || !live(archive)) return;
  archive->cancel.store(1);
}

__declspec(dllexport) int sub_unrar_message(void* handle, wchar_t* buffer,
                                           int capacity) {
  auto* archive = static_cast<Archive*>(handle);
  if (archive == nullptr || buffer == nullptr || capacity < 1 || !live(archive)) {
    return 0;
  }
  const auto count = archive->diagnostic.size() < static_cast<size_t>(capacity - 1)
                         ? archive->diagnostic.size()
                         : static_cast<size_t>(capacity - 1);
  wmemcpy(buffer, archive->diagnostic.c_str(), count);
  buffer[count] = L'\0';
  return static_cast<int>(count);
}

struct SubEntryView {
  uint32_t flags;
  uint32_t method;
  uint32_t dict_kib;
  uint32_t crc32;
  uint32_t unpacked_low;
  uint32_t unpacked_high;
  uint32_t packed_low;
  uint32_t packed_high;
  uint32_t attributes;
  uint32_t name_bytes;
  char name_utf8[2048];
};

__declspec(dllexport) int sub_unrar_next(void* handle, SubEntryView* entry) {
  auto* archive = static_cast<Archive*>(handle);
  if (archive == nullptr || entry == nullptr || !live(archive)) return ERAR_EOPEN;
  if (archive->cancel.load() != 0) return kCancelled;
  if (archive->pending) return ERAR_UNKNOWN;
  try {
    RARHeaderDataEx header{};
    const int code = RARReadHeaderEx(archive->handle, &header);
    if (code == ERAR_END_ARCHIVE) return code;
    if (code != ERAR_SUCCESS) return map_error(archive, code);
    std::memset(entry, 0, sizeof(*entry));
    entry->method = header.Method;
    entry->dict_kib = header.DictSize;
    entry->crc32 = header.FileCRC;
    entry->unpacked_low = header.UnpSize;
    entry->unpacked_high = header.UnpSizeHigh;
    entry->packed_low = header.PackSize;
    entry->packed_high = header.PackSizeHigh;
    entry->attributes = header.FileAttr;
    uint32_t flags = 0;
    if (header.Flags & RHDF_DIRECTORY) flags |= 1;
    if (header.Flags & RHDF_ENCRYPTED) flags |= 2;
    if (header.Flags & RHDF_SOLID) flags |= 4;
    if (header.RedirType != 0) flags |= 8;
    if (header.Flags & RHDF_SPLITBEFORE) flags |= 16;
    if (header.Flags & RHDF_SPLITAFTER) flags |= 32;
    entry->flags = flags;
    const wchar_t* name = header.FileNameW[0] != L'\0'
                              ? header.FileNameW
                              : L"";
    const int written = WideCharToMultiByte(CP_UTF8, 0, name, -1, entry->name_utf8,
                                            sizeof(entry->name_utf8), nullptr,
                                            nullptr);
    entry->name_bytes = written > 0 ? static_cast<uint32_t>(written - 1) : 0;
    archive->pending = true;
    return 0;
  } catch (...) {
    return ERAR_UNKNOWN;
  }
}

__declspec(dllexport) int sub_unrar_skip(void* handle) {
  auto* archive = static_cast<Archive*>(handle);
  if (archive == nullptr || !live(archive) || archive->handle == nullptr) {
    return ERAR_EOPEN;
  }
  if (!archive->pending) return ERAR_UNKNOWN;
  if (archive->cancel.load() != 0) return kCancelled;
  try {
    const int code = RARProcessFileW(archive->handle, RAR_SKIP, nullptr, nullptr);
    archive->pending = false;
    return map_error(archive, code);
  } catch (...) {
    archive->pending = false;
    return ERAR_UNKNOWN;
  }
}

__declspec(dllexport) int sub_unrar_extract(void* handle, const wchar_t* directory,
                                           const wchar_t* file_name) {
  auto* archive = static_cast<Archive*>(handle);
  if (archive == nullptr || !live(archive) || archive->handle == nullptr) {
    return ERAR_EOPEN;
  }
  if (!archive->pending) return ERAR_UNKNOWN;
  if (archive->cancel.load() != 0) return kCancelled;
  if (directory == nullptr || file_name == nullptr) return ERAR_ECREATE;
  // Reject separators so an entry name cannot choose the output path.
  if (wcschr(file_name, L'\\') != nullptr || wcschr(file_name, L'/') != nullptr ||
      wcschr(file_name, L':') != nullptr) {
    return kLimit;
  }
  try {
    const int code = RARProcessFileW(archive->handle, RAR_EXTRACT,
                                     const_cast<wchar_t*>(directory),
                                     const_cast<wchar_t*>(file_name));
    archive->pending = false;
    return map_error(archive, code);
  } catch (...) {
    archive->pending = false;
    return ERAR_UNKNOWN;
  }
}

__declspec(dllexport) void sub_unrar_close(void* handle) {
  auto* archive = static_cast<Archive*>(handle);
  if (archive == nullptr) return;
  {
    std::lock_guard<std::mutex> lock(g_live_mu);
    if (g_live.erase(archive) == 0) return;
  }
  if (archive->handle != nullptr) {
    try {
      RARCloseArchive(archive->handle);
    } catch (...) {
    }
    archive->handle = nullptr;
  }
  wipe_password(archive);
  delete archive;
}

}  // extern "C"
