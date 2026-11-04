package com.example.video_player_app

import android.app.Activity
import android.os.Debug
import android.os.Process
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import com.alexmercerind.media_kit_video.MediaKitVideoPlugin
import java.io.File

/** Registered only in the private diagnostic snapshot, never production. */
class ResourceAuditBridge(private val activity: Activity, private val engine: FlutterEngine,
                          private val asr: AsrAccelerationBridge, private val qwen: QwenAsrBridge) {
    private val resultStub = object : MethodChannel.Result {
        override fun success(result: Any?) {}
        override fun error(code: String, message: String?, details: Any?) { throw IllegalStateException("$code: $message") }
        override fun notImplemented() { throw IllegalStateException("Unsupported diagnostic method") }
    }
    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, "resource_audit/private").setMethodCallHandler { call, result ->
            try {
                when(call.method) {
                    "stats" -> result.success(stats())
                    "fireTimeout" -> result.success(mapOf("fired" to ResourceAuditCounters.fireOne(call.argument<String>("label")!!)))
                    "resize" -> {
                        val plugin = engine.plugins.get(MediaKitVideoPlugin::class.java) as MediaKitVideoPlugin
                        val managerField = plugin.javaClass.getDeclaredField("videoOutputManager").apply { isAccessible = true }
                        val manager = managerField.get(plugin)
                        val outputs = manager.javaClass.getDeclaredField("videoOutputs").apply { isAccessible = true }.get(manager) as Map<*, *>
                        for(handle in outputs.keys.toList()) {
                            plugin.onMethodCall(MethodCall("VideoOutputManager.SetSurfaceSize", mapOf("handle" to handle.toString(),
                                "width" to call.argument<Int>("width").toString(), "height" to call.argument<Int>("height").toString())), resultStub)
                        }
                        result.success(stats())
                    }
                    "detachEngine" -> {
                        // Use the initialized engine/renderer. A newly constructed
                        // engine without a FlutterView has no GPU context and cannot
                        // create a SurfaceProducer. Registry removal invokes the real
                        // onDetachedFromEngine callback with its own binding.
                        val plugin = engine.plugins.get(MediaKitVideoPlugin::class.java) as MediaKitVideoPlugin
                        plugin.onMethodCall(MethodCall("VideoOutputManager.Create", mapOf("handle" to "987654321")), resultStub)
                        plugin.onMethodCall(MethodCall("VideoOutputManager.SetSurfaceSize", mapOf("handle" to "987654321", "width" to "320", "height" to "180")), resultStub)
                        engine.plugins.remove(MediaKitVideoPlugin::class.java)
                        engine.plugins.add(MediaKitVideoPlugin())
                        result.success(stats())
                    }
                    else -> result.notImplemented()
                }
            } catch(error: Throwable) { result.error("audit", error.toString(), null) }
        }
    }
    private fun fieldSize(owner: Any, name: String): Int? = runCatching {
        val value = owner.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(owner)
        when(value) { is Map<*, *> -> value.size; is Collection<*> -> value.size; else -> null }
    }.getOrNull()
    private fun stats(): Map<String, Any?> {
        val info = Debug.MemoryInfo(); Debug.getMemoryInfo(info)
        val refs = runCatching { Class.forName("com.alexmercerind.media_kit_video.VideoOutput").getMethod("auditStats").invoke(null) }.getOrNull()
        return mapOf("pid" to Process.myPid(), "cpuMs" to Process.getElapsedCpuTime(),
            "totalPssKiB" to info.totalPss, "nativeHeapBytes" to Debug.getNativeHeapAllocatedSize(),
            "javaUsedBytes" to Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory(),
            "jni" to refs, "scheduledTimeouts" to ResourceAuditCounters.stats(),
            "asrPending" to fieldSize(asr, "pending"), "qwenPending" to fieldSize(qwen, "pending"),
            "qwenClosing" to fieldSize(qwen, "closing"), "externalFiles" to activity.getExternalFilesDir(null)?.path,
            "codeCache" to activity.codeCacheDir.path,
            "rssStatus" to File("/proc/self/status").readLines().filter { it.startsWith("VmRSS:") || it.startsWith("VmHWM:") })
    }
}
