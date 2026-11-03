package com.example.video_player_app

import android.app.Service
import android.content.Intent
import android.os.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import org.json.JSONObject

/** Each private process contains CPU/GPU native inference for one worker. */
open class OcrAccelerationService : Service() {
    protected open val workerChannel = "com.example.video_player_app/ocr_worker"
    protected open val entryLibrary = "package:video_player_app/services/ocr_android_worker.dart"
    protected open val entryName = "ocrBackgroundMain"
    protected open fun decorateRequest(request: Map<String, Any?>, id: Int) = request
    protected open fun onWorkerCall(call: MethodCall, result: MethodChannel.Result) = result.notImplemented()
    protected fun sendWorkerEvent(id: Int, value: Map<String, Any?>) {
        try { client?.send(Message.obtain(null, 5).apply {
            arg1 = id
            data = Bundle().apply { putString("json", JSONObject(value).put("workerPid", Process.myPid()).toString()) }
        }) } catch (_: RemoteException) { stopSelf(); Process.killProcess(Process.myPid()) }
    }
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private val queued = mutableListOf<() -> Unit>()
    private var client: Messenger? = null
    private var nextAllocation = 0
    private val allocations = mutableMapOf<Int, MethodChannel.Result>()
    private val incoming = Messenger(Handler(Looper.getMainLooper()) { message ->
        when (message.what) {
            2 -> { stopSelf(); Process.killProcess(Process.myPid()) }
            4 -> {
                val result = allocations.remove(message.arg1)
                val error = message.data.getString("error")
                if (error == null) result?.success(null) else result?.error("memory", error, null)
            }
            1 -> {
                val id = message.arg1
                val reply = message.replyTo
                client = reply
                val input = message.data.getString("json") ?: "{}"
                fun respond(value: Map<String, Any?>) {
                    try { reply.send(Message.obtain(null, 1).apply {
                        arg1 = id
                        data = Bundle().apply {
                            putString("json", JSONObject(value).put("workerPid", Process.myPid()).toString())
                        }
                    }) } catch (_: RemoteException) {
                        stopSelf(); Process.killProcess(Process.myPid())
                    }
                }
                val work = {
                    try {
                        val request = toMap(JSONObject(input))
                        channel!!.invokeMethod("request", decorateRequest(request, id), object : MethodChannel.Result {
                            override fun success(result: Any?) {
                                @Suppress("UNCHECKED_CAST")
                                respond(result as? Map<String, Any?> ?: emptyMap())
                            }
                            override fun error(code: String, message: String?, details: Any?) {
                                // Do not log recognized text or file paths.
                                respond(mapOf("error" to (message ?: "OCR 加速不可用")))
                            }
                            override fun notImplemented() = respond(mapOf("workerFailure" to true))
                        })
                    } catch (_: Throwable) { respond(mapOf("workerFailure" to true)) }
                }
                if (ready) work() else queued.add(work)
            }
            else -> return@Handler false
        }
        true
    })
    override fun onCreate() {
        super.onCreate()
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(applicationContext)
            loader.ensureInitializationComplete(applicationContext, null)
            val child = FlutterEngine(this, null, false)
            engine = child
            channel = MethodChannel(child.dartExecutor.binaryMessenger,
                workerChannel).also { bridge ->
                bridge.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "ready" -> {
                            ready = true; result.success(null)
                            val tasks = queued.toList(); queued.clear(); tasks.forEach { it() }
                        }
                        "allocation" -> {
                            val id = ++nextAllocation
                            allocations[id] = result
                            val bytes = (call.argument<Number>("bytes"))?.toLong() ?: 0L
                            try { client?.send(Message.obtain(null, 3).apply {
                                arg1 = id; replyTo = incoming
                                data = Bundle().apply { putLong("bytes", bytes) }
                            }) ?: throw RemoteException("OCR controller disconnected") }
                            catch (_: Exception) { allocations.remove(id)?.error("closed", "OCR 已停止", null) }
                        }
                        else -> onWorkerCall(call, result)
                    }
                }
            }
            child.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(
                loader.findAppBundlePath(),
                entryLibrary, entryName))
        } catch (_: Throwable) { stopSelf(); Process.killProcess(Process.myPid()) }
    }
    override fun onBind(intent: Intent): IBinder = incoming.binder
    override fun onUnbind(intent: Intent): Boolean {
        // Never destroy an engine while a native Run may still be executing.
        stopSelf(); Process.killProcess(Process.myPid()); return false
    }
    companion object {
        private fun convert(v: Any?): Any? = when (v) {
            JSONObject.NULL -> null
            is JSONObject -> toMap(v)
            is org.json.JSONArray -> (0 until v.length()).map { convert(v.get(it)) }
            else -> v
        }
        private fun toMap(v: JSONObject): Map<String, Any?> = v.keys().asSequence().associateWith { convert(v.get(it)) }
    }
}

class OcrSecondaryService : OcrAccelerationService()
