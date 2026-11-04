package com.example.video_player_app

import android.content.*
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException

/** One private service, independently owned ASR/enhancement sessions. */
class QwenAsrBridge @JvmOverloads constructor(
    context: Context, messenger: BinaryMessenger,
    component: String = "qwen_asr",
    private val serviceClass: Class<out QwenAsrService> = QwenAsrService::class.java,
    private val label: String = "Qwen",
) {
    private val app = context.applicationContext
    private val channel = MethodChannel(messenger, "com.example.video_player_app/$component")
    private val handler = Handler(Looper.getMainLooper())
    private val timeouts = RequestTimeouts(
        postDelayed = { task, delay -> handler.postDelayed(task, delay) },
        removeCallbacks = { handler.removeCallbacks(it) },
    )
    private data class Pending(val owner: String, val result: MethodChannel.Result, val gpu: Boolean)
    private val pending = mutableMapOf<Int, Pending>()
    private val closing = mutableMapOf<Int, () -> Unit>()
    private val owners = mutableSetOf<String>()
    private val queued = mutableListOf<() -> Unit>()
    private var nextId = 0
    private var bound = false
    private var remote: Messenger? = null
    private val gpuOwners = mutableSetOf<String>()
    private var workerPid = 0
    private var gpuNativeCrash = false
    private var gpuTimedOut = false
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        timeouts.cancel(message.arg1)
        closing.remove(message.arg1)?.let { it(); return@Handler true }
        val entry = pending.remove(message.arg1) ?: return@Handler true
        try {
            val json = JSONObject(message.data.getString("json") ?: "{}")
            workerPid = json.optInt("workerPid", workerPid)
            entry.result.success(toMap(json))
        }
        catch (_: Exception) { entry.result.success(failure("$label 音频返回无效结果")) }
        true
    })
    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            remote = Messenger(binder)
            val operations = queued.toList(); queued.clear(); operations.forEach { it() }
        }
        override fun onServiceDisconnected(name: ComponentName) {
            // A confirmed native GPU crash is scoped to this app session.
            // Memory kills do not mark a backend faulty. All owners share the
            // private process, so later alignment must not retry a bad driver.
            if (Build.VERSION.SDK_INT >= 30 && pending.values.any { it.gpu }) {
                val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                gpuNativeCrash = gpuNativeCrash || runCatching {
                    manager.getHistoricalProcessExitReasons(null, workerPid, 1)
                        .any { it.pid == workerPid && it.reason == ApplicationExitInfo.REASON_CRASH_NATIVE }
                }.getOrDefault(false)
            }
            failAll("$label 音频进程已退出，已保留有效断点")
        }
        override fun onBindingDied(name: ComponentName) { closeAll() }
        override fun onNullBinding(name: ComponentName) { closeAll() }
    }
    init {
        channel.setMethodCallHandler { call, result ->
            @Suppress("UNCHECKED_CAST")
            val args = call.arguments as? Map<String, Any?> ?: emptyMap()
            val owner = args["owner"] as? String
            if (owner.isNullOrBlank() || owner.length > 128) {
                result.success(failure("无效的音频组件所有者"))
            } else when (call.method) {
                "request" -> send(owner, args, result)
                "close" -> closeOwner(owner) { result.success(null) }
                else -> result.notImplemented()
            }
        }
    }
    private fun failure(message: String) = mapOf("ok" to false, "error" to message)
    private fun failAll(message: String) {
        timeouts.clear()
        remote = null; queued.clear()
        val entries = pending.values.toList(); pending.clear()
        val completed=closing.values.toList(); closing.clear()
        entries.forEach { it.result.success(failure(message)) }
        completed.forEach { it() }
    }
    private fun send(owner: String, args: Map<String, Any?>, result: MethodChannel.Result) {
        if (args["op"] == "capabilities" && (gpuNativeCrash || gpuTimedOut)) {
            result.success(mapOf("ok" to true, "devices" to emptyList<Any>(),
                "gpuUnavailableReason" to if (gpuTimedOut)
                    "GPU 音频计算响应超时，本次运行改用 CPU"
                    else "本次运行检测到 GPU 驱动崩溃，$label 已改用 CPU"))
            return
        }
        val id = ++nextId
        if (args["op"] == "load") {
            if (args["backend"] != "cpu") gpuOwners.add(owner) else gpuOwners.remove(owner)
        }
        pending[id] = Pending(owner, result, args["op"] == "capabilities" || gpuOwners.contains(owner))
        if (args["op"] == "open") owners.add(owner)
        val operation = operation@{
            if (!pending.containsKey(id)) return@operation
            var audio: ParcelFileDescriptor? = null
            try {
                val json = JSONObject(args)
                if (args["op"] in listOf("decode", "align", "identify")) {
                    val file = File(args["path"] as String).canonicalFile
                    // Flutter's Directory.systemTemp uses codeCacheDir on
                    // current Android engines, independently of cacheDir.
                    val allowed = listOf(app.filesDir, app.cacheDir, app.codeCacheDir,
                        app.getExternalFilesDir(null), app.externalCacheDir)
                        .filterNotNull().any { file.path.startsWith(it.canonicalPath + File.separator) }
                    require(allowed) { "PCM outside app storage" }
                    audio = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                    json.remove("path")
                }
                remote?.send(Message.obtain(null, 1).apply {
                    arg1 = id; replyTo = replies
                    data = Bundle().apply { putString("json", json.toString()); audio?.let { putParcelable("audio", it) } }
                }) ?: throw RemoteException("Audio service disconnected")
            } catch (error: Exception) {
                val message = when (error) {
                    is FileNotFoundException -> "$label 临时音频不存在或无法读取"
                    is SecurityException -> "$label 临时音频读取权限不足"
                    is IllegalArgumentException -> "$label 临时音频路径不在应用缓存目录内"
                    is DeadObjectException -> "$label 音频进程已退出，已保留有效断点"
                    else -> "$label 音频请求失败（${error.javaClass.simpleName}）"
                }
                timeouts.cancel(id)
                pending.remove(id)?.result?.success(failure(message))
            } finally { audio?.close() }
        }
        if (remote != null) operation() else {
            queued.add(operation)
            if (!bound) {
                bound = try {
                    app.bindService(Intent(app, serviceClass), connection, Context.BIND_AUTO_CREATE)
                } catch (_: Exception) { false }
                if (!bound) failAll("无法启动 $label 音频组件")
            }
        }
        val gpuAudio = gpuOwners.contains(owner) && args["op"] in listOf("decode", "align")
        if (pending.containsKey(id)) {
            timeouts.schedule(id, qwenRequestTimeoutMillis(args["op"] as? String, gpuAudio)) {
                if (pending.containsKey(id)) {
                    if (gpuAudio) {
                        // A hung vendor fence cannot be cancelled by an atomic
                        // native flag. Reset the shared private process; CPU owners
                        // reopen once instead of retaining dead native contexts.
                        gpuTimedOut = true
                        if (workerPid > 0 && remote?.binder?.isBinderAlive == true) {
                            // Same-UID private service. Binder reports death before
                            // failAll wakes clients, so retries cannot bind the
                            // still-stopping native process.
                            Process.killProcess(workerPid)
                        } else closeAll()
                    } else closeOwner(owner)
                }
            }
        }
    }
    private fun closeOwner(owner: String, completed: (() -> Unit)? = null) {
        owners.remove(owner)
        gpuOwners.remove(owner)
        val id=++nextId
        val done = {
            completed?.invoke()
            if (owners.isEmpty() && bound) {
                try { app.unbindService(connection) } catch (_: IllegalArgumentException) {}
                remote=null; bound=false
            }
        }
        closing[id]=done
        try {
            remote?.send(Message.obtain(null, 2).apply {
                arg1=id; replyTo=replies; data = Bundle().apply { putString("owner", owner) }
            }) ?: closing.remove(id)?.invoke()
        } catch (_: RemoteException) { closing.remove(id)?.invoke() }
        val ids = pending.filterValues { it.owner == owner }.keys.toList()
        ids.forEach {
            timeouts.cancel(it)
            pending.remove(it)?.result?.success(failure("转录已取消或响应超时"))
        }
        if (closing.containsKey(id)) {
            timeouts.schedule(id, 4000L) { closing.remove(id)?.invoke() }
        }
    }
    fun closeAll() {
        try { remote?.send(Message.obtain(null, 3)) } catch (_: RemoteException) {}
        owners.clear(); gpuOwners.clear(); failAll("$label 音频组件已关闭")
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
        private fun toMap(value: JSONObject): Map<String, Any?> = value.keys().asSequence().associateWith { convert(value.get(it)) }
    }
}
