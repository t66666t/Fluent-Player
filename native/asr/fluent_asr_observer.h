#pragma once
#include <atomic>
#include <filesystem>
#include <string>
namespace fluent_asr {
inline thread_local int device = 0;
inline thread_local bool profiling = false;
inline thread_local std::filesystem::path profile;
inline thread_local std::string cache;
inline thread_local std::string model_directory;
inline thread_local int mnn_backend = 0;
inline thread_local int mnn_executed = 0;
inline std::atomic<int> sequence{0};
}
