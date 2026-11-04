package com.example.video_player_app

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Retired channel only; no WebView, watchdog, account or browsing data access. */
internal object EmbeddedBrowserDiagnostics {
    fun register(@Suppress("UNUSED_PARAMETER") context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "com.example.video_player_app/douyin_browser_diagnostics")
            .setMethodCallHandler { _, result ->
                result.error("LOCAL_ONLY", "本地版已移除内置浏览器", null)
            }
    }
}
