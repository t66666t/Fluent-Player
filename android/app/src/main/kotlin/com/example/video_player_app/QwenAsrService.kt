package com.example.video_player_app

import android.app.Service
import android.content.Intent
import android.os.*
import org.json.JSONObject
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Driver failures stay outside Flutter; each native owner has one executor. */
open class QwenAsrService(
    private val nativeLibrary: String = "fluent_qwen_asr",
    private val label: String = "Qwen",
) : Service() {
    companion object {
        // The Android process may outlive and recreate a bound Service.
        // Old-instance cancellation timers must never kill a new instance.
        private val watchdog = QwenWorkerWatchdog()
    }
    private data class Session(val handle: Long, val executor: ExecutorService)
    private val sessions = mutableMapOf<String, Session>()
    private val main = Handler(Looper.getMainLooper())
    private var nativeLoaded = false
    private external fun nativeCreate(): Long
    private external fun nativeRequest(handle: Long, request: ByteArray): ByteArray
    private external fun nativeCancel(handle: Long)
    private external fun nativeDestroy(handle: Long)
    private fun reply(to: Messenger, id: Int, value: String) {
        try { to.send(Message.obtain(null, 1).apply {
            arg1 = id
            data = Bundle().apply { putString("json", JSONObject(value).put("workerPid", Process.myPid()).toString()) }
        }) } catch (_: RemoteException) { /* Client cancelled. */ }
    }
    private fun close(owner: String, completed: (() -> Unit)? = null) {
        val session = sessions.remove(owner) ?: run { completed?.invoke(); return }
        nativeCancel(session.handle)
        val generation = watchdog.generation
        session.executor.execute { nativeDestroy(session.handle); completed?.invoke() }
        session.executor.shutdown()
        // A stuck GPU dispatch must not keep a cancelled last owner alive.
        // Successful destruction needs no process kill: unbinding destroys the
        // service normally. Its old timer can otherwise kill the next batch.
        main.postDelayed({
            if (watchdog.shouldStop(generation, sessions.isEmpty(), session.executor.isTerminated)) {
                stopSelf(); Process.killProcess(Process.myPid())
            }
        }, 3000)
    }
    private val incoming = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what == 3) { stopSelf(); Process.killProcess(Process.myPid()); return@Handler true }
        if (message.what == 2) {
            val response = message.replyTo; val id = message.arg1
            close(message.data.getString("owner") ?: "") { if (response != null) reply(response,id,"{\"ok\":true}") }
            return@Handler true
        }
        if (message.what != 1) return@Handler false
        val id = message.arg1
        val response = message.replyTo
        @Suppress("DEPRECATION")
        val audio = message.data.getParcelable<ParcelFileDescriptor>("audio")
        try {
            if (!nativeLoaded) { System.loadLibrary(nativeLibrary); nativeLoaded = true }
            val request = JSONObject(message.data.getString("json") ?: "{}")
            val owner = request.getString("owner")
            if (request.optString("op") == "open") {
                if (!sessions.containsKey(owner)) {
                    watchdog.renew()
                    val handle = nativeCreate()
                    require(handle != 0L)
                    sessions[owner] = Session(handle, Executors.newSingleThreadExecutor())
                }
                audio?.close(); reply(response, id, "{\"ok\":true}")
            } else {
                val session = sessions[owner] ?: throw IllegalStateException("Closed audio owner")
                session.executor.execute {
                    val value = try {
                        audio?.let { request.put("path", "/proc/self/fd/${it.fd}") }
                        nativeRequest(session.handle, request.toString().toByteArray(Charsets.UTF_8)).toString(Charsets.UTF_8)
                    } catch (error: Throwable) {
                        JSONObject().put("ok", false).put("error", "$label 音频推理失败（${error.javaClass.simpleName}）").toString()
                    } finally { audio?.close() }
                    reply(response, id, value)
                }
            }
        } catch (error: Throwable) {
            audio?.close()
            reply(response, id, JSONObject().put("ok", false).put("error", "$label 原生组件不可用（${error.javaClass.simpleName}）").toString())
        }
        true
    })
    override fun onCreate() {
        super.onCreate()
        watchdog.renew()
    }
    override fun onBind(intent: Intent): IBinder = incoming.binder
    override fun onDestroy() {
        sessions.keys.toList().forEach { close(it) }
        super.onDestroy()
    }
}
