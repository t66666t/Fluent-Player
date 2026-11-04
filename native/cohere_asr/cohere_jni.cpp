#include "cohere_worker.h"
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <string>

// The shared Android service implementation declares the JNI methods. Cohere
// runs in its own process and loads only this library; GGML symbols stay local.
extern "C" JNIEXPORT jlong JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeCreate(JNIEnv*, jobject) {
    return reinterpret_cast<intptr_t>(fluent_cohere_create());
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeRequest(JNIEnv* env, jobject, jlong handle, jbyteArray input) {
    const auto length = env->GetArrayLength(input);
    if (length > 1024 * 1024) return nullptr;
    std::string request(length, '\0');
    env->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte*>(request.data()));
    const auto response = fluent_cohere_request(reinterpret_cast<void*>(static_cast<intptr_t>(handle)), request.c_str());
    const auto size = static_cast<jsize>(std::strlen(response));
    auto output = env->NewByteArray(size);
    if (output) env->SetByteArrayRegion(output, 0, size, reinterpret_cast<const jbyte*>(response));
    return output;
}
extern "C" JNIEXPORT void JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeCancel(JNIEnv*, jobject, jlong handle) {
    fluent_cohere_cancel(reinterpret_cast<void*>(static_cast<intptr_t>(handle)));
}
extern "C" JNIEXPORT void JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeDestroy(JNIEnv*, jobject, jlong handle) {
    fluent_cohere_destroy(reinterpret_cast<void*>(static_cast<intptr_t>(handle)));
}
