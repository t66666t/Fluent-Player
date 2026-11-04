package com.example.video_player_app

import android.annotation.SuppressLint
import android.app.usage.StorageStatsManager
import android.content.Context
import android.os.Build
import android.os.Process
import android.os.storage.StorageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec

/** Read-only statistics for this package, queried on an engine-owned worker. */
object AppStorageAuditBridge {
    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(
            messenger,
            "com.example.video_player_app/storage_audit",
            StandardMethodCodec.INSTANCE,
            messenger.makeBackgroundTaskQueue(),
        ).setMethodCallHandler(object : MethodChannel.MethodCallHandler {
            // This handler runs on the explicit engine-owned background task
            // queue above. Lint infers the default UI queue from the interface.
            @SuppressLint("WrongThread")
            override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
                if (call.method != "readUsage") {
                    result.notImplemented()
                    return
                }
                val values = mutableMapOf<String, Any>(
                    "privateRoot" to app.applicationInfo.dataDir,
                    "externalMediaRoots" to app.externalMediaDirs.filterNotNull().map { it.absolutePath },
                )
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    try {
                        val storage = app.getSystemService(StorageManager::class.java)
                        val manager = app.getSystemService(StorageStatsManager::class.java)
                        val volume = storage.getUuidForPath(app.filesDir)
                        // Querying this package needs no usage-access permission.
                        val stats = manager.queryStatsForPackage(volume, app.packageName, Process.myUserHandle())
                        values["appBytes"] = stats.appBytes
                        values["dataBytes"] = stats.dataBytes
                        // cacheBytes is a subset of dataBytes. Never add it twice.
                        values["cacheBytes"] = stats.cacheBytes
                        values["sampledAt"] = System.currentTimeMillis()
                    } catch (error: Exception) {
                        values["systemError"] = error.message ?: error.javaClass.simpleName
                    }
                }
                result.success(values)
            }
        })
    }
}
