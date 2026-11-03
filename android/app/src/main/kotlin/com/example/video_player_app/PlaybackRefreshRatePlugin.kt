package com.example.video_player_app

import android.app.Activity
import android.hardware.display.DisplayManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.view.View
import android.view.Surface
import android.view.SurfaceHolder
import android.view.ViewGroup
import io.flutter.embedding.android.FlutterView
import io.flutter.embedding.android.FlutterSurfaceView
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.IdentityHashMap
import kotlin.math.abs

/** A route-owned UI frame-rate preference. It never changes display settings,
 * video playback speed, resolution, or the decoder's own frame-rate hint. */
class PlaybackRefreshRatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private val owners = mutableSetOf<Int>()
    private var originalWindowRate: Float? = null
    private var requestedWindowRate: Float? = null
    private var originalModeId: Int? = null
    private var requestedModeId: Int? = null
    private val frameSurfaces = IdentityHashMap<SurfaceHolder, SurfaceHolder.Callback>()

    private fun voteSurface(holder: SurfaceHolder, rate: Float) {
        if (Build.VERSION.SDK_INT < 30 || !holder.surface.isValid) return
        try {
            if (Build.VERSION.SDK_INT >= 31) {
                holder.surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                    Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS)
            } else {
                holder.surface.setFrameRate(rate, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
            }
        } catch (_: IllegalStateException) {
            // Surface destruction may race a display/lifecycle callback.
        } catch (_: IllegalArgumentException) {
            // A vendor rejecting a hint must not interrupt playback.
        }
    }

    private fun trackSurface(view: FlutterSurfaceView, rate: Float) {
        if (Build.VERSION.SDK_INT < 30) return
        val holder = view.holder
        if (!frameSurfaces.containsKey(holder)) {
            val callback = object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) {
                    requestedWindowRate?.let { voteSurface(holder, it) }
                }
                override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                    requestedWindowRate?.let { voteSurface(holder, it) }
                }
                override fun surfaceDestroyed(holder: SurfaceHolder) {}
            }
            frameSurfaces[holder] = callback
            holder.addCallback(callback)
        }
        voteSurface(holder, rate)
    }

    private var displayManager: DisplayManager? = null
    private var requestedDisplayId: Int? = null
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = refreshDisplay()
        override fun onDisplayRemoved(displayId: Int) = refreshDisplay()
        override fun onDisplayChanged(displayId: Int) = refreshDisplay()
    }

    private fun refreshDisplay() {
        if (owners.isNotEmpty()) applyPreference()
    }

    private val originalViewRates = IdentityHashMap<View, Float>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger,
            "com.example.video_player_app/playback_refresh_rate")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "setActive") {
            result.notImplemented()
            return
        }
        val owner = call.argument<Int>("owner")
        val active = call.argument<Boolean>("active")
        if (owner == null || active == null) {
            result.error("invalid-owner", "owner and active are required", null)
            return
        }
        val wasActive = owners.isNotEmpty()
        if (active) owners.add(owner) else owners.remove(owner)
        if (!wasActive && owners.isNotEmpty()) applyPreference()
        if (wasActive && owners.isEmpty()) restorePreference()
        result.success(null)
    }

    @Suppress("DEPRECATION")
    private fun applyPreference() {
        val host = activity ?: return
        val display = if (Build.VERSION.SDK_INT >= 30) host.display
            else host.windowManager.defaultDisplay
        display ?: return
        val mode = display.mode
        // Select only rates at the current physical resolution. Let Android
        // choose the actual mode, including battery saver and OEM policies.
        val preferredMode = display.supportedModes.asSequence()
            .filter { it.physicalWidth == mode.physicalWidth &&
                it.physicalHeight == mode.physicalHeight }
            .filter { it.refreshRate.isFinite() && it.refreshRate > 0f }
            .maxByOrNull { it.refreshRate } ?: mode
        val rate = preferredMode.refreshRate
        if (requestedDisplayId == display.displayId &&
            requestedWindowRate?.let { abs(it - rate) < 0.01f } == true) return
        restorePreference()
        requestedDisplayId = display.displayId
        val params = host.window.attributes
        originalWindowRate = params.preferredRefreshRate
        requestedWindowRate = rate
        // Preserve an explicit mode/resolution selected by another owner.
        if (params.preferredDisplayModeId == 0) {
            // An explicit mode helps vendors which ignore a rate-only vote.
            // On API 31+, restrict it to the advertised seamless alternatives.
            val seamless = Build.VERSION.SDK_INT < 31 || mode.modeId == preferredMode.modeId ||
                mode.alternativeRefreshRates.any { abs(it - rate) < 0.1f }
            if (seamless) {
                originalModeId = params.preferredDisplayModeId
                requestedModeId = preferredMode.modeId
                params.preferredDisplayModeId = preferredMode.modeId
            }
            params.preferredRefreshRate = rate
            host.window.attributes = params
        }
        visitFrameViews(host.window.decorView, rate, true)
    }

    private fun visitFrameViews(view: View, rate: Float, root: Boolean = false) {
        if (view is FlutterSurfaceView) trackSurface(view, rate)
        // ViewGroup frame-rate votes do not propagate to their child views.
        // Vote on Flutter's output too; a video has its own separate cadence.
        if (Build.VERSION.SDK_INT >= 35 && (root || view is FlutterView || view is FlutterSurfaceView)) {
            if (!originalViewRates.containsKey(view)) originalViewRates[view] = view.requestedFrameRate
            // OEM HIGH categories can map to 90Hz on a 120Hz display. Vote
            // for the supported same-resolution rate already used by Window.
            view.requestedFrameRate = rate
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) visitFrameViews(view.getChildAt(index), rate)
        }
    }

    private fun restorePreference() {
        val host = activity
        val original = originalWindowRate
        val applied = requestedWindowRate
        if (host != null && original != null && applied != null) {
            val params = host.window.attributes
            if (requestedModeId != null && params.preferredDisplayModeId == requestedModeId) {
                params.preferredDisplayModeId = originalModeId ?: 0
                host.window.attributes = params
            }
            // Do not overwrite a newer preference installed by another page.
            if (abs(params.preferredRefreshRate - applied) < 0.01f) {
                params.preferredRefreshRate = original
                host.window.attributes = params
            }
        }
        if (Build.VERSION.SDK_INT >= 35) {
            for ((view, rate) in originalViewRates) {
                if (applied != null && abs(view.requestedFrameRate - applied) < 0.01f) {
                    view.requestedFrameRate = rate
                }
            }
        }
        for ((holder, callback) in frameSurfaces) {
            holder.removeCallback(callback)
            voteSurface(holder, 0f)
        }
        frameSurfaces.clear()
        originalViewRates.clear()
        originalWindowRate = null
        requestedWindowRate = null
        requestedDisplayId = null
        originalModeId = null
        requestedModeId = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        displayManager = binding.activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        displayManager?.registerDisplayListener(displayListener, Handler(Looper.getMainLooper()))
        // The engine can attach before Flutter's output view exists.
        binding.activity.window.decorView.post {
            val host = activity ?: return@post
            val rate = requestedWindowRate ?: return@post
            if (owners.isNotEmpty()) visitFrameViews(host.window.decorView, rate, true)
        }
        if (owners.isNotEmpty()) applyPreference()
    }

    override fun onDetachedFromActivityForConfigChanges() {
        restorePreference()
        displayManager?.unregisterDisplayListener(displayListener)
        displayManager = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        restorePreference()
        displayManager?.unregisterDisplayListener(displayListener)
        displayManager = null
        activity = null
    }

    fun resetOwners() {
        restorePreference()
        owners.clear()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        resetOwners()
        channel.setMethodCallHandler(null)
    }
}
