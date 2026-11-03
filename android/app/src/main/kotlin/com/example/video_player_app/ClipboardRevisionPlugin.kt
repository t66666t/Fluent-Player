package com.example.video_player_app

import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Metadata only; text is still read through Flutter's normal clipboard API. */
class ClipboardRevisionPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var clipboard: ClipboardManager? = null
    private val processScope = UUID.randomUUID().toString()
    private var revision = 0L
    private val listener = ClipboardManager.OnPrimaryClipChangedListener { revision++ }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val manager = binding.applicationContext
            .getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard = manager
        // API 24/25 have no copy timestamp. Events still distinguish recopies
        // while the engine is alive, without reading clipboard text in background.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            manager.addPrimaryClipChangedListener(listener)
        }
        channel = MethodChannel(binding.binaryMessenger,
            "com.example.video_player_app/clipboard_revision").also { value ->
            value.setMethodCallHandler { call, result ->
                if (call.method != "getRevision") {
                    result.notImplemented()
                } else {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val timestamp = manager.primaryClipDescription?.timestamp ?: 0L
                            result.success(if (timestamp > 0L) mapOf(
                                "token" to "android/copy/$timestamp",
                                "persistent" to true,
                            ) else null)
                        } else {
                            result.success(mapOf(
                                "token" to "android/process/$processScope/$revision",
                                "persistent" to false,
                            ))
                        }
                    } catch (_: SecurityException) {
                        result.success(null)
                    }
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            clipboard?.removePrimaryClipChangedListener(listener)
        }
        channel?.setMethodCallHandler(null)
        channel = null
        clipboard = null
    }
}
