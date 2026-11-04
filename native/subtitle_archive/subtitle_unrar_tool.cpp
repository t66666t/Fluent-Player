// Standalone extractor. A MinGW DLL's C++ startup returns failure 1114 when
// dart.exe is the host, while the same objects run correctly as their own
// process. This tool is shipped beside the app; it is not 7-Zip or a system
// UnRAR install.
//
// UnRAR source code may be used to handle RAR archives but cannot be used to
// develop a RAR compatible archiver or re-create the RAR compression algorithm.

#include <windows.h>

#include "dll.hpp"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Session {
  std::wstring password;
  int passwordOffers = 0;
  std::string error = "ok";
  int code = 0;
};

int CALLBACK onUnrar(UINT msg, LPARAM user, LPARAM p1, LPARAM p2) {
  auto* session = reinterpret_cast<Session*>(user);
  switch (msg) {
    case UCM_NEEDPASSWORDW: {
      if (session->password.empty() || session->passwordOffers > 0) {
        session->code = session->password.empty() ? ERAR_MISSING_PASSWORD : ERAR_BAD_PASSWORD;
        return -1;
      }
      session->passwordOffers++;
      auto* buffer = reinterpret_cast<wchar_t*>(p1);
      const size_t capacity = static_cast<size_t>(p2);
      if (buffer == nullptr || capacity < 2) return -1;
      const size_t count = session->password.size() < capacity - 1
                               ? session->password.size()
                               : capacity - 1;
      wmemcpy(buffer, session->password.c_str(), count);
      buffer[count] = L'\0';
      return 1;
    }
    case UCM_LARGEDICT:
      if (static_cast<uint64_t>(p1) > (64ull * 1024ull)) {
        session->code = ERAR_LARGE_DICT;
        return -1;
      }
      return 1;
    case UCM_CHANGEVOLUMEW:
      session->code = 30;
      session->error = "missing-volume";
      return -1;
    default:
      return 1;
  }
}

std::string utf8FromWide(const wchar_t* value) {
  if (value == nullptr || value[0] == L'\0') return {};
  const int bytes = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  if (bytes <= 1) return {};
  std::string out(static_cast<size_t>(bytes - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, &out[0], bytes, nullptr, nullptr);
  return out;
}

void jsonEscape(std::string& out, const std::string& value) {
  for (unsigned char c : value) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
    }
  }
}

bool textExtension(const std::string& name) {
  const auto dot = name.rfind('.');
  if (dot == std::string::npos) return false;
  std::string ext = name.substr(dot);
  for (char& c : ext) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  return ext == ".srt" || ext == ".ass" || ext == ".ssa" || ext == ".vtt";
}

}  // namespace

int main() {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argc < 3) {
    std::fputs("{\"ok\":false,\"code\":15,\"error\":\"usage\"}\n", stdout);
    return 2;
  }
  Session session;
  if (const wchar_t* password = _wgetenv(L"SUBTITLE_UNRAR_PASSWORD")) {
    session.password = password;
  }
  RAROpenArchiveDataEx opened{};
  opened.ArcNameW = argv[1];
  opened.OpenMode = RAR_OM_EXTRACT;
  opened.Callback = onUnrar;
  opened.UserData = reinterpret_cast<LPARAM>(&session);
  HANDLE archive = RAROpenArchiveEx(&opened);
  if (archive == nullptr || opened.OpenResult != ERAR_SUCCESS) {
    std::printf("{\"ok\":false,\"code\":%u,\"error\":\"open\"}\n", opened.OpenResult);
    return 1;
  }
  wchar_t absolute[MAX_PATH];
  GetFullPathNameW(argv[2], MAX_PATH, absolute, nullptr);
  const std::wstring outdir = absolute;
  CreateDirectoryW(outdir.c_str(), nullptr);
  SetCurrentDirectoryW(outdir.c_str());
  std::string json = "{\"ok\":true,\"version\":\"UnRAR 7.13 RARDLL extract-only\",\"entries\":[";
  bool first = true;
  int index = 0;
  while (session.code == 0) {
    RARHeaderDataEx header{};
    const int read = RARReadHeaderEx(archive, &header);
    if (read == ERAR_END_ARCHIVE) break;
    if (read != ERAR_SUCCESS) {
      session.code = read;
      break;
    }
    uint32_t flags = 0;
    if (header.Flags & RHDF_DIRECTORY) flags |= 1;
    if (header.Flags & RHDF_ENCRYPTED) flags |= 2;
    if (header.Flags & RHDF_SOLID) flags |= 4;
    if (header.RedirType != 0) flags |= 8;
    if (header.Flags & RHDF_SPLITAFTER) flags |= 32;
    const std::string name = utf8FromWide(header.FileNameW);
    const uint64_t unpacked = static_cast<uint64_t>(header.UnpSize) |
                              (static_cast<uint64_t>(header.UnpSizeHigh) << 32);
    std::string fileName;
    const bool extract = (flags & (1 | 8)) == 0 && textExtension(name);
    if (extract) {
      wchar_t local[32];
      std::swprintf(local, 32, L"%05d.bin", index);
      const int code = RARProcessFileW(archive, RAR_EXTRACT, nullptr, local);
      if (code != ERAR_SUCCESS) {
        session.code = code;
        break;
      }
      fileName = utf8FromWide(local);
    } else if (RARProcessFileW(archive, RAR_SKIP, nullptr, nullptr) != ERAR_SUCCESS) {
      session.code = ERAR_BAD_DATA;
      break;
    }
    if (!first) json += ',';
    first = false;
    json += "{\"index\":" + std::to_string(index) + ",\"flags\":" + std::to_string(flags) +
            ",\"method\":" + std::to_string(header.Method) + ",\"dict\":" + std::to_string(header.DictSize) +
            ",\"unpacked\":" + std::to_string(unpacked) + ",\"name\":\"";
    jsonEscape(json, name);
    json += "\",\"file\":\"";
    jsonEscape(json, fileName);
    json += "\"}";
    index++;
    if (index > 2000) break;
  }
  RARCloseArchive(archive);
  json += "],\"code\":" + std::to_string(session.code) + "}\n";
  std::fwrite(json.data(), 1, json.size(), stdout);
  return session.code == 0 ? 0 : 1;
}
