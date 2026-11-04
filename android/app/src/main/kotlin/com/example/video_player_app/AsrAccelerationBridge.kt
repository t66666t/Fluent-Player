package com.example.video_player_app

import android.content.*
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/** Metadata crosses Binder; PCM crosses a read-only file descriptor. */
class AsrAccelerationBridge(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, "com.example.video_player_app/asr_acceleration")
    private val handler = Handler(Looper.getMainLooper())
    private val timeouts = RequestTimeouts(
        postDelayed = { task, delay -> handler.postDelayed(task, delay) },
        removeCallbacks = { handler.removeCallbacks(it) },
    )
    private val pending = mutableMapOf<Int, MethodChannel.Result>()
    private val queued = mutableListOf<() -> Unit>()
    private var nextId = 0
    private var bound = false
    private var remote: Messenger? = null
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        timeouts.cancel(message.arg1)
        val result = pending.remove(message.arg1) ?: return@Handler true
        try {
            val json = JSONObject(message.data.getString("json") ?: "{}")
            result.success(toMap(json))
        } catch (_: Exception) { result.success(failure("转录 GPU 返回无效结果")) }
        true
    })
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            remote = Messenger(binder)
            val tasks = queued.toList(); queued.clear(); tasks.forEach { it() }
        }
        override fun onServiceDisconnected(name: ComponentName) { failAll("转录 GPU 进程已退出，使用 CPU") }
        override fun onBindingDied(name: ComponentName) { failAll("转录 GPU 连接已失效，使用 CPU") }
        override fun onNullBinding(name: ComponentName) { failAll("转录 GPU 服务不可用，使用 CPU") }
    }
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "environment" -> {
                    // No service binding or NNAPI call: safe even when the GPU
                    // worker could not initialize on the previous task.
                    val apk = File(app.applicationInfo.sourceDir)
                    val library = File(app.applicationInfo.nativeLibraryDir, "libfluent_asr_accel.so")
                    result.success(listOf(Build.FINGERPRINT, Build.SUPPORTED_ABIS.toList(),
                        apk.length(), apk.lastModified(), library.length(), library.lastModified()))
                }
                "close" -> { close(); result.success(null) }
                "request" -> {
                    @Suppress("UNCHECKED_CAST")
                    val args = call.arguments as? Map<String, Any?> ?: emptyMap()
                    send(args, result)
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun failure(message: String) = mapOf("ok" to false, "error" to message)
    private fun failAll(message: String) {
        timeouts.clear()
        remote = null; queued.clear()
        val results = pending.values.toList(); pending.clear()
        results.forEach { it.success(failure(message)) }
    }
    private fun send(args: Map<String, Any?>, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 24) { result.success(failure("此系统使用 CPU 转录")); return }
        val id = ++nextId
        pending[id] = result
        val operation = {
            if (pending.containsKey(id)) {
                var audio: ParcelFileDescriptor? = null
                try {
                    val json = JSONObject(args)
                    if (args["op"] == "decode") {
                        val file = File(args["path"] as String).canonicalFile
                        val allowed = listOf(app.filesDir, app.cacheDir, app.getExternalFilesDir(null))
                            .filterNotNull().any { file.path.startsWith(it.canonicalPath + File.separator) }
                        require(allowed) { "PCM outside app storage" }
                        audio = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                        json.remove("path")
                    }
                    remote?.send(Message.obtain(null, 1).apply {
                        arg1 = id; replyTo = replies
                        data = Bundle().apply {
                            putString("json", json.toString())
                            audio?.let { putParcelable("audio", it) }
                        }
                    }) ?: throw RemoteException("GPU service disconnected")
                } catch (_: Exception) {
                    timeouts.cancel(id)
                    pending.remove(id)?.success(failure("转录 GPU 请求失败，使用 CPU"))
                } finally { audio?.close() }
            }
        }
        if (remote != null) operation() else {
            queued.add(operation)
            if (!bound) {
                bound = try {
                    app.bindService(Intent(app, AsrAccelerationService::class.java), connection, Context.BIND_AUTO_CREATE)
                } catch (_: Exception) { false }
                if (!bound) failAll("无法启动转录 GPU 进程，使用 CPU")
            }
        }
        // Keep the existing post-dispatch deadline, but do not arm work that
        // already failed synchronously during send/binding.
        if (pending.containsKey(id)) {
            timeouts.schedule(id, if (args["op"] == "load") 120_000L else 60_000L) {
                if (pending.containsKey(id)) { close("转录 GPU 响应超时，使用 CPU") }
            }
        }
    }
    fun close(reason: String = "转录加速已停止") {
        try { remote?.send(Message.obtain(null, 2)) } catch (_: RemoteException) {}
        failAll(reason)
        if (bound) { try { app.unbindService(connection) } catch (_: IllegalArgumentException) {} }
        bound = false
    }
    companion object {
        private fun convert(value: Any?): Any? = when (value) {
            JSONObject.NULL -> null
            is JSONObject -> toMap(value)
            is org.json.JSONArray -> (0 until value.length()).map { convert(value.get(it)) }
            else -> value
        }
        private fun toMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence()
            .associateWith { convert(value.get(it)) }
    }
}
