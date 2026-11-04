package com.example.video_player_app

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** A separate address space for native GGUF GPU drivers and their allocations. */
class TranslationAccelerationService : OcrAccelerationService() {
    override val workerChannel = "com.example.video_player_app/translation_worker"
    override val entryLibrary = "package:video_player_app/features/model_center/translation_android_inference.dart"
    override val entryName = "translationBackgroundMain"
    override fun decorateRequest(request: Map<String, Any?>, id: Int) = request + ("transportId" to id)
    override fun onWorkerCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "delta") { result.notImplemented(); return }
        val id = call.argument<Number>("transportId")?.toInt() ?: -1
        sendWorkerEvent(id, mapOf("id" to call.argument<Number>("id")?.toInt(),
            "text" to call.argument<String>("text")))
        result.success(null)
    }
}
