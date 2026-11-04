#include "qwen_worker.h"
#include <jni.h>
#include <cstdint>
#include <cstring>
#include <string>

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeCreate(JNIEnv*, jobject) {
    return reinterpret_cast<intptr_t>(fluent_qwen_create());
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeRequest(JNIEnv* env, jobject, jlong handle, jbyteArray input) {
    jsize length=env->GetArrayLength(input);
    if(length>1024*1024) return nullptr;
    std::string request(length,'\0');
    env->GetByteArrayRegion(input,0,length,reinterpret_cast<jbyte*>(request.data()));
    const char* response=fluent_qwen_request(reinterpret_cast<void*>(static_cast<intptr_t>(handle)),request.c_str());
    auto size=static_cast<jsize>(std::strlen(response));
    jbyteArray output=env->NewByteArray(size);
    if(output) env->SetByteArrayRegion(output,0,size,reinterpret_cast<const jbyte*>(response));
    return output;
}
extern "C" JNIEXPORT void JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeCancel(JNIEnv*, jobject, jlong handle) {
    fluent_qwen_cancel(reinterpret_cast<void*>(static_cast<intptr_t>(handle)));
}
extern "C" JNIEXPORT void JNICALL
Java_com_example_video_1player_1app_QwenAsrService_nativeDestroy(JNIEnv*, jobject, jlong handle) {
    fluent_qwen_destroy(reinterpret_cast<void*>(static_cast<intptr_t>(handle)));
}
