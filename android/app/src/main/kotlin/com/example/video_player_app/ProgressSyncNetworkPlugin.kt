package com.example.video_player_app

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import android.os.StatFs
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Receives local discovery packets while the sync UI/app is foreground. */
class ProgressSyncNetworkPlugin : FlutterPlugin, Application.ActivityLifecycleCallbacks {
    private var application: Application? = null
    private var channel: MethodChannel? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private val resumedActivities = mutableSetOf<Activity>()
    private var enabled = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val app = binding.applicationContext as Application
        application = app
        app.registerActivityLifecycleCallbacks(this)
        val wifi = app.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        multicastLock = wifi?.createMulticastLock("fluent_player_progress_sync")?.apply {
            setReferenceCounted(false)
        }
        channel = MethodChannel(
            binding.binaryMessenger,
            "com.example.video_player_app/progress_sync_network",
        ).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                if (call.method == "availableBytes") {
                    val available = try {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) null else StatFs(path).availableBytes.coerceAtLeast(0L)
                    } catch (_: Exception) {
                        null
                    }
                    result.success(available)
                    return@setMethodCallHandler
                }
                if (call.method != "setMulticastEnabled") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                enabled = call.argument<Boolean>("enabled") == true
                try {
                    updateLock()
                    result.success(null)
                } catch (error: SecurityException) {
                    result.error("MULTICAST_UNAVAILABLE", "Local discovery unavailable", null)
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        enabled = false
        resumedActivities.clear()
        releaseLock()
        channel?.setMethodCallHandler(null)
        channel = null
        application?.unregisterActivityLifecycleCallbacks(this)
        application = null
        multicastLock = null
    }

    private fun updateLock() {
        val lock = multicastLock ?: return
        if (enabled && resumedActivities.isNotEmpty()) {
            if (!lock.isHeld) lock.acquire()
        } else {
            releaseLock()
        }
    }

    private fun releaseLock() {
        val lock = multicastLock ?: return
        if (lock.isHeld) {
            try {
                lock.release()
            } catch (_: RuntimeException) {
                // The OS can already have released a lock during teardown.
            }
        }
    }

    override fun onActivityResumed(activity: Activity) {
        resumedActivities.add(activity)
        try {
            updateLock()
        } catch (_: SecurityException) {
            // Manual-address pairing remains available without multicast.
        }
    }

    override fun onActivityPaused(activity: Activity) {
        resumedActivities.remove(activity)
        if (resumedActivities.isEmpty()) releaseLock()
    }

    override fun onActivityDestroyed(activity: Activity) {
        resumedActivities.remove(activity)
        if (resumedActivities.isEmpty()) releaseLock()
    }

    override fun onActivityCreated(activity: Activity, state: Bundle?) = Unit
    override fun onActivityStarted(activity: Activity) = Unit
    override fun onActivityStopped(activity: Activity) = Unit
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) = Unit
}
