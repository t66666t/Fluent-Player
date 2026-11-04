package com.example.video_player_app

import android.app.Activity
import android.annotation.SuppressLint
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ComponentName
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import androidx.core.content.IntentCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.webkit.MimeTypeMap
import android.view.KeyEvent
import android.view.MotionEvent
import java.io.File
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.Collections
import java.util.LinkedHashSet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.Locale
import java.util.UUID
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject
import com.ryanheise.audioservice.AudioServiceFragmentActivity

class MainActivity : AudioServiceFragmentActivity() {
    private enum class PickerMode {
        MEDIA,
        ARCHIVE,
        FLUENT_PACK,
        IMPORT_FILE,
    }

    private val YTDLP_BEFORE_DL_MARKER = "__YTDLP_BEFORE_DL__:"
    private val YTDLP_AFTER_MOVE_MARKER = "__YTDLP_AFTER_MOVE__:"
    private val CHANNEL = "com.example.video_player_app/file_manager"
    private val OPEN_WITH_CHANNEL = "com.example.video_player_app/open_with"
    private val SHARE_CHANNEL = "com.example.video_player_app/share_intent"
    private val SHARE_EVENT_CHANNEL = "com.example.video_player_app/share_intent_events"
    private val YT_DLP_CHANNEL = "com.example.video_player_app/yt_dlp"
    private val YT_DLP_EVENT_CHANNEL = "com.example.video_player_app/yt_dlp_events"
    private val HARDWARE_INPUT_CHANNEL = "com.example.video_player_app/hardware_input"
    private val REQUEST_CODE_PICK_FILES = 4101
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPickerMode: PickerMode? = null
    private var pendingIncludeSourceHints = false
    private var pendingFilterMediaExtensions = true
    private var ytDlpEventSink: EventChannel.EventSink? = null
    private var hardwareInputChannel: MethodChannel? = null
    private var modelDirectoryImportBridge: ModelDirectoryImportBridge? = null
    private val mediaExtensions = setOf(
        ".mp4", ".mov", ".avi", ".mkv", ".flv", ".webm", ".wmv", ".3gp", ".m4v", ".ts",
        ".rmvb", ".mpg", ".mpeg", ".f4v", ".m2ts", ".mts", ".vob", ".ogv", ".divx",
        ".mp3", ".m4a", ".wav", ".flac", ".ogg", ".aac", ".wma", ".opus", ".m4b", ".aiff"
    )
    private val archiveExtensions = setOf(
        ".zip",
        ".tar",
        ".tgz",
        ".tar.gz",
        ".tbz",
        ".tbz2",
        ".tar.bz2",
        ".txz",
        ".tar.xz",
    )
    private val ytDlpTasks = ConcurrentHashMap<String, RunningYtDlpTask>()
    private val ytDlpWorker by lazy {
        YtDlpWorkerConnection(
            this,
            onStarted = { taskId ->
                ytDlpTasks[taskId]?.let { task ->
                    if (task.terminationReason == null) {
                        task.status = "downloading"
                        emitTaskEvent(taskId = taskId, type = "task_started", message = "Starting download")
                    }
                }
            },
            onEvent = ::handleYtDlpWorkerEvent,
        )
    }
    private var ytDlpWorkerReceiverRegistered = false
    private val ytDlpWorkerReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent != null) handleYtDlpWorkerEvent(intent)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerYtDlpWorkerReceiver()
        // Cached Flutter engines skip configureFlutterEngine on the next
        // Activity. Still consume a VIEW/SEND that launched this instance.
        enqueueSharedItemsFromIntent(intent)
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installHardwareKeyboardPresence(flutterEngine)
        if (!flutterEngine.plugins.has(ClipboardRevisionPlugin::class.java)) {
            flutterEngine.plugins.add(ClipboardRevisionPlugin())
        }
        if (!flutterEngine.plugins.has(PlaybackRefreshRatePlugin::class.java)) {
            val refreshRatePlugin = PlaybackRefreshRatePlugin()
            flutterEngine.plugins.add(refreshRatePlugin)
            flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() { refreshRatePlugin.resetOwners() }
                override fun onEngineWillDestroy() { refreshRatePlugin.resetOwners() }
            })
        }
        val asrAccelerationBridge = AsrAccelerationBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        val qwenAsrBridge = QwenAsrBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        val cohereAsrBridge = QwenAsrBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger,
            "cohere_asr", CohereAsrService::class.java, "Cohere")
        val parakeetJapaneseBridge = QwenAsrBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger,
            "parakeet_ja", ParakeetJapaneseService::class.java, "Parakeet")
        val ocrAccelerationBridge = OcrAccelerationBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        val translationAccelerationBridge = TranslationAccelerationBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() { asrAccelerationBridge.close(); qwenAsrBridge.closeAll(); cohereAsrBridge.closeAll(); parakeetJapaneseBridge.closeAll(); ocrAccelerationBridge.close(); translationAccelerationBridge.close() }
            override fun onEngineWillDestroy() { asrAccelerationBridge.close(); qwenAsrBridge.closeAll(); cohereAsrBridge.closeAll(); parakeetJapaneseBridge.closeAll(); ocrAccelerationBridge.close(); translationAccelerationBridge.close() }
        })
        flutterEngine.plugins.add(ProgressSyncNetworkPlugin())
        AppStorageAuditBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        installModelDirectoryImportBridge(flutterEngine)
        ModelTaskService.register(this, flutterEngine.dartExecutor.binaryMessenger)
        MediaCacheTaskBridge.register(this, flutterEngine.dartExecutor.binaryMessenger)
        ModelResourceBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        EmbeddedBrowserDiagnostics.register(this, flutterEngine.dartExecutor.binaryMessenger)
        ImeShortcutGate.install(this, flutterEngine)
        hardwareInputChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            HARDWARE_INPUT_CHANNEL,
        )
        MediaNotificationGate.register(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openFileManager" -> {
                    openFileManager()
                    result.success(null)
                }
                "pickFiles" -> {
                    if (pendingResult != null) {
                        result.error("PICKER_ACTIVE", "File picker is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingPickerMode = PickerMode.MEDIA
                    pendingIncludeSourceHints = call.argument<Boolean>("includeSourceHints") ?: false
                    pendingFilterMediaExtensions = call.argument<Boolean>("filterMediaExtensions") ?: true
                    val mimeTypes = call.argument<List<String>>("mimeTypes") ?: listOf("video/*", "audio/*")
                    val allowMultiple = call.argument<Boolean>("allowMultiple") ?: true
                    openSystemFilePicker(mimeTypes, allowMultiple)
                }
                "pickArchive" -> {
                    if (pendingResult != null) {
                        result.error("PICKER_ACTIVE", "File picker is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingPickerMode = PickerMode.ARCHIVE
                    openSystemFilePicker(listOf("*/*"), false)
                }
                "pickFluentPack" -> {
                    if (pendingResult != null) {
                        result.error("PICKER_ACTIVE", "File picker is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingPickerMode = PickerMode.FLUENT_PACK
                    // DocumentsUI filters by MIME rather than a private file
                    // extension. Packages shared by this app use application/zip;
                    // octet-stream keeps packages copied over USB/cloud visible.
                    openSystemFilePicker(
                        listOf(
                            "application/x-fluent-player-package",
                            "application/zip",
                            "application/octet-stream",
                        ),
                        false,
                    )
                }
                "pickImportFile" -> {
                    if (pendingResult != null) {
                        result.error("PICKER_ACTIVE", "File picker is already active", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingPickerMode = PickerMode.IMPORT_FILE
                    openSystemFilePicker(listOf("*/*"), false)
                }
                "materializeArchiveForImport" -> {
                    val uriString = call.argument<String>("uri")
                    val displayName = call.argument<String>("displayName")
                    if (uriString.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "missing uri", null)
                    } else {
                        // ContentResolver streams can point at multi-gigabyte files. Copying
                        // them in a MethodChannel callback blocks Android's main thread and
                        // can trigger an ANR. Keep all file I/O on a worker thread and only
                        // marshal the result back to Flutter on the UI thread.
                        thread(name = "archive-materialize") {
                            try {
                                val materializedPath = materializeArchiveForImport(
                                    uriString,
                                    displayName,
                                )
                                runOnUiThread {
                                    result.success(materializedPath)
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "ARCHIVE_MATERIALIZE_FAILED",
                                        e.message ?: "archive materialize failed",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                "materializeFluentPackForImport" -> {
                    val uriString = call.argument<String>("uri")
                    val displayName = call.argument<String>("displayName")
                    if (uriString.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "missing uri", null)
                    } else {
                        thread(name = "fluentpack-materialize") {
                            try {
                                val materializedPath = materializeFluentPackForImport(
                                    uriString,
                                    displayName,
                                )
                                runOnUiThread { result.success(materializedPath) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "FLUENTPACK_MATERIALIZE_FAILED",
                                        e.message ?: "fluentpack materialize failed",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            OPEN_WITH_CHANNEL,
        ).setMethodCallHandler { call, result ->
            if (call.method != "openFile" && call.method != "shareFile") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) {
                result.error("INVALID_ARGS", "missing path", null)
                return@setMethodCallHandler
            }
            if (call.method == "shareFile") {
                shareSourceMediaFile(path, call.argument<String>("mimeType"), result)
                return@setMethodCallHandler
            }
            try {
                result.success(openWithOtherApps(path))
            } catch (e: ActivityNotFoundException) {
                result.success(false)
            } catch (e: Exception) {
                result.error("OPEN_FAILED", e.message ?: "open failed", null)
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedMedia" -> {
                    result.success(ShareIntentDelivery.takePending())
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    ShareIntentDelivery.setSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    // onCancel has no EventSink parameter; null clears the
                    // current sink so a later Activity cannot keep a dead stream.
                    ShareIntentDelivery.clearSink(null)
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YT_DLP_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getYtDlpBinaryStatus" -> {
                    thread(name = "yt-dlp-binary-status", start = true) {
                        val status = getYtDlpBinaryStatus()
                        runOnUiThread { result.success(status) }
                    }
                }
                "reloadYtDlpRuntime" -> {
                    val archivePath = call.argument<String>("archivePath")
                    if (archivePath.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "missing yt-dlp archive path", null)
                    } else {
                        thread(name = "yt-dlp-runtime-reload", start = true) {
                            try {
                                val version = reloadYtDlpRuntime(archivePath)
                                runOnUiThread { result.success(version) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "YT_DLP_RUNTIME_INVALID",
                                        e.message ?: "invalid yt-dlp runtime archive",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                "importYoutubeCookies" -> {
                    val filePath = call.argument<String>("filePath")
                    if (filePath.isNullOrEmpty()) {
                        result.success(null)
                    } else {
                        result.success(importYoutubeCookies(filePath))
                    }
                }
                "saveYoutubeSessionConfig" -> {
                    val config = call.argument<Any?>("config")
                    saveYoutubeSessionConfig(config)
                    result.success(true)
                }
                "loadYoutubeSessionConfig" -> {
                    result.success(loadYoutubeSessionConfig())
                }
                "resolveYoutubeMeta" -> {
                    val url = call.argument<String>("url")
                    val sessionConfig = call.argument<Map<String, Any?>>("sessionConfig")
                    if (url.isNullOrBlank()) {
                        result.error("INVALID_ARGS", "missing url", null)
                    } else {
                        thread(name = "yt-dlp-resolve", start = true) {
                            try {
                                val payload = resolveYoutubeMeta(url, sessionConfig)
                                runOnUiThread {
                                    result.success(payload)
                                }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "YT_DLP_RESOLVE_FAILED",
                                        e.message ?: "yt-dlp resolve failed",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                "startYoutubeDownload" -> {
                    val request = call.arguments as? Map<String, Any?>
                    if (request == null) {
                        result.error("INVALID_ARGS", "missing request payload", null)
                    } else {
                        try {
                            result.success(startYoutubeDownload(request))
                        } catch (e: Exception) {
                            result.error(
                                "YT_DLP_START_FAILED",
                                e.message ?: "yt-dlp download start failed",
                                null,
                            )
                        }
                    }
                }
                "pauseYoutubeDownload" -> {
                    val taskId = call.argument<String>("taskId")
                    val accepted = !taskId.isNullOrBlank() && pauseYoutubeDownload(taskId)
                    result.success(
                        mapOf(
                            "accepted" to accepted,
                            "stopped" to false,
                            "reason" to if (accepted) null else "running task not found",
                        ),
                    )
                }
                "cancelYoutubeDownload" -> {
                    val taskId = call.argument<String>("taskId")
                    result.success(if (taskId.isNullOrBlank()) false else cancelYoutubeDownload(taskId))
                }
                "removeYoutubeTask" -> {
                    val taskId = call.argument<String>("taskId")
                    result.success(if (taskId.isNullOrBlank()) false else removeYoutubeTask(taskId))
                }
                "getYoutubeTaskStatus" -> {
                    val taskId = call.argument<String>("taskId")
                    result.success(if (taskId.isNullOrBlank()) null else getYoutubeTaskStatus(taskId))
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, YT_DLP_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    ytDlpEventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    ytDlpEventSink = null
                }
            }
        )

        enqueueSharedItemsFromIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        ImeShortcutGate.onHostResume()
    }

    override fun onPostResume() {
        super.onPostResume()
        if (!isFinishing && !isDestroyed) {
            // FragmentActivity commits its FlutterFragment asynchronously in
            // onCreate; its delegate getter is unsafe until attachment. Bind
            // here using audio_service's existing engine provider instead of
            // dereferencing the Fragment's delegate, including cached engines.
            provideFlutterEngine(this)?.let {
                installHardwareKeyboardPresence(it)
                installModelDirectoryImportBridge(it)
                ImeShortcutGate.attachHost(this)
            }
        }
    }

    // androidx.core's ancestor class has a library-group restriction; this is
    // Android's public Activity callback, not its restricted superDispatchKeyEvent.
    @SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (!ImeShortcutGate.isTextInputActive &&
            event.action == KeyEvent.ACTION_DOWN &&
            event.keyCode != KeyEvent.KEYCODE_BACK &&
            event.keyCode != KeyEvent.KEYCODE_ESCAPE
        ) {
            ImeShortcutGate.hideIme(this)
        }
        // The Xiaomi keyboard and some Android desktop modes can deliver keys
        // to the Activity without Flutter's current FocusNode seeing them.
        // Forward all ordinary down/up events as a fallback while leaving
        // Back/Escape entirely under Android's navigation handling.
        if (
            (event.action == KeyEvent.ACTION_DOWN || event.action == KeyEvent.ACTION_UP) &&
            event.keyCode != KeyEvent.KEYCODE_BACK &&
            event.keyCode != KeyEvent.KEYCODE_ESCAPE
        ) {
            hardwareInputChannel?.invokeMethod(
                "keyEvent",
                mapOf(
                    "keyCode" to event.keyCode,
                    "scanCode" to event.scanCode,
                    "unicodeChar" to event.getUnicodeChar(event.metaState),
                    "characters" to event.characters,
                    "action" to event.action,
                    "repeatCount" to event.repeatCount,
                    "eventTime" to event.eventTime,
                    "ctrl" to event.isCtrlPressed,
                    "alt" to event.isAltPressed,
                    "meta" to event.isMetaPressed,
                    "shift" to event.isShiftPressed,
                ),
            )
        }
        return super.dispatchKeyEvent(event)
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        // Flutter normally receives Android mouse hover directly. Re-send
        // Activity-level hover as a fallback for vendor touchpads/desktop mode;
        // Dart gives it a separate pointer id and feeds the normal MouseRegion
        // pipeline, so button Tooltips work without custom per-button code.
        when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER,
            MotionEvent.ACTION_HOVER_MOVE,
            MotionEvent.ACTION_HOVER_EXIT -> {
                val density = resources.displayMetrics.density.coerceAtLeast(1f)
                hardwareInputChannel?.invokeMethod(
                    "pointerHover",
                    mapOf(
                        "action" to event.actionMasked,
                        "x" to event.x / density,
                        "y" to event.y / density,
                        "eventTime" to event.eventTime,
                        "deviceId" to event.deviceId,
                    ),
                )
            }
        }
        return super.dispatchGenericMotionEvent(event)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (modelDirectoryImportBridge?.onActivityResult(requestCode, resultCode, data) == true) return
        if (requestCode != REQUEST_CODE_PICK_FILES) return
        val result = pendingResult
        pendingResult = null
        val pickerMode = pendingPickerMode
        pendingPickerMode = null
        val includeSourceHints = pendingIncludeSourceHints
        pendingIncludeSourceHints = false
        val filterMediaExtensions = pendingFilterMediaExtensions
        pendingFilterMediaExtensions = true
        if (result == null) return
        if (resultCode != Activity.RESULT_OK || data == null) {
            when (pickerMode) {
                PickerMode.ARCHIVE, PickerMode.FLUENT_PACK, PickerMode.IMPORT_FILE -> result.success(null)
                else -> result.success(emptyList<String>())
            }
            return
        }
        val uris = mutableListOf<Uri>()
        val clipData = data.clipData
        if (clipData != null) {
            for (i in 0 until clipData.itemCount) {
                uris.add(clipData.getItemAt(i).uri)
            }
        } else {
            data.data?.let { uris.add(it) }
        }
        when (pickerMode) {
            PickerMode.ARCHIVE -> {
                val firstUri = uris.firstOrNull()
                if (firstUri == null) {
                    result.success(null)
                    return
                }
                try {
                    persistGrantedUriAccess(firstUri, data.flags)
                } catch (_: Exception) {
                }
                try {
                    result.success(buildArchiveSelectionPayload(firstUri))
                } catch (error: Exception) {
                    result.error("INVALID_ARCHIVE_SELECTION", error.message ?: "请选择受支持的压缩包", null)
                }
            }
            PickerMode.FLUENT_PACK -> {
                val firstUri = uris.firstOrNull()
                if (firstUri == null) {
                    result.success(null)
                    return
                }
                try {
                    persistGrantedUriAccess(firstUri, data.flags)
                } catch (_: Exception) {
                }
                try {
                    result.success(buildFluentPackSelectionPayload(firstUri))
                } catch (e: Exception) {
                    result.error(
                        "INVALID_FLUENTPACK_SELECTION",
                        e.message ?: "请选择 .fluentpack 文件",
                        null,
                    )
                }
            }
            PickerMode.IMPORT_FILE -> {
                val firstUri = uris.firstOrNull()
                if (firstUri == null) {
                    result.success(null)
                    return
                }
                try {
                    persistGrantedUriAccess(firstUri, data.flags)
                } catch (_: Exception) {
                }
                try {
                    result.success(buildImportFileSelectionPayload(firstUri))
                } catch (e: Exception) {
                    result.error(
                        "INVALID_IMPORT_SELECTION",
                        e.message ?: "请选择 .fluentpack 或压缩包",
                        null,
                    )
                }
            }
            else -> {
                // Materialize content grants regardless of broad raw-path
                // readability. Only an opt-in per-selection payload carries
                // trusted sidecar hints; legacy callers still receive paths.
                ShareIntentDelivery.executor.execute {
                    try {
                        val payload = MediaImportFiles.resolveSelectionPayload(uris.distinct(), includeSourceHints) { uri ->
                            try {
                                persistGrantedUriAccess(uri, data.flags)
                            } catch (_: Exception) {
                                // A temporary read grant is sufficient to copy.
                            }
                            resolveMediaUriForImport(uri, null, filterMediaExtensions)
                        }
                        runOnUiThread { result.success(payload) }
                    } catch (error: Exception) {
                        runOnUiThread {
                            result.error("MEDIA_IMPORT_FAILED", error.message ?: "无法读取所选媒体", null)
                        }
                    }
                }
            }
        }
    }

    private fun persistGrantedUriAccess(uri: Uri, flags: Int) {
        // Preserve only the read/write grants actually returned by the picker.
        // Spell out the supported constants for Android's @IntDef contract.
        when (flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
            Intent.FLAG_GRANT_READ_URI_PERMISSION -> contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION,
            )
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION -> contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) ->
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        enqueueSharedItemsFromIntent(intent)
    }

    override fun onDestroy() {
        modelDirectoryImportBridge?.close()
        modelDirectoryImportBridge = null
        hardwareInputChannel = null
        ytDlpWorker.close()
        ytDlpTasks.clear()
        if (ytDlpWorkerReceiverRegistered) {
            runCatching { unregisterReceiver(ytDlpWorkerReceiver) }
            ytDlpWorkerReceiverRegistered = false
        }
        super.onDestroy()
    }

    private fun installHardwareKeyboardPresence(engine: FlutterEngine) {
        if (!engine.plugins.has(HardwareKeyboardPresencePlugin::class.java)) {
            engine.plugins.add(HardwareKeyboardPresencePlugin())
        }
    }

    private fun installModelDirectoryImportBridge(engine: FlutterEngine) {
        if (modelDirectoryImportBridge == null) {
            modelDirectoryImportBridge = ModelDirectoryImportBridge(this, engine.dartExecutor.binaryMessenger)
        }
    }

    /**
     * Resolving a shared content URI may query a remote provider or copy a
     * multi-gigabyte media file into the app cache. Doing that from
     * configureFlutterEngine/onNewIntent blocks Android's main thread and
     * delays Flutter's first frame. Resolve serially in the background, then
     * preserve the existing pending-item/event-channel delivery semantics.
     */
    private fun enqueueSharedItemsFromIntent(sourceIntent: Intent?) {
        if (sourceIntent == null) return
        val action = sourceIntent.action
        if (
            action != Intent.ACTION_SEND &&
            action != Intent.ACTION_SEND_MULTIPLE &&
            action != Intent.ACTION_VIEW
        ) return

        val snapshot = Intent(sourceIntent)
        // Consume the VIEW/SEND intent immediately so a later Activity
        // recreate cannot re-deliver the same share after the dialog was
        // already shown. The snapshot still has the original extras.
        consumeDeliveredShareIntent(sourceIntent)
        ShareIntentDelivery.executor.execute {
            val sharedItems = extractSharedItemsFromIntent(snapshot)
            if (sharedItems.isEmpty()) return@execute
            runOnUiThread {
                ShareIntentDelivery.deliver(sharedItems)
            }
        }
    }

    private fun consumeDeliveredShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (
            action != Intent.ACTION_SEND &&
            action != Intent.ACTION_SEND_MULTIPLE &&
            action != Intent.ACTION_VIEW
        ) return
        setIntent(Intent(this, MainActivity::class.java).apply {
            this.action = Intent.ACTION_MAIN
            addCategory(Intent.CATEGORY_LAUNCHER)
        })
    }

    private fun registerYtDlpWorkerReceiver() {}

    private fun sendYtDlpWorkerCommand(action: String, taskId: String): Boolean = false

    private fun handleYtDlpWorkerEvent(intent: Intent) {}

    private fun finishYtDlpWorkerDownload(
        task: RunningYtDlpTask,
        downloadResult: Map<String, Any?>,
    ) {}

    private fun openSystemFilePicker(mimeTypes: List<String>, allowMultiple: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
        intent.addCategory(Intent.CATEGORY_OPENABLE)
        intent.type = "*/*"
        intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, allowMultiple)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        intent.addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        startActivityForResult(intent, REQUEST_CODE_PICK_FILES)
    }

    /// Shows the system "open with" sheet for [path] without reading the file.
    ///
    /// createChooser grants the content URI only to the chooser, then to the
    /// app the user picks. A direct ACTION_VIEW with `*/*` (what a folder
    /// path becomes) grants every installed app first, so the sheet stalls.
    /// The video/audio MIME keeps the candidate list small. The file is not
    /// copied: FileProvider only mints a URI for the path that already exists.
    private fun openWithOtherApps(path: String): Boolean {
        val file = File(path)
        if (!file.isFile) return false
        val uri = contentUriForOpen(file)
        val mime = mimeTypeForOpen(file)
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("output", uri)
        }
        val chooser = Intent.createChooser(view, "用其他应用打开").apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            clipData = ClipData.newRawUri("output", uri)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            chooser.putExtra(
                Intent.EXTRA_EXCLUDE_COMPONENTS,
                arrayOf(ComponentName(this, MainActivity::class.java)),
            )
        }
        startActivity(chooser)
        return true
    }

    private fun contentUriForOpen(file: File): Uri {
        val authorities = listOf(
            "$packageName.fileProvider.com.crazecoder.openfile",
            "$packageName.fileprovider",
        )
        var failure: IllegalArgumentException? = null
        for (authority in authorities) {
            try {
                return FileProvider.getUriForFile(this, authority, file)
            } catch (error: IllegalArgumentException) {
                failure = error
            }
        }
        throw failure ?: IllegalArgumentException("unable to share ${file.absolutePath}")
    }

    /// Mint a read-only URI for the original file. FileProvider also handles
    /// app_flutter / private files through the existing open_filex provider.
    /// Only metadata is checked on the worker; no media bytes are copied/read.
    private fun shareSourceMediaFile(
        path: String,
        requestedMime: String?,
        result: MethodChannel.Result,
    ) {
        val fallbackMime = if (requestedMime == "audio/*") "audio/*" else "video/*"
        thread(name = "source-media-share") {
            try {
                require(!path.contains('\u0000')) { "invalid path" }
                val uri: Uri
                val mime: String
                if (path.startsWith("content://", ignoreCase = true)) {
                    uri = Uri.parse(path).normalizeScheme()
                    require(!uri.authority.isNullOrEmpty()) { "invalid content URI" }
                    // Opening a descriptor checks the retained provider grant;
                    // it does not stream the file or make a staging copy.
                    contentResolver.openAssetFileDescriptor(uri, "r")?.use { }
                        ?: throw java.io.FileNotFoundException()
                    mime = contentResolver.getType(uri) ?: fallbackMime
                } else {
                    val file = File(path)
                    require(file.isAbsolute) { "expected absolute source path" }
                    if (!file.isFile) throw java.io.FileNotFoundException()
                    if (!file.canRead()) throw SecurityException("source is not readable")
                    uri = contentUriForOpen(file)
                    mime = MimeTypeMap.getSingleton()
                        .getMimeTypeFromExtension(file.extension.lowercase(Locale.US))
                        ?: fallbackMime
                }
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newRawUri("source media", uri)
                }
                val chooser = Intent.createChooser(send, "分享源媒体文件").apply {
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    clipData = ClipData.newRawUri("source media", uri)
                    putExtra(
                        Intent.EXTRA_EXCLUDE_COMPONENTS,
                        arrayOf(ComponentName(this@MainActivity, MainActivity::class.java)),
                    )
                }
                runOnUiThread {
                    try {
                        if (isFinishing || isDestroyed) {
                            result.success(false)
                        } else {
                            startActivity(chooser)
                            // Complete when the chooser opens, not when another
                            // app finishes reading a multi-gigabyte media file.
                            result.success(true)
                        }
                    } catch (error: Exception) {
                        result.error("SHARE_FAILED", error.message, null)
                    }
                }
            } catch (error: Exception) {
                val code = when (error) {
                    is java.io.FileNotFoundException -> "SOURCE_MISSING"
                    is SecurityException -> "SOURCE_PERMISSION_DENIED"
                    else -> "SHARE_FAILED"
                }
                runOnUiThread { result.error(code, error.message, null) }
            }
        }
    }

    private fun mimeTypeForOpen(file: File): String {
        val extension = file.extension.lowercase(Locale.US)
        if (extension.isEmpty()) return "video/*"
        val mapped = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
        if (!mapped.isNullOrEmpty()) return mapped
        return "video/*"
    }

    private fun openFileManager() {
        try {
            // Try to open the specific path if possible, but Android 11+ is strict.
            // We try to open the system file manager (DocumentsUI).
            val uri = Uri.parse("content://com.android.externalstorage.documents/root/primary%3AAndroid%2Fdata%2Ftv.danmaku.bili%2Fdownload")
            val intent = Intent(Intent.ACTION_VIEW)
            intent.setDataAndType(uri, "vnd.android.document/directory")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        } catch (e: Exception) {
            try {
                // Fallback: Open standard download folder or root
                val intent = Intent(Intent.ACTION_VIEW)
                intent.setDataAndType(Uri.parse(Environment.getExternalStorageDirectory().path), "*/*")
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
            } catch (e2: Exception) {
                // Fallback 2: Open settings? Or just give up gracefully
            }
        }
    }

    private fun extractSharedItemsFromIntent(intent: Intent?): List<Map<String, Any?>> {
        if (intent == null) return emptyList()
        val action = intent.action ?: return emptyList()
        val collectedUris = mutableListOf<Uri>()
        when (action) {
            Intent.ACTION_SEND -> {
                val stream = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                if (stream != null) {
                    collectedUris.add(stream)
                } else {
                    intent.data?.let { collectedUris.add(it) }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val streams = IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                if (streams != null) {
                    collectedUris.addAll(streams.filterNotNull())
                }
            }
            Intent.ACTION_VIEW -> {
                intent.data?.let { collectedUris.add(it) }
            }
            else -> return emptyList()
        }
        val typeHint = intent.type
        val items = mutableListOf<Map<String, Any?>>()
        for (uri in collectedUris) {
            val item = resolveSharedImportItem(uri, typeHint)
            if (item != null) {
                items.add(item)
            }
        }
        return items
    }

    private fun resolveSharedImportItem(uri: Uri, typeHint: String?): Map<String, Any?>? {
        return try {
            // FluentPack is a ZIP container; filename / custom MIME must win
            // before the generic archive heuristic, or Open-With/Share would
            // dump it into the structured-archive importer.
            if (isLikelyFluentPack(uri, typeHint)) {
                val payload = buildFluentPackSelectionPayload(uri).toMutableMap()
                payload["kind"] = "fluentpack"
                payload
            } else if (isLikelyArchive(uri, typeHint)) {
                val payload = buildArchiveSelectionPayload(uri).toMutableMap()
                payload["kind"] = "archive"
                payload
            } else {
                val selected = resolveMediaUriForImport(uri, typeHint)
                if (selected == null) {
                    null
                } else {
                    mutableMapOf<String, Any?>(
                        "kind" to "media",
                        "path" to selected.file.absolutePath,
                    ).apply {
                        selected.sourcePathHint?.let { put("sourcePathHint", it) }
                    }
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun resolveMediaUriForImport(
        uri: Uri,
        typeHint: String?,
        filterMediaExtensions: Boolean = true,
    ): ImportableMediaFile? {
        // Only the explicit document picker may opt out of extension filtering.
        // Do not turn that opt-out into a network URI import entry point.
        if (!filterMediaExtensions && uri.scheme != "content" && uri.scheme != "file") return null
        if (filterMediaExtensions && !isLikelyMedia(uri, typeHint)) return null
        return MediaImportFiles.resolveUri(
            sourceScheme = uri.scheme,
            directPath = {
                if (uri.authority == "${packageName}.fileprovider") null
                else runCatching { resolveToPath(uri) }.getOrNull()?.takeIf { !filterMediaExtensions || isMediaPath(it) }
            },
            sourcePathHint = { trustedMediaSidecarSourceHint(uri) },
        ) { copyUriToCache(uri, typeHint, filterMediaExtensions) }
    }

    private fun trustedMediaSidecarSourceHint(uri: Uri): String? {
        if (!uri.scheme.equals("content", ignoreCase = true)) return null
        val primaryRoot = Environment.getExternalStorageDirectory()
        val secondaryRoot = System.getenv("SECONDARY_STORAGE")?.split(':')?.firstOrNull()
            ?.takeIf { it.isNotBlank() }?.let(::File)
        val hint = when {
            isExternalStorageDocument(uri) && DocumentsContract.isDocumentUri(this, uri) ->
                MediaImportFiles.readableExternalDocumentHint(
                    uri.authority, DocumentsContract.getDocumentId(uri), primaryRoot, secondaryRoot,
                )
            isMediaDocument(uri) && DocumentsContract.isDocumentUri(this, uri) -> {
                val documentId = DocumentsContract.getDocumentId(uri)
                if (!MediaImportFiles.isTrustedMediaStoreSource(uri.authority, documentId)) return null
                MediaImportFiles.readableMediaStoreHint(
                    uri.authority, documentId, resolveToPath(uri), primaryRoot, secondaryRoot,
                )
            }
            uri.authority == "media" -> {
                val sourceId = uri.path ?: return null
                // Validate before querying; unknown providers/MediaStore tables
                // cannot supply a sidecar directory through an arbitrary _data.
                if (!MediaImportFiles.isTrustedMediaStoreSource(uri.authority, sourceId)) return null
                MediaImportFiles.readableMediaStoreHint(
                    uri.authority, sourceId, getDataColumn(uri, null, null), primaryRoot, secondaryRoot,
                )
            }
            else -> null
        }
        return hint?.takeIf { isMediaPath(it) }
    }

    private fun isLikelyMedia(uri: Uri, typeHint: String?): Boolean {
        val normalizedHint = typeHint?.lowercase(Locale.ROOT)
        if (!normalizedHint.isNullOrEmpty() && normalizedHint != "*/*") {
            if (normalizedHint.startsWith("video/") || normalizedHint.startsWith("audio/")) return true
        }
        val resolverType = contentResolver.getType(uri)?.lowercase(Locale.ROOT)
        if (!resolverType.isNullOrEmpty()) {
            if (resolverType.startsWith("video/") || resolverType.startsWith("audio/")) return true
        }
        val displayName = queryDisplayName(uri)
        if (!displayName.isNullOrEmpty() && isMediaPath(displayName)) return true
        val lastPath = uri.lastPathSegment
        if (!lastPath.isNullOrEmpty() && isMediaPath(lastPath)) return true
        return false
    }

    private fun isLikelyFluentPack(uri: Uri, typeHint: String?): Boolean {
        val packageMime = "application/x-fluent-player-package"
        val normalizedHint = typeHint?.lowercase(Locale.ROOT)
        if (normalizedHint == packageMime) return true
        val resolverType = contentResolver.getType(uri)?.lowercase(Locale.ROOT)
        if (resolverType == packageMime) return true
        val displayName = queryDisplayName(uri)
        if (!displayName.isNullOrEmpty() && isFluentPackPath(displayName)) return true
        val lastPath = uri.lastPathSegment
        if (!lastPath.isNullOrEmpty() && isFluentPackPath(lastPath)) return true
        return false
    }

    private fun isLikelyArchive(uri: Uri, typeHint: String?): Boolean {
        val normalizedHint = typeHint?.lowercase(Locale.ROOT)
        if (!normalizedHint.isNullOrEmpty() && normalizedHint != "*/*") {
            if (
                normalizedHint.contains("zip") ||
                normalizedHint.contains("tar") ||
                normalizedHint.contains("gzip") ||
                normalizedHint.contains("bzip") ||
                normalizedHint.contains("xz") ||
                normalizedHint.contains("compressed")
            ) return true
        }
        val resolverType = contentResolver.getType(uri)?.lowercase(Locale.ROOT)
        if (!resolverType.isNullOrEmpty()) {
            if (
                resolverType.contains("zip") ||
                resolverType.contains("tar") ||
                resolverType.contains("gzip") ||
                resolverType.contains("bzip") ||
                resolverType.contains("xz") ||
                resolverType.contains("compressed")
            ) return true
        }
        val displayName = queryDisplayName(uri)
        if (!displayName.isNullOrEmpty() && isArchivePath(displayName)) return true
        val lastPath = uri.lastPathSegment
        if (!lastPath.isNullOrEmpty() && isArchivePath(lastPath)) return true
        return false
    }

    private fun isMediaPath(path: String): Boolean {
        val lower = path.lowercase(Locale.ROOT)
        return mediaExtensions.any { lower.endsWith(it) }
    }

    private fun isArchivePath(path: String): Boolean {
        val lower = path.lowercase(Locale.ROOT)
        return archiveExtensions.any { lower.endsWith(it) }
    }

    private fun isFluentPackPath(path: String): Boolean =
        path.lowercase(Locale.ROOT).endsWith(".fluentpack")

    private fun queryFileSize(uri: Uri): Long? {
        contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && !cursor.isNull(index)) {
                    return cursor.getLong(index)
                }
            }
        }
        return null
    }

    private fun buildArchiveSelectionPayload(uri: Uri): Map<String, Any?> {
        val displayName = queryDisplayName(uri)
            ?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment
            ?: "archive"
        if (!isArchivePath(displayName)) {
            throw IllegalArgumentException("当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包")
        }

        val directPath = readableImportPath(uri, ::isArchivePath)
        return mapOf(
            "displayName" to displayName,
            "sizeBytes" to queryFileSize(uri),
            "path" to directPath,
            "uri" to if (directPath == null) uri.toString() else null,
        )
    }

    private fun buildFluentPackSelectionPayload(uri: Uri): Map<String, Any?> {
        val rawName = queryDisplayName(uri)
            ?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment
            ?: "package.fluentpack"
        // Share-sheet MIME can identify a package whose display name lacks
        // the extension. Keep a real extension so Flutter/inspect can accept it.
        val displayName = when {
            isFluentPackPath(rawName) -> rawName
            !rawName.contains('.') -> "$rawName.fluentpack"
            else -> throw IllegalArgumentException("请选择 .fluentpack 文件")
        }
        val directPath = readableImportPath(uri, ::isFluentPackPath)
        return mapOf(
            "displayName" to displayName,
            "sizeBytes" to queryFileSize(uri),
            "path" to directPath,
            "uri" to if (directPath == null) uri.toString() else null,
        )
    }

    private fun buildImportFileSelectionPayload(uri: Uri): Map<String, Any?> {
        val displayName = queryDisplayName(uri)
            ?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment
            ?: "import"
        val fluentPack = isFluentPackPath(displayName)
        val archive = isArchivePath(displayName)
        if (!fluentPack && !archive) {
            throw IllegalArgumentException("请选择 .fluentpack，或 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包")
        }
        val directPath = readableImportPath(uri) {
            if (fluentPack) isFluentPackPath(it) else isArchivePath(it)
        }
        return mapOf(
            "displayName" to displayName,
            "sizeBytes" to queryFileSize(uri),
            "path" to directPath,
            "uri" to if (directPath == null) uri.toString() else null,
        )
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    val value = cursor.getString(index)
                    if (!value.isNullOrEmpty()) return value
                }
            }
        }
        return null
    }

    private fun materializeArchiveForImport(uriString: String, displayName: String?): String {
        val uri = Uri.parse(uriString)
        val directPath = readableImportPath(uri, ::isArchivePath)
        if (!directPath.isNullOrBlank()) {
            return directPath
        }

        val safeName = (displayName ?: queryDisplayName(uri) ?: "archive")
            .replace(Regex("""[^\u4e00-\u9fa5A-Za-z0-9._-]"""), "_")
            .takeIf { it.isNotBlank() }
            ?: "archive_${System.currentTimeMillis()}"
        val finalName = if (isArchivePath(safeName)) {
            safeName
        } else {
            "${safeName}.zip"
        }
        val archiveDir = File(cacheDir, "picked_archives").apply { mkdirs() }
        var outFile = File(archiveDir, finalName)
        if (outFile.exists()) {
            val base = finalName.substringBeforeLast('.', finalName)
            val suffix = finalName.substringAfterLast('.', "")
            val uniqueName = if (suffix.isNotEmpty()) {
                "${base}_${System.currentTimeMillis()}.$suffix"
            } else {
                "${base}_${System.currentTimeMillis()}"
            }
            outFile = File(archiveDir, uniqueName)
        }
        val partialFile = File(outFile.parentFile, "${outFile.name}.partial")
        try {
            if (partialFile.exists()) {
                partialFile.delete()
            }
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(partialFile).use { output ->
                    input.copyTo(output, bufferSize = 1024 * 1024)
                    output.fd.sync()
                }
            } ?: throw IllegalStateException("无法读取压缩包内容")
            if (partialFile.length() <= 0L || !partialFile.renameTo(outFile)) {
                throw IllegalStateException("无法保存压缩包临时副本")
            }
        } catch (e: Exception) {
            runCatching { partialFile.delete() }
            throw e
        }
        return outFile.absolutePath
    }

    private fun materializeFluentPackForImport(uriString: String, displayName: String?): String {
        val uri = Uri.parse(uriString)
        val directPath = readableImportPath(uri, ::isFluentPackPath)
        if (!directPath.isNullOrBlank()) return directPath

        val sourceName = displayName ?: queryDisplayName(uri) ?: "package.fluentpack"
        if (!isFluentPackPath(sourceName)) {
            throw IllegalArgumentException("请选择 .fluentpack 文件")
        }
        val safeName = sourceName
            .replace(Regex("""[^\u4e00-\u9fa5A-Za-z0-9._-]"""), "_")
            .takeIf { it.isNotBlank() }
            ?: "package_${System.currentTimeMillis()}.fluentpack"
        val packageDir = File(cacheDir, "picked_fluentpacks").apply { mkdirs() }
        var outFile = File(packageDir, safeName)
        if (outFile.exists()) {
            val base = safeName.removeSuffix(".fluentpack")
            outFile = File(packageDir, "${base}_${System.currentTimeMillis()}.fluentpack")
        }
        val partialFile = File(outFile.parentFile, "${outFile.name}.partial")
        try {
            if (partialFile.exists()) partialFile.delete()
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(partialFile).use { output ->
                    input.copyTo(output, bufferSize = 1024 * 1024)
                    output.fd.sync()
                }
            } ?: throw IllegalStateException("无法读取 FluentPack 内容")
            if (partialFile.length() <= 0L || !partialFile.renameTo(outFile)) {
                throw IllegalStateException("无法保存 FluentPack 临时副本")
            }
        } catch (e: Exception) {
            runCatching { partialFile.delete() }
            throw e
        }
        return outFile.absolutePath
    }

    private fun copyUriToCache(uri: Uri, typeHint: String?, filterMediaExtensions: Boolean = true): File {
        val resolver = contentResolver
        val displayName = queryDisplayName(uri)
        val mime = (resolver.getType(uri) ?: typeHint)?.lowercase(Locale.ROOT)
        val ext = run {
            val fromName = displayName?.substringAfterLast('.', "")
            if (!fromName.isNullOrEmpty()) fromName.lowercase(Locale.ROOT) else {
                val fromMime = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                fromMime?.lowercase(Locale.ROOT)
            }
        }
        val baseName = displayName?.substringBeforeLast('.', displayName)
            ?.replace(Regex("""[^\u4e00-\u9fa5A-Za-z0-9._-]"""), "_")
            ?.takeIf { it.isNotEmpty() }
            ?: "shared_media_${System.currentTimeMillis()}"
        val fileName = if (!ext.isNullOrEmpty()) "$baseName.$ext" else baseName
        if (filterMediaExtensions && !isMediaPath(fileName)) {
            throw IllegalArgumentException("所选文件不是受支持的媒体")
        }
        return MediaImportFiles.copyToCache(cacheDir, fileName, queryFileSize(uri)) {
            resolver.openInputStream(uri)
        }
    }

    private fun readableImportPath(uri: Uri, supported: (String) -> Boolean): String? =
        runCatching { MediaImportFiles.readablePath(resolveToPath(uri)?.takeIf(supported)) }.getOrNull()

    private fun resolveToPath(uri: Uri): String? {
        if ("file" == uri.scheme) {
            return uri.path
        }
        if ("content" == uri.scheme) {
            if (DocumentsContract.isDocumentUri(this, uri)) {
                val docId = DocumentsContract.getDocumentId(uri)
                val split = docId.split(":")
                val type = split.getOrNull(0)
                val relPath = split.getOrNull(1)
                if (isExternalStorageDocument(uri)) {
                    if (type.equals("primary", true)) {
                        val base = Environment.getExternalStorageDirectory().absolutePath
                        return if (relPath.isNullOrEmpty()) base else "$base/$relPath"
                    }
                    val secondary = System.getenv("SECONDARY_STORAGE")?.split(":")?.firstOrNull()
                    if (!secondary.isNullOrEmpty() && !relPath.isNullOrEmpty()) {
                        return "$secondary/$relPath"
                    }
                    return null
                }
                if (isDownloadsDocument(uri)) {
                    if (docId.startsWith("raw:")) {
                        return docId.removePrefix("raw:")
                    }
                    val contentUri = docId.toLongOrNull()?.let {
                        ContentUris.withAppendedId(Uri.parse("content://downloads/public_downloads"), it)
                    }
                    return contentUri?.let { getDataColumn(it, null, null) }
                }
                if (isMediaDocument(uri)) {
                    val mediaType = type ?: return null
                    val contentUri = when (mediaType) {
                        "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                        "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        else -> null
                    } ?: return null
                    val id = split.getOrNull(1) ?: return null
                    return getDataColumn(contentUri, "_id=?", arrayOf(id))
                }
            }
            return getDataColumn(uri, null, null)
        }
        return null
    }

    private fun getDataColumn(uri: Uri, selection: String?, selectionArgs: Array<String>?): String? {
        return try {
            val projection = arrayOf(MediaStore.MediaColumns.DATA)
            contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val index = cursor.getColumnIndex(MediaStore.MediaColumns.DATA)
                    if (index >= 0) {
                        return cursor.getString(index)
                    }
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun isExternalStorageDocument(uri: Uri): Boolean {
        return "com.android.externalstorage.documents" == uri.authority
    }

    private fun isDownloadsDocument(uri: Uri): Boolean {
        return "com.android.providers.downloads.documents" == uri.authority
    }

    private fun isMediaDocument(uri: Uri): Boolean {
        return "com.android.providers.media.documents" == uri.authority
    }

    private fun ensurePythonRuntimeReady() {}

    @Volatile
    private var activeYtDlpRuntimePath: String? = null

    private fun getYtDlpPythonModule(): Nothing = throw UnsupportedOperationException("Community edition")

    private fun reloadYtDlpRuntime(archivePath: String): String? { return null }

    private fun queryPythonYtDlpVersion(): String? { return null }

    private fun getYtDlpBinaryStatus(): Map<String, Any?> { return emptyMap() }

    private fun importYoutubeCookies(sourcePath: String): String? { return null }

    private fun saveYoutubeSessionConfig(config: Any?) {}

    private fun loadYoutubeSessionConfig(): Map<String, Any?>? { return null }

    private fun resolveYoutubeMeta(
        url: String,
        sessionConfig: Map<String, Any?>?,
    ): Map<String, Any?> { return emptyMap() }

    private fun resolveYtDlpBinary(): File { throw UnsupportedOperationException("Community edition") }

    private fun resolveFfmpegBinary(): File {
        val baseDir = File(filesDir, "yt_dlp")
        val candidates = listOf(
            File(baseDir, "ffmpeg"),
            File(baseDir, "ffmpeg_android"),
        )
        return candidates.firstOrNull { it.exists() } ?: candidates.first()
    }

    private fun queryBinaryVersion(binary: File, args: List<String>): String? {
        return try {
            val process = ProcessBuilder(listOf(binary.absolutePath) + args)
                .directory(binary.parentFile)
                .redirectErrorStream(true)
                .start()
            ProcessVersionProbe.readVersion(process)
        } catch (_: Exception) {
            null
        }
    }

    private fun buildSessionArgs(sessionConfig: Map<String, Any?>?): List<String> {
        if (sessionConfig == null) return emptyList()
        val args = mutableListOf<String>()

        fun readString(key: String): String? {
            return sessionConfig[key]?.toString()?.trim()?.takeIf { it.isNotEmpty() }
        }

        fun readInt(key: String): Int? {
            val value = sessionConfig[key] ?: return null
            return when (value) {
                is Int -> value
                is Long -> value.toInt()
                is Double -> value.toInt()
                is Float -> value.toInt()
                else -> value.toString().toIntOrNull()
            }
        }

        fun readBool(key: String): Boolean {
            val value = sessionConfig[key] ?: return false
            return when (value) {
                is Boolean -> value
                is String -> value.equals("true", ignoreCase = true)
                else -> false
            }
        }

        if (readBool("useCookies")) {
            readString("cookiesFilePath")?.let {
                args.add("--cookies")
                args.add(it)
            }
        }
        if (readBool("useCustomUserAgent")) {
            readString("userAgent")?.let {
                args.add("--add-header")
                args.add("User-Agent:$it")
            }
        }
        if (readBool("useProxy")) {
            readString("proxy")?.let {
                args.add("--proxy")
                args.add(it)
            }
        }
        readInt("socketTimeoutSeconds")?.takeIf { it > 0 }?.let {
            args.add("--socket-timeout")
            args.add(it.toString())
        }
        readInt("retries")?.takeIf { it > 0 }?.let {
            args.add("--retries")
            args.add(it.toString())
        }
        readInt("fragmentRetries")?.takeIf { it > 0 }?.let {
            args.add("--fragment-retries")
            args.add(it.toString())
        }
        readInt("concurrentFragments")?.takeIf { it > 0 }?.let {
            args.add("-N")
            args.add(it.toString())
        }
        readString("rateLimit")?.let {
            args.add("-r")
            args.add(it)
        }
        if (readBool("forceIpv4")) {
            args.add("-4")
        }

        buildYoutubeExtractorArgs(sessionConfig)?.let {
            args.add("--extractor-args")
            args.add(it)
        }
        return args
    }

    private fun buildYoutubeExtractorArgs(sessionConfig: Map<String, Any?>): String? { return null }

    private fun startYoutubeDownload(request: Map<String, Any?>): Boolean { return false }

    private fun pauseYoutubeDownload(taskId: String): Boolean { return false }

    private fun cancelYoutubeDownload(taskId: String): Boolean { return false }

    private fun removeYoutubeTask(taskId: String): Boolean { return false }

    private fun getYoutubeTaskStatus(taskId: String): Map<String, Any?>? { return null }

    private fun monitorYoutubeDownload(task: RunningYtDlpTask) {}

    private fun sanitizeAndroidDownloadArgs(
        originalArgs: List<String>,
        ffmpegAvailable: Boolean,
        androidPostProcessMode: Boolean,
    ): List<String> {
        if (ffmpegAvailable || androidPostProcessMode) {
            return originalArgs
        }
        val args = originalArgs.toMutableList()
        var index = 0
        while (index < args.size) {
            when (args[index]) {
                "-f" -> {
                    val format = args.getOrNull(index + 1)
                    if (format != null && format.contains("+")) {
                        args[index + 1] = "best"
                    }
                    index += 2
                }
                "--merge-output-format" -> {
                    args.removeAt(index)
                    if (index < args.size) args.removeAt(index)
                }
                "--embed-subs" -> {
                    args.removeAt(index)
                }
                "--postprocessor-args" -> {
                    args.removeAt(index)
                    if (index < args.size) args.removeAt(index)
                }
                "--extract-audio", "--audio-format" -> {
                    throw IllegalStateException(
                        "当前 Android 运行时尚未接入 ffmpeg CLI，所选任务需要音频提取或转码，请先改为直接下载可播放格式。",
                    )
                }
                else -> {
                    index += 1
                }
            }
        }
        return args
    }

    private fun injectFfmpegLocationArg(
        originalArgs: List<String>,
        ffmpeg: File,
    ): List<String> {
        if (!ffmpeg.exists()) {
            return originalArgs
        }
        if (originalArgs.any { it == "--ffmpeg-location" }) {
            return originalArgs
        }
        return originalArgs + listOf("--ffmpeg-location", ffmpeg.absolutePath)
    }

    private fun applyDownloadArtifacts(task: RunningYtDlpTask, result: Map<String, Any?>) {
        trackProducedPath(task, result["outputPath"]?.toString())
        val producedPaths = (result["producedPaths"] as? List<*>) ?: return
        producedPaths.forEach { path ->
            trackProducedPath(task, path?.toString())
        }
    }

    private fun isSubtitleArtifact(path: String): Boolean {
        val lowerPath = path.lowercase(Locale.ROOT)
        return listOf(
            ".srt",
            ".ass",
            ".ssa",
            ".vtt",
            ".lrc",
            ".ttml",
            ".srv1",
            ".srv2",
            ".srv3",
            ".json3",
        ).any(lowerPath::endsWith)
    }

    private fun hasUsableMediaArtifact(paths: List<String>): Boolean {
        return paths.any { path ->
            isMediaPath(path) && File(path).exists()
        }
    }

    private fun handlePythonProgress(task: RunningYtDlpTask, rawPayload: String) {}

    private fun mapMediaDownloadProgress(overallProgress: Double): Double {
        return (overallProgress.coerceIn(0.0, 1.0) * 0.90).coerceIn(0.0, 0.90)
    }

    private fun downloadKindLabel(mediaKind: String): String {
        return when (mediaKind) {
            "video" -> "视频轨道"
            "audio" -> "音频轨道"
            else -> "媒体文件"
        }
    }

    private fun buildDownloadStageMessage(
        mediaKind: String,
        formatId: String?,
        fragmentIndex: Int?,
        fragmentCount: Int?,
    ): String {
        val details = mutableListOf<String>()
        if (!formatId.isNullOrBlank()) {
            details.add("格式 $formatId")
        }
        if (fragmentIndex != null && fragmentCount != null && fragmentCount > 0) {
            details.add("分片 $fragmentIndex/$fragmentCount")
        }
        val suffix = if (details.isEmpty()) "" else " · ${details.joinToString(" · ")}"
        return "正在下载${downloadKindLabel(mediaKind)}$suffix"
    }

    private fun buildPostProcessorMessage(postprocessor: String?, status: String): String {
        val action = when {
            postprocessor?.contains("merger", ignoreCase = true) == true -> "合并音视频"
            postprocessor?.contains("thumbnail", ignoreCase = true) == true -> "处理封面"
            postprocessor?.contains("metadata", ignoreCase = true) == true -> "写入媒体信息"
            postprocessor?.contains("subtitle", ignoreCase = true) == true -> "处理字幕"
            else -> "处理下载产物"
        }
        return if (status == "finished") "$action 已完成" else "正在$action"
    }

    private inner class PythonTaskCallback(
        private val task: RunningYtDlpTask,
    ) {
        @Suppress("unused")
        fun onOutputLine(line: String) {
            handleYoutubeDownloadOutput(task, line)
        }

        @Suppress("unused")
        fun onProgress(payload: String) {
            handlePythonProgress(task, payload)
        }

        @Suppress("unused")
        fun isCancelled(): Boolean {
            return task.terminationReason == "cancel" || task.terminationReason == "pause"
        }
    }

    private fun handleYoutubeDownloadOutput(task: RunningYtDlpTask, rawLine: String) {}

    private fun buildTaskStepMessage(line: String): String? {
        val lower = line.lowercase()
        if (lower.contains("retrying fragment") ||
            (lower.contains("fragment") && lower.contains("retry"))
        ) {
            return "分片请求暂时失败，正在重试（最多 2 次）"
        }
        if (lower.contains("sleeping") || lower.contains("sleep interval")) {
            return "服务端要求暂时等待，yt-dlp 将自动继续"
        }
        if (lower.contains("timed out") || lower.contains("timeout")) {
            return "网络响应超时，等待 yt-dlp 重试"
        }
        if (line.startsWith("[download]")) {
            if (parseProgress(line) != null) {
                return null
            }
            if (line.contains("has already been downloaded")) {
                return "文件已存在，直接复用"
            }
            val fragmentCount = Regex(
                "Downloading\\s+(\\d+)\\s+fragments?",
                RegexOption.IGNORE_CASE,
            ).find(line)?.groupValues?.getOrNull(1)
            if (fragmentCount != null) {
                return "开始下载 $fragmentCount 个媒体分片"
            }
            if (line.contains("Destination:")) {
                return shortenTaskMessage(line)
            }
        }
        if (line.startsWith("[youtube", ignoreCase = true) ||
            line.startsWith("[info]", ignoreCase = true) ||
            line.contains("Extracting URL", ignoreCase = true) ||
            line.contains("Downloading webpage", ignoreCase = true) ||
            line.contains("Downloading player", ignoreCase = true) ||
            line.contains("Downloading m3u8", ignoreCase = true) ||
            line.contains("Downloading tv client config", ignoreCase = true) ||
            line.contains("Downloading ios player API JSON", ignoreCase = true) ||
            line.contains("Downloading android player API JSON", ignoreCase = true) ||
            line.contains("Downloading web player API JSON", ignoreCase = true) ||
            line.contains("Downloading initial data API JSON", ignoreCase = true) ||
            line.contains("Downloading subtitle", ignoreCase = true)
        ) {
            return shortenTaskMessage(line)
        }
        return null
    }

    private fun shortenTaskMessage(raw: String): String {
        var message = raw.replace(Regex("\\s+"), " ").trim()
        val quotedPathMatch = Regex("\"([^\"]+)\"").find(message)
        if (quotedPathMatch != null) {
            val fullPath = quotedPathMatch.groupValues.getOrNull(1)
            if (!fullPath.isNullOrBlank()) {
                message = message.replace(fullPath, File(fullPath).name)
            }
        }
        return if (message.length <= 96) {
            message
        } else {
            message.take(93) + "..."
        }
    }

    private fun emitTaskEvent(
        taskId: String,
        type: String,
        progress: Double? = null,
        downloadedBytes: Long? = null,
        totalBytes: Long? = null,
        speedText: String? = null,
        etaText: String? = null,
        outputPath: String? = null,
        producedPaths: List<String>? = null,
        errorCode: String? = null,
        message: String? = null,
    ) {
        val payload = mutableMapOf<String, Any?>(
            "taskId" to taskId,
            "type" to type,
            "progress" to progress,
            "downloadedBytes" to downloadedBytes,
            "totalBytes" to totalBytes,
            "speedText" to speedText,
            "etaText" to etaText,
            "outputPath" to outputPath,
            "producedPaths" to producedPaths,
            "errorCode" to errorCode,
            "message" to message,
        )
        runOnUiThread {
            ytDlpEventSink?.success(payload)
        }
    }

    private fun normalizeProducedPath(path: String?): String? {
        return path
            ?.trim()
            ?.trim('"')
            ?.takeIf { it.isNotEmpty() }
    }

    private fun isTransientArtifact(path: String): Boolean {
        val lowerPath = path.lowercase(Locale.ROOT)
        return lowerPath.endsWith(".part") ||
            lowerPath.endsWith(".ytdl") ||
            lowerPath.endsWith(".tmp") ||
            lowerPath.endsWith(".temp") ||
            lowerPath.endsWith(".frag")
    }

    private fun cleanupAndroidStagedArtifacts(task: RunningYtDlpTask) {
        val key = task.debugContext["androidTempArtifactKey"]?.toString()?.trim()
        if (key.isNullOrEmpty()) return
        val safeKey = key.replace(Regex("[^A-Za-z0-9_-]"), "_")
        val prefix = "ytdlp_${safeKey}_"
        val outputDirectory = File(task.outputDir)
        if (!outputDirectory.exists()) return
        outputDirectory.walkTopDown()
            .filter { it.isFile && it.name.startsWith(prefix) }
            .forEach { file -> runCatching { file.delete() } }
    }

    private fun trackProducedPath(task: RunningYtDlpTask, path: String?) {
        val normalized = normalizeProducedPath(path) ?: return
        task.outputPath = normalized
        if (!isTransientArtifact(normalized)) {
            task.producedPaths.add(normalized)
        }
    }

    private fun snapshotProducedPaths(task: RunningYtDlpTask): List<String> {
        val collected = LinkedHashSet<String>()
        synchronized(task.producedPaths) {
            collected.addAll(task.producedPaths)
        }
        normalizeProducedPath(task.outputPath)?.let {
            if (!isTransientArtifact(it)) {
                collected.add(it)
            }
        }

        val outputDirectory = File(task.outputDir)
        if (outputDirectory.exists()) {
            val templatePrefix = task.outputTemplate.substringBefore("%(", "")
            val hintedBaseName = normalizeProducedPath(task.outputPath)
                ?.let { File(it).nameWithoutExtension }
                ?.takeIf { it.isNotEmpty() }
            outputDirectory.listFiles()?.forEach { file ->
                if (!file.isFile) {
                    return@forEach
                }
                val filePath = file.absolutePath
                if (isTransientArtifact(filePath)) {
                    return@forEach
                }
                val fileName = file.name
                val fileBaseName = file.nameWithoutExtension
                val matchesPrefix = templatePrefix.isNotEmpty() && fileName.startsWith(templatePrefix)
                val matchesHint = hintedBaseName != null &&
                    (fileBaseName == hintedBaseName || fileName.startsWith("$hintedBaseName."))
                val isRecent = file.lastModified() >= task.startedAtMillis - 60_000L
                if (matchesPrefix || matchesHint || isRecent) {
                    collected.add(filePath)
                }
            }
        }
        return collected.toList()
    }

    private fun appendTaskLog(task: RunningYtDlpTask, line: String) {
        synchronized(task.logTail) {
            if (task.logTail.size >= 12) {
                task.logTail.removeFirst()
            }
            task.logTail.addLast(line)
        }
    }

    private fun buildTaskFailureMessage(task: RunningYtDlpTask, exitCode: Int?): String {
        val tail = synchronized(task.logTail) {
            task.logTail.joinToString("\n").trim()
        }
        val baseMessage = task.message?.takeIf { it.isNotBlank() }
        val tailMessage = tail.takeIf { it.isNotBlank() }
        val exitLabel = exitCode?.let { "退出码 $it" }
        return listOfNotNull(baseMessage, tailMessage, exitLabel)
            .joinToString("\n")
            .ifBlank { "下载失败" }
    }

    private fun RunningYtDlpTask.usesAndroidPostProcessMode(): Boolean {
        return debugContext["androidPostProcessMode"] == true
    }

    private fun extractOutputPath(line: String): String? {
        val markers = listOf(
            "Destination:",
            "Merging formats into",
            "[ExtractAudio] Destination:",
        )
        for (marker in markers) {
            if (!line.contains(marker)) continue
            return line.substringAfter(marker)
                .trim()
                .trim('"')
                .takeIf { it.isNotEmpty() }
        }
        return null
    }

    private fun extractStructuredOutputPath(line: String): Pair<String, String>? {
        val before = line.substringAfter(YTDLP_BEFORE_DL_MARKER, "").trim()
        if (before.isNotEmpty()) {
            return "before_dl" to before.trim('"')
        }
        val after = line.substringAfter(YTDLP_AFTER_MOVE_MARKER, "").trim()
        if (after.isNotEmpty()) {
            return "after_move" to after.trim('"')
        }
        return null
    }

    private fun parseProgress(line: String): Double? {
        val match = Regex("""(\d+(?:\.\d+)?)%""").find(line) ?: return null
        val value = match.groupValues.getOrNull(1)?.toDoubleOrNull() ?: return null
        return (value / 100.0).coerceIn(0.0, 1.0)
    }

    private fun parseSpeed(line: String): String? {
        val match = Regex("""\bat\s+(.+?)\s+ETA\b""").find(line)
        return match?.groupValues?.getOrNull(1)?.trim()
    }

    private fun parseEta(line: String): String? {
        val match = Regex("""\bETA\s+([0-9:]+)""").find(line)
        return match?.groupValues?.getOrNull(1)?.trim()
    }

    private fun encodeDynamicJson(value: Any?): String? {
        if (value == null) return null
        return when (value) {
            is Map<*, *> -> JSONObject(value).toString()
            is List<*> -> JSONArray(value).toString()
            else -> JSONObject.wrap(value)?.toString()
        }
    }

    private fun decodeJsonObject(raw: String): Map<String, Any?>? {
        return try {
            jsonObjectToMap(JSONObject(raw))
        } catch (_: Exception) {
            null
        }
    }

    private fun jsonObjectToMap(jsonObject: JSONObject): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val keys = jsonObject.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = unwrapJsonValue(jsonObject.opt(key))
        }
        return result
    }

    private fun jsonArrayToList(jsonArray: JSONArray): List<Any?> {
        val result = mutableListOf<Any?>()
        for (index in 0 until jsonArray.length()) {
            result.add(unwrapJsonValue(jsonArray.opt(index)))
        }
        return result
    }

    private fun unwrapJsonValue(value: Any?): Any? {
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> jsonObjectToMap(value)
            is JSONArray -> jsonArrayToList(value)
            else -> value
        }
    }

    private data class RunningYtDlpTask(
        val taskId: String,
        val outputDir: String,
        val outputTemplate: String,
        val sourceUrl: String,
        val requestPayload: Map<String, Any?>,
        val debugContext: Map<String, Any?> = emptyMap(),
        val startedAtMillis: Long = System.currentTimeMillis(),
        val producedPaths: MutableSet<String> = Collections.synchronizedSet(LinkedHashSet()),
        @Volatile var process: Process? = null,
        @Volatile var status: String = "queued",
        @Volatile var progress: Double? = null,
        @Volatile var downloadedBytes: Long? = null,
        @Volatile var totalBytes: Long? = null,
        @Volatile var speedText: String? = null,
        @Volatile var etaText: String? = null,
        @Volatile var outputPath: String? = null,
        @Volatile var errorCode: String? = null,
        @Volatile var message: String? = null,
        @Volatile var terminationReason: String? = null,
        val logTail: ArrayDeque<String> = ArrayDeque(),
    )

}

/**
 * Survives MainActivity recreation while audio_service keeps the Flutter
 * engine. Pending shares and the event sink used to live on the Activity
 * instance, so a new Activity could resolve a zip while Dart still queried
 * the previous instance's empty queue.
 */
private object ShareIntentDelivery {
    private val lock = Any()
    private val pendingSharedItems = mutableListOf<Map<String, Any?>>()
    private var shareEventSink: EventChannel.EventSink? = null
    val executor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "shared-intent-resolver")
    }

    fun setSink(events: EventChannel.EventSink?) {
        synchronized(lock) {
            shareEventSink = events
            if (events != null && pendingSharedItems.isNotEmpty()) {
                events.success(ArrayList(pendingSharedItems))
                pendingSharedItems.clear()
            }
        }
    }

    fun clearSink(events: EventChannel.EventSink?) {
        synchronized(lock) {
            if (shareEventSink === events || events == null) {
                shareEventSink = null
            }
        }
    }

    fun takePending(): ArrayList<Map<String, Any?>> {
        synchronized(lock) {
            val copy = ArrayList(pendingSharedItems)
            pendingSharedItems.clear()
            return copy
        }
    }

    fun deliver(items: List<Map<String, Any?>>) {
        if (items.isEmpty()) return
        synchronized(lock) {
            val sink = shareEventSink
            if (sink != null) {
                sink.success(ArrayList(items))
            } else {
                pendingSharedItems.addAll(items)
            }
        }
    }
}
