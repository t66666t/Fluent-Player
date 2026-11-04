#pragma once
#ifdef _WIN32
#define FLUENT_PARAKEET_JA_API __declspec(dllexport)
#else
#define FLUENT_PARAKEET_JA_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
FLUENT_PARAKEET_JA_API void* fluent_parakeet_ja_create(void);
FLUENT_PARAKEET_JA_API const char* fluent_parakeet_ja_request(void*, const char*);
FLUENT_PARAKEET_JA_API void fluent_parakeet_ja_cancel(void*);
FLUENT_PARAKEET_JA_API void fluent_parakeet_ja_destroy(void*);
#ifdef __cplusplus
}
#endif
