#pragma once
#ifdef _WIN32
#define FLUENT_QWEN_API __declspec(dllexport)
#else
#define FLUENT_QWEN_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
FLUENT_QWEN_API void* fluent_qwen_create(void);
FLUENT_QWEN_API const char* fluent_qwen_request(void* handle, const char* request);
FLUENT_QWEN_API void fluent_qwen_cancel(void* handle);
FLUENT_QWEN_API void fluent_qwen_destroy(void* handle);
#ifdef __cplusplus
}
#endif
