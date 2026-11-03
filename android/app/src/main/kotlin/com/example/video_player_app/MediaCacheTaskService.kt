package com.example.video_player_app

import android.app.job.JobScheduler
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Holds a user-started transfer while the shared Flutter/audio engine runs.
 * A force-stop never starts a second engine or loses the durable Dart queue. */
object MediaCacheTaskBridge {
    const val JOB_ID = 3025
    const val NOTIFICATION_ID = 3025
    const val CHANNEL_ID = "fluent_media_cache"
    const val PAUSE = "com.example.video_player_app.MEDIA_CACHE_PAUSE"
    private var channel: MethodChannel? = null
    private var count = 0
    private var scheduled = false
    var job: MediaCacheJobService? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        val value = MethodChannel(messenger, "com.example.video_player_app/media_cache_tasks")
        channel = value
        value.setMethodCallHandler { call, result ->
            if (call.method != "setActive") { result.notImplemented(); return@setMethodCallHandler }
            val next = call.argument<Int>("count") ?: 0
            try {
                count = next
                if (next <= 0) {
                    scheduled = false
                    if (Build.VERSION.SDK_INT >= 34) {
                        job?.finishTransfer()
                        app.getSystemService(JobScheduler::class.java).cancel(JOB_ID)
                    }
                    app.stopService(Intent(app, MediaCacheTaskService::class.java))
                    app.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
                } else if (Build.VERSION.SDK_INT >= 34) {
                    if (!scheduled) {
                        val request = NetworkRequest.Builder()
                            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).build()
                        val info = JobInfo.Builder(JOB_ID, ComponentName(app, MediaCacheJobService::class.java))
                            .setUserInitiated(true).setRequiredNetwork(request).build()
                        val status = app.getSystemService(JobScheduler::class.java).schedule(info)
                        if (status != JobScheduler.RESULT_SUCCESS) throw IllegalStateException("System deferred background transfer")
                        scheduled = true
                    }
                    job?.updateNotification()
                } else {
                    ContextCompat.startForegroundService(app, Intent(app, MediaCacheTaskService::class.java))
                }
                result.success(null)
            } catch (error: Exception) {
                scheduled = false
                result.error("BACKGROUND_START", "系统暂时不允许后台缓存，断点已保留", null)
            }
        }
    }
    fun interrupted(manual: Boolean = false) {
        scheduled = false
        count = 0
        channel?.invokeMethod("interrupted", mapOf("manual" to manual))
    }
    fun canRun() = channel != null && count > 0
    fun notification(context: Context): Notification {
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            val channel = NotificationChannel(CHANNEL_ID, "媒体缓存", NotificationManager.IMPORTANCE_LOW)
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val open = launch?.let { PendingIntent.getActivity(context, 3025, it,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) }
        val pause = PendingIntent.getService(context, 3025,
            Intent(context, MediaCacheTaskService::class.java).setAction(PAUSE), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(context, CHANNEL_ID).setSmallIcon(R.mipmap.launcher_icon)
            .setContentTitle("Fluent Player · 媒体缓存").setContentText("$count 个任务正在进行")
            .setContentIntent(open).setSilent(true).setOngoing(true).setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(android.R.drawable.ic_media_pause, "暂停缓存", pause).build()
    }
}

class MediaCacheJobService : JobService() {
    private var parameters: JobParameters? = null
    override fun onStartJob(params: JobParameters): Boolean {
        // Restoration is performed when the real app engine is ready. A job
        // relaunched into a new process must not invent a headless media library.
        if (!MediaCacheTaskBridge.canRun()) return false
        parameters = params
        MediaCacheTaskBridge.job = this
        updateNotification()
        return true
    }
    fun updateNotification() {
        if (Build.VERSION.SDK_INT >= 34) parameters?.let {
            setNotification(it, MediaCacheTaskBridge.NOTIFICATION_ID,
                MediaCacheTaskBridge.notification(this), JOB_END_NOTIFICATION_POLICY_REMOVE)
        }
    }
    fun finishTransfer() {
        parameters?.let { jobFinished(it, false) }
        parameters = null
        MediaCacheTaskBridge.job = null
    }
    override fun onStopJob(params: JobParameters): Boolean {
        parameters = null
        MediaCacheTaskBridge.job = null
        MediaCacheTaskBridge.interrupted()
        return false
    }
}

class MediaCacheTaskService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == MediaCacheTaskBridge.PAUSE) {
            MediaCacheTaskBridge.interrupted(manual = true)
            MediaCacheTaskBridge.job?.finishTransfer()
            stopSelf()
            return START_NOT_STICKY
        }
        if (!MediaCacheTaskBridge.canRun()) { stopSelf(); return START_NOT_STICKY }
        val notification = MediaCacheTaskBridge.notification(this)
        if (Build.VERSION.SDK_INT >= 29) startForeground(MediaCacheTaskBridge.NOTIFICATION_ID,
            notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        else startForeground(MediaCacheTaskBridge.NOTIFICATION_ID, notification)
        if (wakeLock?.isHeld != true) {
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$packageName:media-cache")
                .also { it.acquire(6 * 60 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }
    override fun onTimeout(startId: Int, fgsType: Int) { MediaCacheTaskBridge.interrupted(); stopSelf() }
    override fun onDestroy() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        super.onDestroy()
    }
}
