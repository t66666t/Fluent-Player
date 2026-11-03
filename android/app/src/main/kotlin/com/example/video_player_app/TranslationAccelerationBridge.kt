package com.example.video_player_app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class TranslationAccelerationBridge(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, "com.example.video_player_app/translation_acceleration")
    private fun connection() = BackgroundWorkerConnection(app, channel, 0,
        TranslationAccelerationService::class.java, "delta")
    private var worker = connection()
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "request" -> {
                    if (worker.terminated) worker = connection()
                    worker.send(call.argument<Map<String, Any?>>("command") ?: emptyMap(), result)
                }
                "close" -> worker.close { stopped ->
                    if (stopped) result.success(null)
                    else result.error("shutdown_timeout", "翻译进程仍在退出，暂不能重新启动", null)
                }
                else -> result.notImplemented()
            }
        }
    }
    fun close() { worker.close() }
}
