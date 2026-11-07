package com.example.video_player_app

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.system.Os
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import kotlin.concurrent.thread

/** Saves an existing compose output through the system document picker. */
class ComposeVideoSavePlugin : FlutterPlugin, ActivityAware,
    PluginRegistry.ActivityResultListener {
    companion object {
        private const val CHANNEL = "com.example.video_player_app/compose_video_save"
        private const val REQUEST_SAVE = 0x4E31
    }

    private data class Pending(val path: String, val result: MethodChannel.Result)

    private val main = Handler(Looper.getMainLooper())
    private lateinit var channel: MethodChannel
    private var binding: ActivityPluginBinding? = null
    private var pending: Pending? = null

    override fun onAttachedToEngine(engine: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(engine.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            if (call.method != "save") {
                result.notImplemented()
            } else {
                val path = call.argument<String>("path")
                val activity = binding?.activity
                when {
                    pending != null -> result.error("SAVE_BUSY", "已有保存操作正在进行", null)
                    path.isNullOrBlank() || path.contains('\u0000') || !File(path).isAbsolute ->
                        result.error("INVALID_PATH", "视频路径无效", null)
                    activity == null -> result.error("NO_ACTIVITY", "无法打开系统保存窗口", null)
                    !File(path).isFile -> result.error("SOURCE_MISSING", "合成视频不存在", null)
                    else -> {
                        val request = Pending(path, result)
                        pending = request
                        try {
                            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "video/mp4"
                                putExtra(Intent.EXTRA_TITLE, File(path).name)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            }
                            @Suppress("DEPRECATION")
                            activity.startActivityForResult(intent, REQUEST_SAVE)
                        } catch (error: Exception) {
                            finish(request, "PICKER_FAILED", error.message)
                        }
                    }
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_SAVE) return false
        val request = pending ?: return true
        if (resultCode == Activity.RESULT_CANCELED) {
            pending = null
            request.result.success(false)
            return true
        }
        val uri = data?.data
        val activity = binding?.activity
        if (resultCode != Activity.RESULT_OK || uri == null || activity == null) {
            finish(request, "PICKER_FAILED", "未能获取保存位置")
            return true
        }
        val resolver = activity.applicationContext.contentResolver
        thread(name = "compose-video-save") {
            try {
                FileInputStream(request.path).use { input ->
                    // A provider may return an existing document. Refuse to
                    // truncate the source if both descriptors identify it.
                    val source = Os.fstat(input.fd)
                    val target = resolver.openFileDescriptor(uri, "r")
                        ?: throw IOException("无法验证所选目标文件")
                    target.use {
                        val destination = Os.fstat(it.fileDescriptor)
                        if (source.st_dev == destination.st_dev && source.st_ino == destination.st_ino) {
                            throw IOException("保存位置与原视频相同，请选择其他位置")
                        }
                    }
                    val output = resolver.openOutputStream(uri, "wt")
                        ?: throw IOException("无法写入所选位置")
                    output.use { stream ->
                        input.copyTo(stream, 1024 * 1024)
                        stream.flush()
                    }
                }
                main.post { finish(request, null, null) }
            } catch (error: Exception) {
                // Do not delete the provider's document: it might have existed
                // before the selection. The original compose output is kept.
                main.post { finish(request, "SAVE_FAILED", error.message) }
            }
        }
        return true
    }

    private fun finish(request: Pending, code: String?, message: String?) {
        if (pending !== request) return
        pending = null
        if (code == null) request.result.success(true)
        else request.result.error(code, message, null)
    }

    override fun onAttachedToActivity(activityBinding: ActivityPluginBinding) {
        binding = activityBinding
        activityBinding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(activityBinding: ActivityPluginBinding) =
        onAttachedToActivity(activityBinding)

    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding = null
        pending?.let { finish(it, "ACTIVITY_DETACHED", "保存窗口已关闭，请重试") }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pending?.let { finish(it, "ENGINE_DETACHED", "保存操作已中断，请重试") }
        channel.setMethodCallHandler(null)
    }
}
