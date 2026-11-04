#pragma once
#ifdef _WIN32
#define FLUENT_COHERE_API __declspec(dllexport)
#else
#define FLUENT_COHERE_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
FLUENT_COHERE_API void* fluent_cohere_create(void);
FLUENT_COHERE_API const char* fluent_cohere_request(void*, const char*);
FLUENT_COHERE_API void fluent_cohere_cancel(void*);
FLUENT_COHERE_API void fluent_cohere_destroy(void*);
#ifdef __cplusplus
}
#endif
