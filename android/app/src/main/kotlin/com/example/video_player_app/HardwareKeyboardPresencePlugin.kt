package com.example.video_player_app

import android.content.Context
import android.hardware.input.InputManager
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Engine-owned so cached Activity recreation does not orphan device events. */
class HardwareKeyboardPresencePlugin : FlutterPlugin, InputManager.InputDeviceListener {
    private var inputManager: InputManager? = null
    private var channel: MethodChannel? = null
    private var lastConnected: Boolean? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        inputManager = binding.applicationContext.getSystemService(Context.INPUT_SERVICE) as InputManager
        channel = MethodChannel(binding.binaryMessenger, "com.example.video_player_app/keyboard_presence").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "isKeyboardConnected") {
                    val connected = isKeyboardConnected()
                    lastConnected = connected
                    result.success(connected)
                } else {
                    result.notImplemented()
                }
            }
        }
        inputManager?.registerInputDeviceListener(this, Handler(Looper.getMainLooper()))
        // A cached audio_service engine may already be running Dart before
        // the Activity installs this plugin. Recover an earlier missing query.
        publish()
    }

    private fun isKeyboardConnected(): Boolean {
        val manager = inputManager ?: return false
        return manager.inputDeviceIds.any { id ->
            val device = manager.getInputDevice(id)
            // A headset, remote, mouse or software keyboard must not enable
            // letter shortcuts. Include built-in/docked physical keyboards.
            device != null && !device.isVirtual && device.isEnabled &&
                device.keyboardType == InputDevice.KEYBOARD_TYPE_ALPHABETIC &&
                device.supportsSource(InputDevice.SOURCE_KEYBOARD)
        }
    }

    private fun publish() {
        val connected = isKeyboardConnected()
        if (lastConnected == connected) return
        lastConnected = connected
        channel?.invokeMethod("keyboardChanged", connected)
    }

    override fun onInputDeviceAdded(deviceId: Int) = publish()
    override fun onInputDeviceRemoved(deviceId: Int) = publish()
    override fun onInputDeviceChanged(deviceId: Int) = publish()

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        inputManager?.unregisterInputDeviceListener(this)
        inputManager = null
        channel?.setMethodCallHandler(null)
        channel = null
        lastConnected = null
    }
}
