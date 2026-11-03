package com.example.video_player_app

import android.app.ActivityManager
import android.content.*
import android.content.res.Configuration
import android.os.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor

/** Independent from model_tasks: resource events cannot replace pause/expiry. */
class ModelResourceBridge(private val context: Context, messenger: BinaryMessenger) :
    ComponentCallbacks2, EventChannel.StreamHandler {
    private val power = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    private val memory = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var started = false
    private var warnedAt = 0L
    private var lastHeadroomAt = 0L
    private var headroom: Float? = null
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) { changed() }
    }
    init {
        EventChannel(messenger, "com.example.video_player_app/model_resources/events").setStreamHandler(this)
        MethodChannel(messenger, "com.example.video_player_app/model_resources").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> { start(); result.success(null) }
                "stop" -> { stop(); result.success(null) }
                "snapshot" -> result.success(snapshot(call.argument<List<Number>>("pids") ?: emptyList()))
                else -> result.notImplemented()
            }
        }
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sink = events }
    override fun onCancel(arguments: Any?) { sink = null }
    private fun changed() { handler.post { sink?.success(mapOf("changed" to true)) } }
    private fun start() {
        if (started) return
        started = true
        context.registerComponentCallbacks(this)
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else @Suppress("DEPRECATION") context.registerReceiver(receiver, filter)
        if (Build.VERSION.SDK_INT >= 29) {
            thermalListener = PowerManager.OnThermalStatusChangedListener { changed() }
            power.addThermalStatusListener(Executor { handler.post(it) }, thermalListener!!)
        }
    }
    private fun stop() {
        if (!started) return
        started = false
        context.unregisterComponentCallbacks(this)
        context.unregisterReceiver(receiver)
        if (Build.VERSION.SDK_INT >= 29) thermalListener?.let { power.removeThermalStatusListener(it) }
        thermalListener = null
    }
    private fun rss(pid: Int): Long? = try {
        Regex("(?m)^VmRSS:\\s+(\\d+)\\s+kB").find(File("/proc/$pid/status").readText())
            ?.groupValues?.get(1)?.toLongOrNull()?.times(1024)
    } catch (_: Exception) { null }
    private fun allowedProcessors(): Int? = try {
        val text = Regex("(?m)^Cpus_allowed_list:\\s*(.+)$")
            .find(File("/proc/self/status").readText())?.groupValues?.get(1)
        val ids = mutableSetOf<Int>()
        text?.split(',')?.forEach { part ->
            val range = part.trim().split('-').mapNotNull { it.toIntOrNull() }
            if (range.size in 1..2 && range[0] >= 0 && range.last() >= range[0] && range.last() - range[0] < 4096) {
                ids.addAll(range[0]..range.last())
            }
        }
        ids.size.takeIf { it > 0 }
    } catch (_: Exception) { null }
    private fun snapshot(pids: List<Number>): Map<String, Any?> {
        val info = ActivityManager.MemoryInfo()
        memory.getMemoryInfo(info)
        val now = SystemClock.elapsedRealtime()
        if (Build.VERSION.SDK_INT >= 30 && (lastHeadroomAt == 0L || now - lastHeadroomAt >= 10000)) {
            lastHeadroomAt = now
            headroom = try { power.getThermalHeadroom(0).takeIf { it.isFinite() } } catch (_: Exception) { null }
        }
        val status = if (Build.VERSION.SDK_INT >= 29) power.currentThermalStatus else -1
        val thermal = when {
            status >= 3 || (headroom ?: 0f) >= 1f -> "severe"
            status >= 2 || (headroom ?: 0f) >= .8f -> "moderate"
            status == 1 -> "warm"
            status == 0 -> "normal"
            else -> "unknown"
        }
        var workerBytes = 0L
        var complete = true
        for (pid in pids.map { it.toInt() }.distinct()) {
            val value = rss(pid)
            if (value == null) complete = false else workerBytes += value
        }
        val recentWarning = warnedAt != 0L && now - warnedAt < 10000
        return mapOf("processors" to Runtime.getRuntime().availableProcessors(),
            "allowedProcessors" to allowedProcessors(),
            "memoryBytes" to info.totalMem, "availableMemoryBytes" to info.availMem,
            "memoryScope" to "system", "processBytes" to rss(Process.myPid()),
            "workerBytes" to workerBytes, "workerMemoryComplete" to complete,
            "memoryPressure" to if (info.lowMemory || recentWarning) "critical" else "normal",
            "thermal" to thermal, "thermalSupported" to (Build.VERSION.SDK_INT >= 29),
            "powerSaving" to power.isPowerSaveMode,
            "environment" to "${Build.FINGERPRINT}:${Build.VERSION.SDK_INT}")
    }
    override fun onTrimMemory(level: Int) {
        // UI_HIDDEN reports lifecycle, not exhausted memory.
        if (level == ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN) return
        if (level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
            level >= ComponentCallbacks2.TRIM_MEMORY_MODERATE) {
            warnedAt = SystemClock.elapsedRealtime()
            sink?.success(mapOf("memoryPressure" to "critical"))
        }
    }
    override fun onLowMemory() {
        warnedAt = SystemClock.elapsedRealtime()
        sink?.success(mapOf("memoryPressure" to "critical"))
    }
    override fun onConfigurationChanged(configuration: Configuration) {}
}
