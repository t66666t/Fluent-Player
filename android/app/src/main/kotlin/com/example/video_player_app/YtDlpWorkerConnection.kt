package com.example.video_player_app
import android.content.Context
import android.content.Intent
/** No service, process, Python interpreter, resolver or media downloader exists here. */
internal class YtDlpWorkerConnection(context: Context, onStarted: (String) -> Unit, onEvent: (Intent) -> Unit) {
    fun enqueue(taskId: String, requestJson: String) { throw UnsupportedOperationException("Community edition") }
    fun requestStop(taskId: String, reason: String): Boolean = false
    fun finished(taskId: String) {}
    fun close() {}
}
