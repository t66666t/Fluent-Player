package com.example.video_player_app

import android.app.NotificationChannel
import android.app.ActivityManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Does not start an empty Flutter engine or restart work after a force stop. */
class ModelTaskService : Service() {
    companion object {
        private const val CHANNEL = "fluent_model_tasks"
        private const val NOTIFICATION = 3024
        private const val PAUSE = "com.example.video_player_app.MODEL_TASK_PAUSE"
        var onInterrupted: (() -> Unit)? = null

        fun register(context: Context, messenger: BinaryMessenger) {
            val app = context.applicationContext
            val channel = MethodChannel(messenger, "com.example.video_player_app/model_tasks")
            onInterrupted = { channel.invokeMethod("interrupted", null) }
            channel.setMethodCallHandler { call, result ->
                if (call.method == "deviceInfo") {
                    val memory = ActivityManager.MemoryInfo()
                    (app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(memory)
                    result.success(mapOf("memoryBytes" to memory.totalMem, "availableMemoryBytes" to memory.availMem))
                    return@setMethodCallHandler
                }
                if (call.method != "setActive") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val downloads = call.argument<Int>("downloads") ?: 0
                val inference = call.argument<Int>("inference") ?: 0
                try {
                    val intent = Intent(app, ModelTaskService::class.java)
                        .putExtra("downloads", downloads).putExtra("inference", inference)
                    if (downloads + inference > 0) {
                        ContextCompat.startForegroundService(app, intent)
                    } else {
                        app.stopService(intent)
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error("BACKGROUND_START", error.message, null)
                }
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == PAUSE) {
            onInterrupted?.invoke()
            stopSelf()
            return START_NOT_STICKY
        }
        val downloads = intent?.getIntExtra("downloads", 0) ?: 0
        val inference = intent?.getIntExtra("inference", 0) ?: 0
        if (downloads + inference == 0) {
            stopSelf()
            return START_NOT_STICKY
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "模型下载与本地处理", NotificationManager.IMPORTANCE_LOW))
        }
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = if (launch == null) null else PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val pause = PendingIntent.getService(this, 0, Intent(this, ModelTaskService::class.java).setAction(PAUSE), PendingIntent.FLAG_IMMUTABLE)
        val text = buildList {
            if (downloads > 0) add("$downloads 个模型下载")
            if (inference > 0) add("正在进行本地字幕处理")
        }.joinToString(" · ")
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.launcher_icon).setContentTitle("Fluent Player 模型中心")
            .setContentText(text).setContentIntent(pending).setOngoing(true).setSilent(true)
            .addAction(android.R.drawable.ic_media_pause, "暂停任务", pause).build()
        if (Build.VERSION.SDK_INT >= 29) {
            var types = if (downloads > 0 || Build.VERSION.SDK_INT < 35) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0
            if (inference > 0 && Build.VERSION.SDK_INT >= 35) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROCESSING
            startForeground(NOTIFICATION, notification, types)
        } else {
            startForeground(NOTIFICATION, notification)
        }
        if (wakeLock?.isHeld != true) {
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:model-tasks")
                .also { it.acquire(6 * 60 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        onInterrupted?.invoke()
        stopSelf()
    }
    override fun onDestroy() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }
}
