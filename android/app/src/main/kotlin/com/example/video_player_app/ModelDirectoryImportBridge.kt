package com.example.video_player_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.lang.ref.WeakReference
import java.util.WeakHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Read only catalog-declared files through the user's SAF tree grant. */
class ModelDirectoryImportBridge(private val activity: Activity, private val messenger: BinaryMessenger) {
    companion object {
        private const val CHANNEL = "com.example.video_player_app/model_directory_import"
        private const val REQUEST_CODE = 4117
        // Cached engines can outlive/rebind Activities. An old host may cancel
        // its own work, but must never unregister its replacement's channel.
        private val owners = WeakHashMap<BinaryMessenger, WeakReference<ModelDirectoryImportBridge>>()
    }

    private class Selection(val files: List<ModelImportFileRequest>, val result: MethodChannel.Result) {
        val cancelled = AtomicBoolean(false)
        val signal = CancellationSignal()
        val input = AtomicReference<InputStream?>(null)
        val stagedToken = AtomicReference<String?>(null)

        fun cancel() {
            cancelled.set(true)
            runCatching { signal.cancel() }
            runCatching { input.getAndSet(null)?.close() }
        }
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "model-directory-import").apply { isDaemon = true }
    }
    private var selection: Selection? = null
    private var closed = false

    init {
        owners[messenger]?.get()?.close()
        owners[messenger] = WeakReference(this)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "selectAndStage" -> {
                    if (closed || selection != null) {
                        result.error("MODEL_DIRECTORY_PICKER_ACTIVE", "模型目录选择已在进行中", null)
                    } else {
                        try {
                            val files = parseRequests(call.argument<List<Map<String, Any?>>>("files"))
                            ModelImportStaging.validateRequests(files)
                            selection = Selection(files, result)
                            activity.startActivityForResult(
                                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                                ),
                                REQUEST_CODE,
                            )
                        } catch (error: Exception) {
                            selection = null
                            result.error("MODEL_DIRECTORY_IMPORT_FAILED", error.message, null)
                        }
                    }
                }
                "cleanup" -> {
                    val token = call.argument<String>("token")
                    if (token == null || closed) {
                        result.error("INVALID_MODEL_IMPORT_TOKEN", "无效的模型导入临时目录", null)
                    } else {
                        val cache = activity.cacheDir
                        worker.execute {
                            val deleted = ModelImportStaging.cleanup(cache, token)
                            main.post {
                                if (deleted) result.success(null)
                                else result.error("MODEL_DIRECTORY_CLEANUP_FAILED", "无法清理模型导入临时文件", null)
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val pending = selection ?: return true
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || tree == null) {
            selection = null
            pending.result.success(null)
            return true
        }
        if (tree.scheme != "content" || !DocumentsContract.isTreeUri(tree)) {
            selection = null
            pending.result.error("MODEL_DIRECTORY_IMPORT_FAILED", "请选择系统提供的模型目录", null)
            return true
        }
        // The result's read grant stays valid while this Activity owns the
        // selection. Copy now; do not turn the tree into an ungranted raw path
        // or acquire/revoke any unrelated persistent grants.
        val cache = activity.cacheDir
        worker.execute {
            try {
                val staged = ModelImportStaging.stage(cache, pending.files, pending.cancelled::get) { path ->
                    findFile(tree, path, pending)
                }
                pending.stagedToken.set(staged.token)
                if (pending.cancelled.get()) {
                    ModelImportStaging.cleanup(cache, staged.token)
                    return@execute
                }
                main.post {
                    if (!closed && selection === pending && !pending.cancelled.get()) {
                        selection = null
                        pending.result.success(mapOf("directoryPath" to staged.directory.absolutePath, "token" to staged.token))
                    }
                }
            } catch (error: Exception) {
                main.post {
                    if (!closed && selection === pending) {
                        selection = null
                        pending.result.error("MODEL_DIRECTORY_IMPORT_FAILED", error.message ?: "无法读取所选模型目录", null)
                    }
                }
            }
        }
        return true
    }

    /** Called before the Activity/engine messenger is released. */
    fun close() {
        if (closed) return
        closed = true
        if (owners[messenger]?.get() === this) {
            channel.setMethodCallHandler(null)
            owners.remove(messenger)
        }
        selection?.let {
            it.cancel()
            it.stagedToken.get()?.let { token ->
                val cache = activity.cacheDir
                worker.execute { ModelImportStaging.cleanup(cache, token) }
            }
            it.result.error("MODEL_DIRECTORY_IMPORT_CANCELLED", "模型目录导入已取消，请重新选择", null)
        }
        selection = null
        // Existing work owns its UUID and will remove it on cancellation.
        // Do not interrupt cleanup or wait on a provider from Android's UI thread.
        worker.shutdown()
    }

    private fun parseRequests(files: List<Map<String, Any?>>?): List<ModelImportFileRequest> {
        val requested = files ?: throw IllegalArgumentException("缺少模型文件清单")
        require(requested.isNotEmpty() && requested.size <= 128) { "模型文件数量无效" }
        return requested.map { item ->
            val paths = (item["relativePaths"] as? List<*>)
                ?.map { it as? String ?: throw IllegalArgumentException("无效的模型相对路径") }
                ?: throw IllegalArgumentException("缺少模型相对路径")
            val bytes = item["expectedBytes"] as? Number ?: throw IllegalArgumentException("缺少模型文件大小")
            require(bytes is Int || bytes is Long) { "模型文件大小必须为整数" }
            ModelImportFileRequest(
                item["targetPath"] as? String ?: throw IllegalArgumentException("缺少模型目标文件名"),
                paths,
                bytes.toLong(),
            )
        }
    }

    private fun findFile(tree: Uri, relativePath: String, pending: Selection): ModelImportSource? {
        var documentId = DocumentsContract.getTreeDocumentId(tree)
        val parts = relativePath.split('/')
        var size: Long? = null
        for ((index, part) in parts.withIndex()) {
            if (pending.cancelled.get()) throw IOException("模型目录导入已取消")
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, documentId)
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
            )
            var matchingId: String? = null
            var matchingType: String? = null
            activity.contentResolver.query(children, projection, null, null, null, pending.signal)?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (pending.cancelled.get()) throw IOException("模型目录导入已取消")
                    if (cursor.getString(1) != part) continue
                    if (matchingId != null) throw IOException("模型目录含有重名文件：$relativePath")
                    matchingId = cursor.getString(0)
                    matchingType = cursor.getString(2)
                    size = if (cursor.isNull(3)) null else cursor.getLong(3)
                }
            }
            documentId = matchingId ?: return null
            val isDirectory = matchingType == DocumentsContract.Document.MIME_TYPE_DIR
            if (isDirectory != (index < parts.lastIndex)) return null
        }
        val document = DocumentsContract.buildDocumentUriUsingTree(tree, documentId)
        return ModelImportSource(size) {
            if (pending.cancelled.get()) throw IOException("模型目录导入已取消")
            val descriptor = activity.contentResolver.openAssetFileDescriptor(document, "r", pending.signal)
                ?: throw IOException("无法读取模型文件：$relativePath")
            val input = try {
                descriptor.createInputStream()
            } catch (error: Exception) {
                descriptor.close()
                throw error
            }
            pending.input.set(input)
            if (pending.cancelled.get()) {
                pending.input.compareAndSet(input, null)
                input.close()
                throw IOException("模型目录导入已取消")
            }
            object : FilterInputStream(input) {
                override fun close() {
                    pending.input.compareAndSet(input, null)
                    super.close()
                }
            }
        }
    }
}
