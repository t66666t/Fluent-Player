#include <windows.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <thread>

#define API extern "C" __declspec(dllexport)
namespace {
struct Session { bool long_job; int state = 0; int result = -1; };
std::map<long, Session> sessions;
std::mutex mutex;
std::atomic_bool cancelled{false};
long next_id = 1;
void (*complete)(long, int) = nullptr;
char* copy(const char* text) {
  const size_t length = strlen(text) + 1;
  auto value = static_cast<char*>(malloc(length));
  memcpy(value, text, length);
  return value;
}
}
API char* ffmpegkit_create_ffmpeg_session(const char** arguments, int count) {
  bool long_job = false;
  for (int index = 0; index < count; ++index) {
    if (strcmp(arguments[index], "-re") == 0) long_job = true;
  }
  std::lock_guard<std::mutex> lock(mutex);
  const long id = next_id++;
  sessions.emplace(id, Session{long_job});
  cancelled.store(false);
  char output[256];
  sprintf_s(output, "{\"sessionId\":%ld,\"createTime\":0,\"startTime\":0,\"command\":\"native lifetime fixture\",\"type\":1}", id);
  return copy(output);
}
API void ffmpegkit_ffmpeg_execute(long id) {
  bool long_job;
  {
    std::lock_guard<std::mutex> lock(mutex);
    sessions.at(id).state = 1;
    long_job = sessions.at(id).long_job;
  }
  printf("FIXTURE job=%ld running long=%d\n", id, long_job); fflush(stdout);
  if (long_job) {
    wchar_t ignore[32]{};
    GetEnvironmentVariableW(L"FLUENT_AUDIT_IGNORE_CANCEL_MS", ignore, ARRAYSIZE(ignore));
    const auto ignoreUntil = GetTickCount64() + _wtoi(ignore);
    while (GetTickCount64() < ignoreUntil) Sleep(10);
    while (!cancelled.load()) Sleep(10);
  } else {
    Sleep(50);
  }
  {
    std::lock_guard<std::mutex> lock(mutex);
    sessions.at(id).state = 3;
    sessions.at(id).result = long_job ? 255 : 0;
  }
  printf("FIXTURE job=%ld returned cancelled=%d\n", id, cancelled.load()); fflush(stdout);
}
API void ffmpegkit_async_ffmpeg_execute(long id) {
  std::thread([id] {
    ffmpegkit_ffmpeg_execute(id);
    if (complete) complete(id, 1);
  }).detach();
}
API int ffmpegkit_session_get_state(long id) {
  std::lock_guard<std::mutex> lock(mutex); return sessions.at(id).state;
}
API char* ffmpegkit_get_session_json(long id) {
  char output[256];
  sprintf_s(output, "{\"sessionId\":%ld,\"createTime\":0,\"startTime\":0,\"command\":\"native lifetime fixture\",\"type\":1}", id);
  return copy(output);
}
API int ffmpegkit_session_get_return_code(long id) {
  std::lock_guard<std::mutex> lock(mutex); return sessions.at(id).result;
}
API void ffmpegkit_cancel() {
  if (!cancelled.exchange(true)) { printf("FIXTURE cancel received\n"); fflush(stdout); }
}
API void ffmpegkit_cancel_session(long) { ffmpegkit_cancel(); }
API void ffmpegkit_enable_ffmpeg_session_complete_callback(void (*value)(long, int)) { complete = value; }
API void ffmpegkit_enable_redirection() {}
API void ffmpegkit_disable_redirection() { printf("FIXTURE log consumer joined\n"); fflush(stdout); }
API int ffmpegkit_get_log_level() { return 32; }
API char* ffmpegkit_get_package_name() { return copy("lifetime-fixture"); }
API char* ffmpegkit_get_arch() { return copy("x86_64"); }
API char* ffmpegkit_get_ffmpeg_version() { return copy("test fixture"); }
API char* ffmpegkit_get_build_date() { return copy("20261031"); }
API void ffmpegkit_free(void* pointer) { free(pointer); }
BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
  if (reason == DLL_PROCESS_DETACH) {
    const char text[] = "FIXTURE native module detached\n";
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, sizeof(text) - 1, &written, nullptr);
  }
  return TRUE;
}
