package com.example.video_player_app

import android.app.Service
import android.content.Intent
import android.os.*
import org.json.JSONObject
import java.util.concurrent.Executors

/** A private, bound process. A native driver failure cannot take Flutter down. */
class AsrAccelerationService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private var nativeLoaded = false
    private external fun nativeRequest(request: ByteArray): ByteArray
    private val incoming = Messenger(Handler(Looper.getMainLooper()) { message ->
        if (message.what == 2) {
            stopSelf()
            Process.killProcess(Process.myPid())
            return@Handler true
        }
        if (message.what != 1) return@Handler false
        val id = message.arg1
        val reply = message.replyTo
        val data = message.data
        @Suppress("DEPRECATION")
        val audio = data.getParcelable<ParcelFileDescriptor>("audio")
        val input = data.getString("json") ?: "{}"
        executor.execute {
            val result = try {
                if (Build.VERSION.SDK_INT < 24) {
                    JSONObject().put("ok", false).put("error", "此系统使用 CPU").toString()
                } else {
                    if (!nativeLoaded) {
                        System.loadLibrary("fluent_asr_accel")
                        nativeLoaded = true
                    }
                    val request = JSONObject(input)
                    audio?.let { request.put("path", "/proc/self/fd/${it.fd}") }
                    nativeRequest(request.toString().toByteArray(Charsets.UTF_8)).toString(Charsets.UTF_8)
                }
            } catch (error: Throwable) {
                // No audio or recognized text in error messages or logcat.
                JSONObject().put("ok", false).put("error",
                    "转录加速组件不可用（${error.javaClass.simpleName}），使用 CPU").toString()
            } finally {
                audio?.close()
            }
            try {
                reply.send(Message.obtain(null, 1).apply {
                    arg1 = id
                    this.data = Bundle().apply { putString("json", JSONObject(result).put("workerPid", Process.myPid()).toString()) }
                })
            } catch (_: RemoteException) { /* Client already cancelled. */ }
        }
        true
    })
    override fun onBind(intent: Intent): IBinder = incoming.binder
    override fun onDestroy() { executor.shutdownNow(); super.onDestroy() }
}
