package com.example.video_player_app

import android.content.*
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

/** Only small metadata crosses Binder. Frames remain in app-owned files. */
class OcrAccelerationBridge(context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "com.example.video_player_app/ocr_acceleration")
    private val connections = mutableListOf(
        BackgroundWorkerConnection(context, channel, 0, OcrAccelerationService::class.java),
        BackgroundWorkerConnection(context, channel, 1, OcrSecondaryService::class.java))
    init {
        channel.setMethodCallHandler { call, result ->
            val slot = call.argument<Number>("slot")?.toInt() ?: 0
            var worker = connections.getOrNull(slot)
            if (worker == null) { result.error("slot", "OCR 进程编号无效", null); return@setMethodCallHandler }
            if (worker.terminated) {
                worker = BackgroundWorkerConnection(context, channel, slot,
                    if (slot == 0) OcrAccelerationService::class.java else OcrSecondaryService::class.java)
                connections[slot] = worker
            }
            val current = worker
            when (call.method) {
                "close" -> {
                    current.close { stopped ->
                        if (stopped) result.success(null)
                        else result.error("shutdown_timeout", "OCR 进程仍在退出，暂不能重新启动", null)
                    }
                }
                "request" -> {
                    val command = call.argument<Map<String, Any?>>("command") ?: emptyMap()
                    current.send(command, result)
                }
                else -> result.notImplemented()
            }
        }
    }
    fun close() = connections.forEach { it.close() }
}

internal class BackgroundWorkerConnection(context: Context, private val channel: MethodChannel,
    private val slot: Int, private val service: Class<out android.app.Service>,
    private val eventMethod: String? = null) {
    private val app = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val pending = mutableMapOf<Int, MethodChannel.Result>()
    private val timeouts = mutableMapOf<Int, Runnable>()
    private val queued = mutableListOf<() -> Unit>()
    private var nextId = 0
    private var remote: Messenger? = null
    private val closed: Boolean get() = lifecycle.closed
    val terminated: Boolean get() = lifecycle.terminated
    private var closeTimeout: Runnable? = null
    private val deathRecipient = IBinder.DeathRecipient { handler.post { processDied() } }
    private val lifecycle: BackgroundWorkerLifecycle = BackgroundWorkerLifecycle(
        stop = {
            try { remote?.send(Message.obtain(null, 2)) }
            catch (_: RemoteException) {
                if (remote?.binder?.isBinderAlive != true) processDied()
            }
        },
        unbind = { try { app.unbindService(connection) } catch (_: Exception) {} },
        failPending = {
            queued.clear()
            timeouts.values.forEach { handler.removeCallbacks(it) }; timeouts.clear()
            val results = pending.values.toList(); pending.clear()
            results.forEach { it.success(failure()) }
        },
    )
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what == 5) {
            if (!closed && eventMethod != null && pending.containsKey(message.arg1)) {
                // Translation can be long while still streaming normally.
                timeouts[message.arg1]?.let { handler.removeCallbacks(it); handler.postDelayed(it, 85_000L) }
                try { channel.invokeMethod(eventMethod, toMap(JSONObject(message.data.getString("json") ?: "{}"))) }
                catch (_: Exception) { close() }
            }
        } else if (message.what == 3) {
            val target = message.replyTo
            val allocationId = message.arg1
            if (closed) {
                try { target?.send(Message.obtain(null, 4).apply {
                    arg1 = allocationId
                    data = Bundle().apply { putString("error", "OCR 已停止") }
                }) } catch (_: RemoteException) {}
                return@Handler true
            }
            val bytes = message.data.getLong("bytes")
            channel.invokeMethod("allocation", mapOf("slot" to slot, "bytes" to bytes), object : MethodChannel.Result {
                private fun reply(error: String?) {
                    try { target?.send(Message.obtain(null, 4).apply {
                        arg1 = allocationId
                        data = Bundle().apply { putString("error", error) }
                    }) } catch (_: RemoteException) { /* Cancelled. */ }
                }
                override fun success(result: Any?) = reply(null)
                override fun error(code: String, message: String?, details: Any?) = reply(message ?: "内存不足")
                override fun notImplemented() = reply("OCR 资源控制不可用")
            })
        } else {
            val result = pending.remove(message.arg1)
            timeouts.remove(message.arg1)?.let { handler.removeCallbacks(it) }
            if (result != null) {
                try {
                    val json = JSONObject(message.data.getString("json") ?: "{}")
                    result.success(toMap(json))
                } catch (_: Exception) { result.success(failure()) }
            }
        }
        true
    })
    private val connection: ServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            if (terminated) return
            remote = Messenger(binder)
            try { binder.linkToDeath(deathRecipient, 0) }
            catch (_: RemoteException) { processDied(); return }
            lifecycle.connected()
            if (!closed) {
                val tasks = queued.toList(); queued.clear(); tasks.forEach { it() }
            }
        }
        override fun onServiceDisconnected(name: ComponentName) = processDied()
        override fun onBindingDied(name: ComponentName) {
            if (remote?.binder?.isBinderAlive == true) close() else processDied()
        }
        override fun onNullBinding(name: ComponentName) = processDied()
    }
    private fun failure() = mapOf("workerFailure" to true)
    fun send(args: Map<String, Any?>, result: MethodChannel.Result) {
        if (closed) { result.success(failure()); return }
        val json = JSONObject(args).toString()
        if (json.length > 131072) { result.success(failure()); return }
        val id = ++nextId
        pending[id] = result
        val operation = {
            if (pending.containsKey(id)) {
                try { remote?.send(Message.obtain(null, 1).apply {
                    arg1 = id; replyTo = replies
                    data = Bundle().apply { putString("json", json) }
                }) ?: throw RemoteException("OCR disconnected") }
                catch (_: Exception) { close() }
            }
        }
        val timeout = Runnable { if (pending.containsKey(id)) close() }
        timeouts[id] = timeout
        handler.postDelayed(timeout, 85_000L)
        if (remote != null) operation() else {
            queued.add(operation)
            if (!lifecycle.binding) {
                try {
                    lifecycle.bindingStarted()
                    val bound = app.bindService(Intent(app, service),
                        connection, Context.BIND_AUTO_CREATE)
                    if (!bound) processDied()
                } catch (_: Exception) { processDied() }
            }
        }
    }
    fun close(done: ((Boolean) -> Unit)? = null) {
        lifecycle.close(done)
        if (!terminated && closeTimeout == null) {
            closeTimeout = Runnable {
                closeTimeout = null
                lifecycle.closeTimedOut()
            }.also { handler.postDelayed(it, 10_000L) }
        }
    }
    private fun processDied() {
        closeTimeout?.let { handler.removeCallbacks(it) }; closeTimeout = null
        try { remote?.binder?.unlinkToDeath(deathRecipient, 0) } catch (_: Exception) {}
        remote = null
        lifecycle.disconnected()
    }
    companion object {
        private fun convert(v: Any?): Any? = when (v) {
            JSONObject.NULL -> null
            is JSONObject -> toMap(v)
            is JSONArray -> (0 until v.length()).map { convert(v.get(it)) }
            else -> v
        }
        private fun toMap(v: JSONObject): Map<String, Any?> = v.keys().asSequence().associateWith { convert(v.get(it)) }
    }
}
