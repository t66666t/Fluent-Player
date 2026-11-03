package com.example.video_player_app

import android.app.Activity
import android.content.Context
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * Hardware keyboards start CJK composition only while an input connection
 * exists. Drop that connection whenever no text field is editing so letter
 * shortcuts stay raw keys in both Chinese and English modes.
 */
object ImeShortcutGate {
    private const val CHANNEL = "com.example.video_player_app/ime_gate"

    var isTextInputActive: Boolean = false
        private set

    private var activityRef: WeakReference<Activity>? = null
    private var attachRetries = 0

    fun install(activity: Activity, engine: FlutterEngine) {
        attachHost(activity)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "setTextInputActive") {
                    setTextInputActive(call.arguments as? Boolean ?: false)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        setTextInputActive(false, force = true)
    }

    // AudioService's cached engine can outlive an Activity; rebind the weak
    // host without resetting the live Dart text-input state on recreation.
    fun attachHost(activity: Activity) {
        activityRef = WeakReference(activity)
        attachRetries = 0
    }

    fun onHostResume() {
        setTextInputActive(isTextInputActive, force = true)
    }

    fun hideIme(activity: Activity) {
        if (isTextInputActive) return
        val target = findFlutterView(activity.window?.decorView) ?: activity.window?.decorView
        val token = target?.windowToken ?: return
        val imm = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(token, 0)
    }

    private fun setTextInputActive(active: Boolean, force: Boolean = false) {
        val changed = isTextInputActive != active
        isTextInputActive = active
        if (active || (!changed && !force)) return
        val host = activityRef?.get() ?: return
        val decor = host.window?.decorView
        val target = findFlutterView(decor)
        if (target == null) {
            if (attachRetries < 8 && decor != null) {
                attachRetries += 1
                decor.post {
                    if (!isTextInputActive) {
                        setTextInputActive(false, force = true)
                    }
                }
            }
            return
        }
        attachRetries = 0
        val imm = host.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(target.windowToken, 0)
        imm.restartInput(target)
    }

    private fun findFlutterView(root: View?): View? {
        if (root == null) return null
        if (root.javaClass.name == "io.flutter.embedding.android.FlutterView") {
            return root
        }
        if (root is ViewGroup) {
            for (index in 0 until root.childCount) {
                findFlutterView(root.getChildAt(index))?.let { return it }
            }
        }
        return null
    }
}
