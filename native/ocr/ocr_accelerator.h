#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>
#include <stdexcept>
#if defined(_WIN32)
#define OCR_API extern "C" __declspec(dllexport)
#else
#define OCR_API extern "C" __attribute__((visibility("default"), used))
#endif
namespace fluent_ocr {
struct Result {
    std::vector<int64_t> shape;
    std::vector<float> data;
};
class Session {
public:
    virtual ~Session() = default;
    virtual Result* run(const float* data, const int64_t* shape, int rank) = 0;
};
constexpr size_t kMaxOutputBytes = 32 * 1024 * 1024;
inline size_t elements(const int64_t* shape, int rank, size_t limit) {
    if (!shape || rank < 1 || rank > 8) throw std::runtime_error("Invalid OCR tensor rank");
    size_t count = 1;
    for (int i = 0; i < rank; ++i) {
        if (shape[i] <= 0 || size_t(shape[i]) > limit / count)
            throw std::runtime_error("OCR tensor exceeds memory limit");
        count *= size_t(shape[i]);
    }
    return count;
}
Session* createQnn(const char* path, int backend, int threads);
bool probeQnn(int backend);
std::string gpuDevice(int backend);
}
