#pragma once
#include <cstdint>
#if defined(_WIN32) && defined(FLUENT_ASR_MNN_BUILD)
#define ASR_MNN_API extern "C" __declspec(dllexport)
#elif defined(FLUENT_ASR_MNN_BUILD)
#define ASR_MNN_API extern "C" __attribute__((visibility("default"), used))
#else
#define ASR_MNN_API extern "C"
#endif
// Values use ONNX element types; allocations never cross runtime ownership.
struct FluentMnnTensor {
    int32_t type;
    int32_t rank;
    const int64_t* shape;
    const void* data;
};
ASR_MNN_API int FluentMnnAbi();
ASR_MNN_API const char* FluentMnnVersion();
ASR_MNN_API const char* FluentMnnError();
ASR_MNN_API int FluentMnnProbe(int backend);
ASR_MNN_API const char* FluentMnnDevice(int backend);
ASR_MNN_API void* FluentMnnOpen(const char* source, const char* cache, int backend);
ASR_MNN_API void FluentMnnClose(void* session);
ASR_MNN_API void* FluentMnnRun(void* session, const char* const* names,
    const FluentMnnTensor* inputs, int count, const char* const* outputs, int outputCount);
ASR_MNN_API int FluentMnnRead(void* result, int index, FluentMnnTensor* tensor);
ASR_MNN_API void FluentMnnFree(void* result);
ASR_MNN_API int FluentMnnAccelerated(void* session);
