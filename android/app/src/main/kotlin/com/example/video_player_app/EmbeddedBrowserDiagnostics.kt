package com.example.video_player_app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.webkit.WebView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Local, bounded diagnostics for the browser's Android UI-thread stall. */
internal class EmbeddedBrowserDiagnostics private constructor(context: Context, messenger: BinaryMessenger) {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "EmbeddedBrowserWatchdog").apply { isDaemon = true }
    }
    private val awaitingMain = AtomicBoolean(false)
    private val leases = linkedMapOf<String, String>()
    private val stage: String
        get() = leases.entries.joinToString { "${it.key}=${it.value}" }
    @Volatile private var lastAck = 0L
    private var monitor: ScheduledFuture<*>? = null
    private var captured = false
    private val stallFile get() = File(app.filesDir, "douyin-browser-stall.txt")

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            val id = call.argument<String>("lease")
            when (call.method) {
                "start" -> {
                    if (id != null) start(id)
                    result.success(null)
                }
                "closing" -> {
                    worker.execute { if (id != null && leases.containsKey(id)) leases[id] = "closing" }
                    result.success(null)
                }
                "stop" -> {
                    // Include asynchronous WebView teardown in the watch window.
                    worker.schedule({
                        leases.remove(id)
                        if (leases.isEmpty()) {
                            monitor?.cancel(false)
                            monitor = null
                            awaitingMain.set(false)
                        }
                    }, 6, TimeUnit.SECONDS)
                    result.success(null)
                }
                "record" -> {
                    val event = call.argument<String>("event").orEmpty().take(256)
                    worker.execute {
                        val file = File(app.filesDir, "embedded-browser-events.txt")
                        val entry = "timeMillis=${System.currentTimeMillis()} browser=$id $event\n"
                        runCatching {
                            val old = if (file.isFile) file.readText().takeLast(12288) else ""
                            file.writeText((old + entry).takeLast(16384))
                        }
                    }
                    result.success(null)
                }
                "report" -> {
                    val webView = if (Build.VERSION.SDK_INT >= 26) {
                        runCatching {
                            WebView.getCurrentWebViewPackage()?.let { "${it.packageName} ${it.versionName}" }
                        }.getOrNull() ?: "unknown"
                    } else "unknown"
                    worker.execute {
                        val report = runCatching { report(webView) }.getOrElse { "diagnostic_error=${it.javaClass.simpleName}" }
                        main.post { result.success(report) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(id: String) {
        worker.execute {
            leases[id] = "browsing"
            if (monitor == null) {
                lastAck = SystemClock.uptimeMillis()
                captured = false
                awaitingMain.set(false)
                monitor = worker.scheduleAtFixedRate({ tick() }, 1, 1, TimeUnit.SECONDS)
            }
        }
    }

    private fun tick() {
        if (leases.isEmpty()) return
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        if (state.importance != ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND) {
            lastAck = SystemClock.uptimeMillis()
            return
        }
        val elapsed = SystemClock.uptimeMillis() - lastAck
        if (awaitingMain.get() && elapsed >= 5000 && !captured) {
            captured = true
            val report = buildString {
                appendLine("timeMillis=${System.currentTimeMillis()} stage=$stage mainThreadBlockedMs=$elapsed")
                appendLine("${Build.MANUFACTURER} ${Build.MODEL} Android ${Build.VERSION.RELEASE} API ${Build.VERSION.SDK_INT}")
                appendLine("requestedComposition=texture-layer")
                appendLine("main thread:")
                Looper.getMainLooper().thread.stackTrace.take(100).forEach { appendLine("  at $it") }
            }
            runCatching { stallFile.writeText(report.take(32768)) }
        }
        if (awaitingMain.compareAndSet(false, true)) {
            main.post {
                lastAck = SystemClock.uptimeMillis()
                awaitingMain.set(false)
            }
        }
    }

    private fun report(webView: String): String = buildString {
        appendLine("${Build.MANUFACTURER} ${Build.MODEL} Android ${Build.VERSION.RELEASE} API ${Build.VERSION.SDK_INT}")
        appendLine("WebView=$webView")
        appendLine("requestedComposition=texture-layer")
        appendLine("activeBrowsers=$stage")
        val events = File(app.filesDir, "embedded-browser-events.txt")
        appendLine("\nRecent renderer events:")
        appendLine(if (events.isFile) events.readText().takeLast(16384) else "No renderer event recorded.")
        appendLine("\nLast UI-thread stall:")
        appendLine(if (stallFile.isFile) stallFile.readText().take(32768) else "No stall recorded (this does not rule out a raster/GPU stall).")
        if (Build.VERSION.SDK_INT >= 30) {
            val manager = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val exits = runCatching {
                manager.getHistoricalProcessExitReasons(app.packageName, 0, 10)
                    .filter { it.processName == app.packageName }.take(3)
            }.getOrElse {
                appendLine("systemExitReadError=${it.javaClass.simpleName}")
                emptyList()
            }
            appendLine("\nRecent process exits:")
            for (exit in exits) {
                appendLine("timeMillis=${exit.timestamp} process=${exit.processName} reason=${reason(exit.reason)} status=${exit.status}")
                if (exit.reason == ApplicationExitInfo.REASON_ANR) {
                    runCatching {
                        exit.traceInputStream?.bufferedReader()?.use { reader ->
                            val chars = CharArray(4096)
                            var remaining = 32768
                            while (remaining > 0) {
                                val count = reader.read(chars, 0, minOf(chars.size, remaining))
                                if (count < 0) break
                                append(chars, 0, count)
                                remaining -= count
                            }
                        }
                    }
                }
            }
        }
    }

    private fun reason(value: Int): String = when (value) {
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_CRASH -> "JAVA_CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "NATIVE_CRASH"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        else -> "OTHER($value)"
    }

    companion object {
        private const val CHANNEL = "com.example.video_player_app/douyin_browser_diagnostics"
        fun register(context: Context, messenger: BinaryMessenger) {
            EmbeddedBrowserDiagnostics(context, messenger)
        }
    }
}
