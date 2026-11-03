import 'widgets/processing_screen_protection.dart';
import 'features/web_media/web_media_download_queue.dart';
import 'features/douyin_download/douyin_download_controller.dart';
import 'features/media_cache/app_media_cache_backend.dart';
import 'features/media_cache/media_cache_service.dart';
import 'features/media_cache/media_cache_models.dart';
import 'features/media_cache/media_cache_playback.dart';
import 'features/media_cache/media_cache_hooks.dart';
import 'features/podcasts/podcast_playback_hooks.dart';
import 'features/media_cache/bilibili_download_cache.dart';
import 'services/storage_migration_coordinator.dart';
import 'widgets/storage_settings_dialog.dart';
import 'widgets/keyboard_shortcut_help.dart';
import 'utils/keyboard_shortcut_hints.dart';
import 'utils/page_shortcut_keys.dart';
import 'platform/linux_file_picker.dart';
import 'platform/linux_application_identity.dart';
import 'platform/linux_media_runtime.dart';
import 'widgets/import_location_picker.dart';
import 'services/app_storage_service.dart';
import 'services/subtitle_font_service.dart';
import 'services/windows_subtitle_exit_guard.dart';
import 'dart:async';
import 'features/podcasts/podcast_runtime.dart';
import 'features/podcasts/podcast_pages.dart';
import 'services/network/network_http.dart';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'utils/app_data_paths.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import 'features/ai_chat/ai_chat_session.dart';
import 'features/progress_sync/folder_sync_request_prompt.dart';
import 'features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/platform/windows_video_player_media_kit.dart';
import 'screens/home_screen.dart';
import 'features/onboarding/onboarding_store.dart';
import 'services/library_service.dart';
import 'services/settings_service.dart';
import 'services/app_default_settings_trial.dart';
import 'models/recommended_app_defaults.dart';
import 'features/ai_chat/ai_chat_typography.dart';
import 'features/ai_chat/ai_chat_settings.dart';
import 'services/subtitle_translate_settings.dart';
import 'services/transcription_manager.dart';
import 'features/model_center/model_center_service.dart';
import 'services/model_task_interruption.dart';
import 'services/subtitle_translation_service.dart';
import 'services/media_materialization_service.dart';
import 'services/batch_import_service.dart';
import 'services/bilibili/bilibili_cache_limit_service.dart';
import 'services/embedded_subtitle_service.dart';
import 'services/bilibili/bilibili_download_service.dart';
import 'services/bilibili/bilibili_streaming_service.dart';
import 'services/bilibili/bilibili_watch_cards.dart';
import 'services/bilibili/bilibili_watch_launch.dart';
import 'services/bilibili/bilibili_watch_playlist.dart';
import 'services/media_playback_service.dart';
import 'services/playlist_manager.dart';
import 'services/playback_navigation_service.dart';
import 'services/playback_restore_preview.dart';
import 'features/cloud_drive/services/cloud_drive_runtime.dart';
import 'services/progress_tracker.dart';
import 'services/thumbnail_cache_service.dart';
import 'services/video_compose_manager.dart';
import 'services/ocr_subtitle_manager.dart';
import 'services/subtitle_stream_source.dart';
import 'services/system_media_session_service.dart';
import 'utils/app_toast.dart';
import 'utils/app_localizations.dart';
import 'utils/ime_shortcut_gate.dart';
import 'utils/first_open_ui_warmup.dart';
import 'utils/tooltip_hover_policy.dart';
import 'widgets/incoming_share_listener.dart';
import 'widgets/app_clipboard_listener.dart';
import 'services/clipboard_detection_routes.dart';
import 'widgets/media_library_shell.dart';
import 'widgets/mobile_system_navigation_bar.dart';
import 'widgets/ui_refresh_rate_scope.dart';
import 'widgets/mouse_back_button_listener.dart';
import 'widgets/app_text_input_focus.dart';
import 'widgets/library_persistence_notification_bridge.dart';
import 'theme/app_page_transitions.dart';
import 'theme/app_interaction_theme.dart';
import 'theme/app_typography.dart';
import 'widgets/tooltip_interaction_guard.dart';
import 'debug/debug_log_buffer.dart';
import 'debug/log_redaction.dart';
import 'services/app_licenses.dart';
import 'debug/debug_log_navigator.dart';
import 'debug/debug_log_overlay.dart';
import 'debug/app_startup_trace.dart';

void main() async {
  AppStartupTrace.start();
  registerAppLicenses();
  WidgetsFlutterBinding.ensureInitialized();
  LinuxFilePicker.install();
  Object? linuxIdentityError;
  try {
    await prepareLinuxApplicationIdentity();
    initializeLinuxMediaRuntime();
  } catch (error) {
    linuxIdentityError = error;
  }
  if (Platform.isAndroid || Platform.isIOS) {
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  }
  NetworkHttp.instance.observeDeviceNetwork();
  unawaited(NetworkSettingsService.instance.init().catchError((Object _) {}));
  DebugLogBuffer.instance.install();
  installDebugLogBackHandler();
  ImeShortcutGate.install();
  _configureImageCaches();

  // Create a stable provider graph synchronously. Disk-backed and plugin
  // initialization starts only after the lightweight startup frame is visible.
  final settings = SettingsService();
  final subtitleTranslateSettings = SubtitleTranslateSettings();
  unawaited(subtitleTranslateSettings.ensureLoaded());
  final library = LibraryService();
  installImportLocationPicker(library);
  ThumbnailCacheService().setMissingThumbnailResolver(
    (videoId) => library.ensureThumbnailForVideo(videoId),
  );
  final batch = BatchImportService();

  // Register Services
  final transcriptionManager = TranscriptionManager();
  final embeddedSubtitleService = EmbeddedSubtitleService();
  final bilibiliService = BilibiliDownloadService();
  library.attachBilibiliStreamingService(bilibiliService.streamingService);
  library.attachMediaMaterializationService(
    bilibiliService.materializationService,
  );
  final ytDlpService = YtDlpDownloadService();
  // The metadata root is selected after the lightweight startup frame.
  final videoComposeManager = VideoComposeManager(
    library: library,
    deferTaskLoading: true,
  );
  final ocrSubtitleManager = OcrSubtitleManager(library: library);
  installModelTaskInterruptionHandler(
    pauseTranscription: transcriptionManager.pauseAllTasks,
    cancelTranslation: SubtitleTranslationService.instance.cancel,
    cancelOcr: ocrSubtitleManager.cancel,
    modelCenterLoaded: () => ModelCenterService.instance.loaded,
    pauseModelDownloads: () => ModelCenterService.instance.pauseAll(),
    videoComposeManager: videoComposeManager,
  );

  // Initialize media playback services
  final playlistManager = PlaylistManager();
  playlistManager.initialize(libraryService: library);

  final progressTracker = ProgressTracker();
  progressTracker.initialize(libraryService: library);

  final mediaPlaybackService = MediaPlaybackService();
  final mediaCache = MediaCacheService(
    backend: AppMediaCacheBackend(bilibiliService),
    isPathInUse: (path) {
      if (mediaPlaybackService.controller == null) return false;
      final item = mediaPlaybackService.currentItem;
      if (item?.path == path || item?.playbackPath == path) return true;
      if (item == null) return false;
      final key = CacheSource.fromItem(item)?.key;
      return key != null &&
          MediaCacheService.instance?.tasks.any(
                (task) =>
                    task.state == CacheTaskState.completed &&
                    task.source.key == key &&
                    task.workDirectory != null &&
                    AppStorageService.samePath(task.workDirectory!, path),
              ) ==
              true;
    },
    onBeforeDelete: (variant) => library.detachOfflineMediaFile(variant.path),
    onFilesRemoved: (paths) async {
      await library.notifyStorageFilesDeleted(paths);
      await bilibiliService.forgetStorageFiles(paths);
      await PodcastPlaybackHooks.forgetDeletedStorage?.call(paths);
    },
    onChanged: () => library.notifyOnlineCacheChanged(''),
  );
  MediaCacheService.instance = mediaCache;
  final mediaCachePlayback = MediaCachePlayback(mediaCache)..install();
  MediaCacheHooks.pathInUse = (path) =>
      PodcastPlaybackHooks.isStoragePathInUse?.call(path) ?? false;
  MediaCacheHooks.discover = (source) async {
    final item = library.getVideo(source.itemId) ?? source.toItem();
    if (source.isPodcast) {
      return await PodcastPlaybackHooks.cachedVariants?.call(item) ?? [];
    }
    if (!source.isBilibili) {
      return await library.cloudDriveMaterialization?.cacheVariants(item) ?? [];
    }
    final variants = <CacheVariant>[];
    for (final candidate in [
      item,
      ...library
          .bilibiliCacheCandidates(source.ref.bvid, source.ref.cid)
          .where(
            (other) =>
                other.id != item.id &&
                other.sourceRef?.bvid == source.ref.bvid &&
                other.sourceRef?.cid == source.ref.cid,
          ),
    ]) {
      variants.addAll(
        await bilibiliService.materializationService.cacheVariants(candidate),
      );
    }
    return variants;
  };
  final progressSync = ProgressSyncService(
    library: library,
    activeMediaId: () => mediaPlaybackService.currentItem?.id,
  );
  mediaPlaybackService.beforeLibraryPlayback = progressSync.preparePlayback;
  DefaultTrialRuntime.bindings.addAll({
    'bilibili': DefaultTrialRuntimeBinding(
      flush: bilibiliService.flushPreferencesForTrial,
      reload: bilibiliService.reloadPreferencesForTrial,
    ),
    'ytDlp': DefaultTrialRuntimeBinding(
      flush: ytDlpService.flushPreferencesForTrial,
      reload: ytDlpService.reloadPreferencesForTrial,
    ),
    'translation': DefaultTrialRuntimeBinding(
      flush: subtitleTranslateSettings.flushPreferencesForTrial,
      reload: subtitleTranslateSettings.reloadPreferencesForTrial,
    ),
    'reading': DefaultTrialRuntimeBinding(
      flush: AiChatReadingSettings.instance.flushPreferencesForTrial,
      reload: AiChatReadingSettings.instance.reloadPreferencesForTrial,
    ),
    'chat': DefaultTrialRuntimeBinding(
      flush: AiChatSessions.instance.flushPreferencesForTrial,
      reload: () async => AiChatSessions.instance.adoptPreferenceFields(
        await AiChatSettingsStore().preferenceFieldsForTrial(
          RecommendedAppDefaults.aiFields,
        ),
      ),
    ),
    'model': DefaultTrialRuntimeBinding(
      flush: ModelCenterService.instance.flushPreferencesForTrial,
      reload: ModelCenterService.instance.reloadPreferencesForTrial,
      patchRecord: ModelCenterService.instance.patchPreferencesForTrial,
    ),
    'cache': DefaultTrialRuntimeBinding(
      flush: mediaCache.flushPreferencesForTrial,
      reload: mediaCache.reloadPreferencesForTrial,
      patchRecord: mediaCache.patchPreferencesForTrial,
    ),
    'podcasts': DefaultTrialRuntimeBinding(
      flush: PodcastRuntime.instance.flushPreferencesForTrial,
      reload: PodcastRuntime.instance.reloadPreferencesForTrial,
    ),
    'webQueue': DefaultTrialRuntimeBinding(
      flush: () => WebMediaDownloadQueue.flushPreferencesForTrial(library),
      reload: () => WebMediaDownloadQueue.reloadPreferencesForTrial(library),
    ),
    'sleep': DefaultTrialRuntimeBinding(
      flush: mediaPlaybackService.sleepTimer.flushPreferencesForTrial,
      reload: mediaPlaybackService.sleepTimer.reloadPreferencesForTrial,
    ),
    'playback': DefaultTrialRuntimeBinding(
      flush: () async {},
      reload: mediaPlaybackService.reloadPreferencesForTrial,
    ),
  });
  bool syncWasPlaying = false;
  String? syncLastItem;
  mediaPlaybackService.addListener(() {
    final playing = mediaPlaybackService.isPlaying;
    final id = mediaPlaybackService.currentItem?.id;
    if ((syncWasPlaying && !playing) ||
        (syncLastItem != null && syncLastItem != id)) {
      unawaited(progressSync.flush());
    }
    syncWasPlaying = playing;
    syncLastItem = id;
  });
  bilibiliService.materializationService.onRequestPlaybackRelease =
      mediaPlaybackService.releaseMaterializedPlaybackForClear;
  final deferredServicesReady = Completer<void>();
  final libraryMetadataReady = Completer<void>();
  final coreLibraryReady = Completer<void>();
  PlaybackRestorePreview? restoredPlaybackPreview;

  // Mini can now be opened before podcast setup. Register its route now; only
  // an actual play request waits for the deferred source resolver to be ready.
  installPodcastNavigation();
  PodcastPlaybackHooks.deferResolveUntil(deferredServicesReady.future);

  // Register the cloud wait point before any page or restored card can use it.
  // Only the library directory is required; unrelated deferred services must
  // not leave an early cloud page with a permanent "not initialized" error.
  CloudDriveRuntime.beginInstall(
    library: library,
    playlist: playlistManager,
    mediaPlayback: mediaPlaybackService,
    libraryReady: coreLibraryReady.future,
  );

  // Queue reconstruction and native warmup can wait for integrations. Mini's
  // local bookmark is already published by initializeStartupServices below.
  libraryMetadataReady.future.then((_) {
    _restorePlaybackState(
      mediaPlaybackService: mediaPlaybackService,
      playlistManager: playlistManager,
      library: library,
      preview: restoredPlaybackPreview,
      integrationsReady: deferredServicesReady.future,
    ).catchError((e) {
      debugPrint('恢复播放状态失败: $e');
    });
  });

  // 初始化崩溃日志路径，供 FlutterError.onError 和 runZonedGuarded 使用。
  // 必须在 runZonedGuarded 之前完成，确保错误处理器可用。
  await _initCrashLogPath();

  // 捕获框架级异常（渲染/布局/Widget 错误）。
  // runZonedGuarded 无法捕获此类异常，需单独处理，否则直接导致崩溃无日志。
  FlutterError.onError = (FlutterErrorDetails details) {
    final own = DebugLogBuffer.instance.stackOriginatesInOverlay(details.stack);
    if (own) DebugLogBuffer.instance.beginSuppressingOwnOutput();
    try {
      FlutterError.presentError(details);
    } finally {
      if (own) DebugLogBuffer.instance.endSuppressingOwnOutput();
    }
    if (!own) {
      DebugLogBuffer.instance.recordReleaseFrameworkError(
        details.exception,
        details.stack,
      );
    }
    _writeCrashLog(
      '[FlutterError] ${details.exception}\n${details.stack ?? ''}',
    );
  };

  StorageMigrationCoordinator.preflight = () async {
    if (library.hasActiveImport ||
        transcriptionManager.isProcessing ||
        ocrSubtitleManager.isRunning ||
        videoComposeManager.runningTask != null ||
        progressSync.busy) {
      throw const StorageUnavailableException(
        '请等待导入、转写、OCR、合成或设备同步完成后再迁移；下载任务会自动暂停',
      );
    }
    if (SubtitleTranslationService.instance.isTranslating ||
        ModelCenterService.instance.hasModelLeases) {
      throw const StorageUnavailableException('请等待本地模型检查或字幕翻译完成后再迁移');
    }
  };
  StorageMigrationCoordinator.register(
    StorageParticipant('runtime', () async {
      await mediaPlaybackService.pause();
      await mediaCache.shutdown();
      await mediaCachePlayback.shutdown();
      if (ModelCenterService.instance.loaded) {
        await ModelCenterService.instance.shutdown();
      }
      progressSync.dispose();
      await videoComposeManager.prepareStorageMigration();
      await batch.prepareStorageMigration();
      await WebMediaDownloadQueue.forLibrary(library).pauseAll();
      await WebMediaDownloadQueue.forLibrary(library).shutdown();
      await DouyinDownloadController.shared.prepareStorageMigration();
      await bilibiliService.shutdown();
      await ytDlpService.prepareStorageMigration();
      await transcriptionManager.shutdown();
      await PodcastRuntime.instance.prepareStorageMigration();
      await CloudDriveRuntime.prepareStorageMigration();
      await library.prepareStorageMigration();
    }),
  );

  Future<void> initializeStartupServices() async {
    if (linuxIdentityError != null) {
      await prepareLinuxApplicationIdentity();
      initializeLinuxMediaRuntime();
      linuxIdentityError = null;
    }
    await _initializeStartupServices(
      settings: settings,
      mediaPlaybackService: mediaPlaybackService,
      playlistManager: playlistManager,
      progressTracker: progressTracker,
      library: library,
      embeddedSubtitleService: embeddedSubtitleService,
      bilibiliStreamingService: bilibiliService.streamingService,
      videoComposeManager: videoComposeManager,
    );
    try {
      // Publish before mounting Home. Do not wait for notifications, cache
      // migration, podcast startup, or any remote media preparation.
      restoredPlaybackPreview = await AppStartupTrace.measure(
        'playback-preview',
        () => restorePlaybackPreview(
          playback: mediaPlaybackService,
          progress: progressTracker,
          playlist: playlistManager,
          library: library,
        ),
      );
    } catch (e) {
      debugPrint('恢复本地播放卡片失败: $e');
    }
  }

  // Android already owns a native launch surface. Keep that single cover on
  // screen until the core state is ready, so the first Flutter frame is the
  // real home page instead of a second, differently scaled copy of the logo.
  var useNativeAndroidLaunchSurface = Platform.isAndroid;
  if (useNativeAndroidLaunchSurface) {
    try {
      await initializeStartupServices();
    } catch (_) {
      useNativeAndroidLaunchSurface = false;
    }
  }

  runZonedGuarded(
    () {
      runApp(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: settings),
            ChangeNotifierProvider.value(value: subtitleTranslateSettings),
            ChangeNotifierProvider.value(value: library),
            ChangeNotifierProvider.value(value: mediaCache),
            ChangeNotifierProvider.value(value: progressSync),
            ChangeNotifierProvider.value(value: transcriptionManager),
            ChangeNotifierProvider.value(value: batch),
            ChangeNotifierProvider.value(value: embeddedSubtitleService),
            ChangeNotifierProvider.value(value: bilibiliService),
            ChangeNotifierProvider<BilibiliStreamingService>.value(
              value: bilibiliService.streamingService,
            ),
            ChangeNotifierProvider<MediaMaterializationService>.value(
              value: bilibiliService.materializationService,
            ),
            ChangeNotifierProvider.value(value: ytDlpService),
            ChangeNotifierProvider.value(value: videoComposeManager),
            ChangeNotifierProvider.value(value: ocrSubtitleManager),
            Provider<SubtitleStreamSource>(
              create: (_) =>
                  SubtitleStreamHub([transcriptionManager, ocrSubtitleManager]),
              dispose: (_, source) => (source as SubtitleStreamHub).dispose(),
            ),
            ChangeNotifierProvider.value(value: playlistManager),
            ChangeNotifierProvider.value(value: mediaPlaybackService),
          ],
          child: AppStartupGate(
            initialize: initializeStartupServices,
            initiallyReady: useNativeAndroidLaunchSurface,
            onReadyFirstFrame: () {
              AppStartupTrace.mark('home-first-frame');
              library.startDeferredMaintenance();
              unawaited(SubtitleFontService.instance.ready);
              // Cloud setup also schedules thumbnail repairs. Start it after
              // Home has painted, without waiting for cache/notification work.
              if (!coreLibraryReady.isCompleted) coreLibraryReady.complete();
              unawaited(
                _initializeDeferredServices(
                  library: library,
                  batch: batch,
                  transcriptionManager: transcriptionManager,
                  ocrSubtitleManager: ocrSubtitleManager,
                  bilibiliService: bilibiliService,
                  ytDlpService: ytDlpService,
                  mediaPlaybackService: mediaPlaybackService,
                  playlistManager: playlistManager,
                  onLibraryReady: () {
                    if (!libraryMetadataReady.isCompleted) {
                      libraryMetadataReady.complete();
                    }
                  },
                ).whenComplete(() {
                  unawaited(progressSync.init());
                  if (!deferredServicesReady.isCompleted) {
                    deferredServicesReady.complete();
                  }
                }),
              );
            },
            child: MyApp(
              bilibiliService: bilibiliService,
              transcriptionManager: transcriptionManager,
            ),
          ),
        ),
      );
    },
    (error, stack) {
      final own = DebugLogBuffer.instance.stackOriginatesInOverlay(stack);
      if (own) DebugLogBuffer.instance.beginSuppressingOwnOutput();
      try {
        debugPrint('Uncaught error: $error');
        debugPrint(stack.toString());
      } finally {
        if (own) DebugLogBuffer.instance.endSuppressingOwnOutput();
      }
      if (!own) {
        DebugLogBuffer.instance.recordReleaseFrameworkError(error, stack);
      }
      _writeCrashLog('[ZoneError] $error\n$stack');
      unawaited(transcriptionManager.shutdown());
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (!DebugLogBuffer.instance.isForwardingDebugPrint) {
          DebugLogBuffer.instance.add(line);
        }
        parent.print(zone, redactSensitiveLogText(line));
      },
    ),
  );
}

Future<void> _initializeStartupServices({
  required SettingsService settings,
  required MediaPlaybackService mediaPlaybackService,
  required PlaylistManager playlistManager,
  required ProgressTracker progressTracker,
  required LibraryService library,
  required EmbeddedSubtitleService embeddedSubtitleService,
  required BilibiliStreamingService bilibiliStreamingService,
  required VideoComposeManager videoComposeManager,
}) async {
  Future<void> safely(String name, Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      debugPrint('$name init failed: $e');
    }
  }

  // Window setup is independent of persisted settings, so it can run in
  // parallel. This function starts after the startup frame, which prevents
  // show() from exposing an unpainted Flutter view.
  final desktopWindowFuture = safely(
    'Desktop window',
    _initializeDesktopWindow,
  );

  await safely('Onboarding', OnboardingStore.prepareFirstLaunch);
  await AppStartupTrace.measure('settings', settings.init);
  await AppStartupTrace.measure(
    'storage',
    () => AppStorageService.instance.initialize(
      configuredRoot: settings.largeDataRootPath,
      holdLease: true,
    ),
  );
  await AppStartupTrace.measure(
    'compose-tasks',
    videoComposeManager.initialize,
  );
  if (AppStorageService.instance.requiresBootstrapRelocation) {
    final target = await AppStorageService.instance.defaultDataDirectory();
    await StorageMigrationCoordinator(
      AppStorageService.instance,
      bootstrap: true,
    ).migrate(target);
    await settings.setLargeDataRootPath(target.path);
  }
  await AppStartupTrace.measure(
    'library',
    () => library.init(deferMaintenance: true),
  );

  // Preserve the original dependency order: playback reads persisted mute
  // state only after settings have had an opportunity to load.
  await safely(
    'MediaPlaybackService',
    () => mediaPlaybackService.initialize(
      playlistManager: playlistManager,
      progressTracker: progressTracker,
      libraryService: library,
      embeddedSubtitleService: embeddedSubtitleService,
      bilibiliStreamingService: bilibiliStreamingService,
    ),
  );

  await desktopWindowFuture;
}

Future<void> _initializeDesktopWindow() async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    return;
  }

  await windowManager.ensureInitialized();
  if (Platform.isWindows) {
    await WindowsSubtitleExitGuard.install();
  }

  // The GTK runner sizes Linux once, before mapping its FlView. Resizing or
  // maximizing again during engine startup can invalidate the first GL frame.
  if (Platform.isLinux) {
    return;
  }

  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    center: true,
    backgroundColor: Color(0xFF121212),
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.maximize();
    await windowManager.focus();
  });
}

/// Paints a minimal first frame before any plugin or disk-backed startup work.
///
/// The real application is mounted only after its existing startup dependencies
/// are ready, so users cannot interact with partially initialized services.
@visibleForTesting
class AppStartupGate extends StatefulWidget {
  const AppStartupGate({
    super.key,
    required this.initialize,
    required this.onReadyFirstFrame,
    required this.child,
    this.initiallyReady = false,
  });

  final Future<void> Function() initialize;
  final VoidCallback onReadyFirstFrame;
  final Widget child;
  final bool initiallyReady;

  @override
  State<AppStartupGate> createState() => _AppStartupGateState();
}

class _AppStartupGateState extends State<AppStartupGate> {
  late bool _isReady;
  bool _initializationStarted = false;
  bool _readyFirstFrameReported = false;
  Object? _storageError;

  @override
  void initState() {
    super.initState();
    _isReady = widget.initiallyReady;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isReady) {
        _reportReadyFirstFrame();
        return;
      }
      if (_initializationStarted) return;
      _initializationStarted = true;
      unawaited(_initialize());
    });
  }

  Future<void> _initialize() async {
    try {
      await widget.initialize();
    } catch (e, stack) {
      await AppStorageService.instance.releaseForegroundLease();
      debugPrint('App startup initialization failed: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) setState(() => _storageError = e);
      return;
    }

    if (!mounted) return;
    setState(() {
      _isReady = true;
      _storageError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportReadyFirstFrame();
    });
  }

  void _reportReadyFirstFrame() {
    if (_readyFirstFrameReported) return;
    _readyFirstFrameReported = true;
    debugPrint('Fluent Player startup ready');
    widget.onReadyFirstFrame();
  }

  @override
  Widget build(BuildContext context) {
    if (_isReady) return widget.child;
    if (_storageError != null) {
      return MaterialApp(
        home: StorageRecoveryScreen(
          error: _storageError!,
          onRetry: () async {
            setState(() => _storageError = null);
            AppStorageService.instance.resetForRetry();
            await _initialize();
          },
        ),
      );
    }
    return const _StartupSurface();
  }
}

class _StartupSurface extends StatelessWidget {
  const _StartupSurface();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fluent Player',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: appLocalizationDelegates,
      supportedLocales: appSupportedLocales,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(primary: Color(0xFF6EA8FF)),
      ),
      home: Scaffold(
        body: Center(
          child: Semantics(
            image: true,
            label: 'Fluent Player',
            child: Image.asset(
              'android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png',
              key: const ValueKey<String>('startup-cover'),
              width: 112,
              height: 112,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _initializeDeferredServices({
  required LibraryService library,
  required BatchImportService batch,
  required TranscriptionManager transcriptionManager,
  required OcrSubtitleManager ocrSubtitleManager,
  required BilibiliDownloadService bilibiliService,
  required YtDlpDownloadService ytDlpService,
  required MediaPlaybackService mediaPlaybackService,
  required PlaylistManager playlistManager,
  required VoidCallback onLibraryReady,
}) async {
  Future<void> safely(String name, Future<void> Function() operation) async {
    try {
      await operation();
    } catch (e) {
      debugPrint('$name init failed: $e');
    }
  }

  // Native codec discovery and video_player registration can load shared
  // libraries. Do it after the first frame, but before library restoration can
  // create any player controller.
  try {
    NativeVideoPlayerMediaKit.ensureInitialized();
    debugPrint('Cross-platform MediaKit video backend initialized');
  } catch (e) {
    debugPrint('Cross-platform MediaKit initialization failed: $e');
  }

  final podcastArtworkFuture = safely(
    'Podcast card artwork',
    () => PodcastRuntime.instance.prepareCardArtwork(library: library),
  );
  final libraryFuture = safely('LibraryService', () async {
    await library.init();
    await podcastArtworkFuture;
  });
  final mediaSessionFuture = safely(
    'SystemMediaSessionService',
    () => SystemMediaSessionService.instance.initialize(
      playbackService: mediaPlaybackService,
      playlistManager: playlistManager,
    ),
  );

  unawaited(safely('BatchImportService', batch.init));
  unawaited(
    safely('TranscriptionManager', () async {
      await safely('ModelCenter', ModelCenterService.instance.initialize);
      await transcriptionManager.initialize();
    }),
  );
  unawaited(safely('OcrSubtitleManager', ocrSubtitleManager.initialize));
  unawaited(safely('BilibiliDownloadService', bilibiliService.init));
  unawaited(
    safely('Bilibili card data', () async {
      await libraryFuture;
      await bilibiliService.init();
      bilibiliService.resumePendingStreamCardData(library);
    }),
  );
  unawaited(safely('YtDlpDownloadService', ytDlpService.init));

  // Playback restoration needs the library and Android media session, but
  // neither is allowed to delay the first Flutter frame.
  await Future.wait<void>(<Future<void>>[libraryFuture, mediaSessionFuture]);
  await safely('MediaCache', () async {
    await bilibiliService.init();
    final cache = MediaCacheService.instance;
    if (cache != null) {
      await cache.initialize();
      await bilibiliService.restoreDownloadedCardLinks(library);
      await migrateBilibiliDownloadCards(library, cache, bilibiliService.tasks);
    }
  });
  onLibraryReady();
  await safely(
    'Podcasts',
    () => PodcastRuntime.instance.initialize(
      library: library,
      playlist: playlistManager,
      playback: mediaPlaybackService,
    ),
  );
  // Keeps the online playback cache under the user's cap (Bilibili settings).
  BilibiliCacheManager.install(
    BilibiliCacheManager.forApp(
      library: library,
      streaming: bilibiliService.streamingService,
      playback: mediaPlaybackService,
    ),
  );

  // Watch-only Bilibili cards: progress into the watch history, removed once
  // neither playing nor shown on a playback page (or in its episode list).
  BilibiliWatchCards.install(
    BilibiliWatchCards.forApp(
      library: library,
      playbackChanges: mediaPlaybackService,
      currentItemId: () => mediaPlaybackService.currentItem?.id,
      openPageItemIds: _openPlaybackPageItemIds,
      queueItemIds: () => playlistManager.playlist.map((item) => item.id),
      // While the mini player or a playback page is still using the temporary
      // Bilibili list, keep every row. Dropping a card that already had a
      // cover used to put a blank row back in its place.
      keptItemIds: () {
        if (playlistManager.hasManualQueue) {
          return playlistManager.playlist.map((item) => item.id);
        }
        final session = BilibiliWatchPlaylistSession.instance;
        if (session == null) return const <String>[];
        final listInUse =
            mediaPlaybackService.currentItem != null ||
            PlaybackNavigationService.instance.hasPlaybackPage;
        if (listInUse) return session.queuedItemIds();
        return session.placeholderIds();
      },
      prepareCurrentItem: (itemId) => completeAndApplyWatchCard(
        service: bilibiliService,
        library: library,
        playback: mediaPlaybackService,
        itemId: itemId,
      ),
    ),
  );

  // The temporary playlist of videos opened from the Bilibili pages. It
  // stays when the playback page closes, and is written down so the mini
  // player can come back after a restart without waiting on a playurl.
  BilibiliWatchPlaylistSession.install(
    BilibiliWatchPlaylistSession(
      list: BilibiliWatchPlaylist.instance,
      service: bilibiliService,
      library: library,
      queue: playlistManager,
      playbackChanges: mediaPlaybackService,
      currentItem: () => mediaPlaybackService.currentItem,
      persistenceFile: library.bilibiliWatchPlaylistFile,
      warmCovers: true,
    ),
  );
}

Iterable<String> _openPlaybackPageItemIds() sync* {
  yield* PlaybackNavigationService.instance.browseHistory.itemIds;
  for (final route in PlaybackNavigationService.instance.observer.routes) {
    final settings = route.settings;
    final id = settings.arguments;
    if (PlaybackNavigationService.isPlaybackRouteName(settings.name) &&
        id is String) {
      yield id;
    }
  }
}

final NavigatorObserver _watchCardsRouteObserver =
    BilibiliWatchCards.routeObserver(
      isPlaybackRoute: PlaybackNavigationService.isPlaybackRouteName,
    );

void _configureImageCaches() {
  final imageCache = PaintingBinding.instance.imageCache;
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  // Keep memory usage conservative to avoid OOM on Windows.
  // 768MB was far too aggressive for a media player that already uses
  // significant memory for video decoding.
  final targetImageEntryCount = isDesktop ? 600 : 350;
  final targetImageMemoryBytes = isDesktop
      ? 256 * 1024 * 1024
      : 128 * 1024 * 1024;
  if (imageCache.maximumSize < targetImageEntryCount) {
    imageCache.maximumSize = targetImageEntryCount;
  }
  if (imageCache.maximumSizeBytes < targetImageMemoryBytes) {
    imageCache.maximumSizeBytes = targetImageMemoryBytes;
  }

  final thumbnailCache = ThumbnailCacheService();
  final targetThumbnailEntryCount = isDesktop ? 800 : 400;
  if (thumbnailCache.maxCacheSize < targetThumbnailEntryCount) {
    thumbnailCache.setMaxCacheSize(targetThumbnailEntryCount);
  }
}

/// 崩溃日志文件路径，由 [_initCrashLogPath] 初始化。
String? _crashLogPath;

/// 初始化崩溃日志路径。
///
/// 在 [main] 早期调用，确保后续错误处理器可用。路径获取失败时静默处理，
/// 仅丢失日志能力，不影响应用启动。
Future<void> _initCrashLogPath() async {
  try {
    final dir = await resolveAppDataDirectory();
    _crashLogPath = p.join(dir.path, 'crash_log.txt');
  } catch (e) {
    debugPrint('初始化崩溃日志路径失败: $e');
  }
}

/// 将崩溃信息写入日志文件（追加模式）。
///
/// 日志文件限制为 1MB，超出时清空重写，避免无限增长。
/// 写入失败时静默处理，防止日志机制本身导致二次崩溃。
void _writeCrashLog(String message) {
  if (_crashLogPath == null) return;
  try {
    final file = File(_crashLogPath!);
    final timestamp = DateTime.now().toIso8601String();
    final entry = '[$timestamp] ${redactSensitiveLogText(message)}\n';
    // 限制日志文件大小为 1MB，超出时清空重来
    if (file.existsSync() && file.lengthSync() > 1024 * 1024) {
      file.writeAsStringSync('');
    }
    file.writeAsStringSync(entry, mode: FileMode.append, flush: true);
  } catch (e) {
    // 写入失败静默处理
    debugPrint('崩溃日志写入失败: $e');
  }
}

class RestartWidget extends StatefulWidget {
  final Widget child;

  const RestartWidget({super.key, required this.child});

  static void restartApp(BuildContext context) {
    context.findAncestorStateOfType<_RestartWidgetState>()?.restartApp();
  }

  @override
  State<RestartWidget> createState() => _RestartWidgetState();
}

class _RestartWidgetState extends State<RestartWidget> {
  Key key = UniqueKey();

  void restartApp() {
    setState(() {
      key = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(key: key, child: widget.child);
  }
}

class RefreshAppIntent extends Intent {
  const RefreshAppIntent();
}

class MyApp extends StatefulWidget {
  final BilibiliDownloadService bilibiliService;
  final TranscriptionManager transcriptionManager;

  const MyApp({
    super.key,
    required this.bilibiliService,
    required this.transcriptionManager,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final _clipboardRoutes = ClipboardDetectionRoutes();
  bool _sessionThumbnailCacheCleared = false;
  StreamSubscription<bool>? _notificationClickedSubscription;
  bool _pendingNotificationPlaybackNavigation = false;
  int? _pendingNotificationSessionGeneration;
  bool _notificationNavigationInFlight = false;

  bool _isForegroundState(AppLifecycleState? state) {
    return state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SubtitleStreamSource source = widget.transcriptionManager;
    try {
      source = context.read<SubtitleStreamSource>();
    } on ProviderNotFoundException {
      /* Standalone app tests retain ASR. */
    }
    MediaPlaybackService().bindSubtitleStreams(source);
    MediaPlaybackService().addListener(_handlePlaybackServiceChanged);
    MediaPlaybackService().handleAppLifecycleState(
      WidgetsBinding.instance.lifecycleState,
    );
    _notificationClickedSubscription = audio_service
        .AudioService
        .notificationClicked
        .listen(_handleNotificationClicked);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    MediaPlaybackService().handleAppLifecycleState(state);
    if (_isForegroundState(state) &&
        MediaPlaybackService().currentItem != null) {
      unawaited(
        SystemMediaSessionService.instance.refreshNow(
          ensureNotificationVisible: true,
        ),
      );
      if (_pendingNotificationPlaybackNavigation) {
        unawaited(_openPlaybackFromNotificationIfReady());
      }
    }
    if (state == AppLifecycleState.detached) {
      AiChatSessions.instance.shutdown();
      unawaited(CloudDriveRuntime.instance?.shutdown());
      unawaited(widget.bilibiliService.shutdown());
      unawaited(MediaCacheService.instance?.shutdown());
      unawaited(widget.transcriptionManager.shutdown());
      unawaited(_cleanupSessionThumbnailCaches());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardRoutes.dispose();
    MediaPlaybackService().removeListener(_handlePlaybackServiceChanged);
    unawaited(_notificationClickedSubscription?.cancel());
    _notificationClickedSubscription = null;
    AiChatSessions.instance.shutdown();
    unawaited(CloudDriveRuntime.instance?.shutdown());
    unawaited(widget.bilibiliService.shutdown());
    unawaited(MediaCacheService.instance?.shutdown());
    unawaited(widget.transcriptionManager.shutdown());
    unawaited(_cleanupSessionThumbnailCaches());
    super.dispose();
  }

  void _handleNotificationClicked(bool clicked) {
    if (!clicked) {
      return;
    }
    _pendingNotificationPlaybackNavigation = true;
    _pendingNotificationSessionGeneration =
        MediaPlaybackService().sessionGeneration;
    unawaited(_openPlaybackFromNotificationIfReady());
  }

  void _handlePlaybackServiceChanged() {
    if (!_pendingNotificationPlaybackNavigation) {
      return;
    }
    unawaited(_openPlaybackFromNotificationIfReady());
  }

  Future<void> _openPlaybackFromNotificationIfReady() async {
    if (!_pendingNotificationPlaybackNavigation ||
        _notificationNavigationInFlight ||
        !_isForegroundState(WidgetsBinding.instance.lifecycleState)) {
      return;
    }

    final playbackService = MediaPlaybackService();
    final currentItem = playbackService.currentItem;
    if (currentItem == null) {
      return;
    }

    final expectedGeneration = _pendingNotificationSessionGeneration;
    _pendingNotificationPlaybackNavigation = false;
    _pendingNotificationSessionGeneration = null;
    _notificationNavigationInFlight = true;
    try {
      await PlaybackNavigationService.instance
          .openCurrentPlaybackSessionFromNotification(
            playbackService,
            expectedGeneration: expectedGeneration,
          );
    } finally {
      _notificationNavigationInFlight = false;
      if (_pendingNotificationPlaybackNavigation) {
        unawaited(_openPlaybackFromNotificationIfReady());
      }
    }
  }

  Future<void> _cleanupSessionThumbnailCaches() async {
    if (_sessionThumbnailCacheCleared) {
      return;
    }
    _sessionThumbnailCacheCleared = true;
    final thumbnailCache = ThumbnailCacheService();
    thumbnailCache.clearMemoryCache();
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
  }

  @override
  Widget build(BuildContext context) {
    final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

    return RestartWidget(
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.f1, includeRepeats: false):
              const KeyboardShortcutHelpIntent(),
          const SingleActivator(
            LogicalKeyboardKey.slash,
            control: true,
            includeRepeats: false,
          ): const KeyboardShortcutHelpIntent(),
          const SingleActivator(
            LogicalKeyboardKey.slash,
            meta: true,
            includeRepeats: false,
          ): const KeyboardShortcutHelpIntent(),
          LogicalKeySet(LogicalKeyboardKey.f11): const ToggleFullScreenIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape):
              const ExitFullScreenIntent(),
          LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyR):
              const RefreshAppIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            KeyboardShortcutHelpIntent:
                CallbackAction<KeyboardShortcutHelpIntent>(
                  onInvoke: (_) {
                    invokeKeyboardShortcutHelp(
                      AppToast.navigatorKey.currentState?.overlay?.context,
                    );
                    return null;
                  },
                ),
            ToggleFullScreenIntent: CallbackAction<ToggleFullScreenIntent>(
              onInvoke: (intent) {
                if (isEditableTextFocused()) return null;
                return Provider.of<SettingsService>(
                  context,
                  listen: false,
                ).toggleFullScreen();
              },
            ),
            ExitFullScreenIntent: CallbackAction<ExitFullScreenIntent>(
              onInvoke: (intent) {
                if (isEditableTextFocused()) return null;
                final settings = Provider.of<SettingsService>(
                  context,
                  listen: false,
                );
                if (settings.isFullScreen) {
                  settings.toggleFullScreen();
                }
                return null;
              },
            ),
            RefreshAppIntent: CallbackAction<RefreshAppIntent>(
              onInvoke: (intent) {
                if (isEditableTextFocused()) return null;
                RestartWidget.restartApp(context);
                AppToast.show("正在刷新应用...", type: AppToastType.info);
                return null;
              },
            ),
          },
          child: MaterialApp(
            title: 'Fluent_Player',
            debugShowCheckedModeBanner: false,
            localizationsDelegates: appLocalizationDelegates,
            supportedLocales: appSupportedLocales,
            navigatorKey: AppToast.navigatorKey,
            navigatorObservers: [
              AppToast.observer,
              ProcessingScreenProtection.navigationObserver,
              AppToast.routeObserver,
              PlaybackNavigationService.instance.observer,
              _watchCardsRouteObserver,
              _clipboardRoutes.rootObserver,
              DebugLogNavigatorObserver(),
            ],
            builder: (context, child) {
              return ProcessingScreenProtection(
                enabled: context.watch<SettingsService>().processingScreenProtection,
                child: KeyboardShortcutHints(
                  child: MouseBackButtonListener(
                    navigatorKey: AppToast.navigatorKey,
                    child: DebugLogOverlay(
                      child: TooltipInteractionGuard(
                        child: IncomingShareListener(
                          child: AppClipboardListener(
                            navigatorKey: AppToast.navigatorKey,
                            routes: _clipboardRoutes,
                            child: FolderSyncRequestPrompt(
                              child: LibraryPersistenceNotificationBridge(
                                child: FirstOpenUiWarmupHost(
                                  child: MobileSystemNavigationBar(
                                    child: AppTextInputFocus(
                                      child: UiRefreshRateScope(
                                        child: child ?? const SizedBox.shrink(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            theme: appInteractionTheme(
              ThemeData(
                brightness: Brightness.dark,
                primarySwatch: Colors.blue,
                scaffoldBackgroundColor: const Color(0xFF121212),
                typography: Typography.material2021(
                  platform: isIOS ? TargetPlatform.iOS : defaultTargetPlatform,
                ),
                fontFamily: isIOS ? 'CupertinoSystemText' : 'MiSans',
                textTheme: appTextTheme(isIOS: isIOS),
                textButtonTheme: TextButtonThemeData(
                  style: appActionTextStyle(isIOS: isIOS),
                ),
                filledButtonTheme: FilledButtonThemeData(
                  style: appActionTextStyle(isIOS: isIOS, emphasized: true),
                ),
                elevatedButtonTheme: ElevatedButtonThemeData(
                  style: appActionTextStyle(isIOS: isIOS, emphasized: true),
                ),
                outlinedButtonTheme: OutlinedButtonThemeData(
                  style: appActionTextStyle(isIOS: isIOS),
                ),
                cupertinoOverrideTheme: isIOS
                    ? const CupertinoThemeData(brightness: Brightness.dark)
                    : null,
                colorScheme: const ColorScheme.dark(
                  primary: Colors.blue,
                  surface: Color(0xFF121212),
                ),
                useMaterial3: true,
                pageTransitionsTheme: appPageTransitionsTheme,
                tooltipTheme: const TooltipThemeData(
                  waitDuration: kAppTooltipWaitDuration,
                ),
                appBarTheme: const AppBarTheme(
                  backgroundColor: Color(0xFF1E1E1E),
                  elevation: 0,
                  systemOverlayStyle: MobileSystemNavigationBar.overlayStyle,
                ),
              ),
            ),
            onGenerateRoute: (settings) {
              if (settings.name != Navigator.defaultRouteName) return null;
              return buildMediaLibraryShellRoute<void>(
                settings: settings,
                home: const HomeScreen(),
              );
            },
          ),
        ),
      ),
    );
  }
}

class ExitFullScreenIntent extends Intent {
  const ExitFullScreenIntent();
}

class ToggleFullScreenIntent extends Intent {
  const ToggleFullScreenIntent();
}

/// 恢复上次的播放状态
Future<void> _restorePlaybackState({
  required MediaPlaybackService mediaPlaybackService,
  required PlaylistManager playlistManager,
  required LibraryService library,
  required PlaybackRestorePreview? preview,
  required Future<void> integrationsReady,
}) async {
  try {
    if (preview == null) return;
    await integrationsReady;
    // Tapping play, stopping, selecting other media or editing the queue while
    // integrations loaded must take precedence over background restoration.
    if (!preview.isCurrent(mediaPlaybackService, playlistManager)) return;
    final videoItem = preview.item;
    final snapshot = preview.snapshot;
    final previewGeneration = preview.generation;
    final position = mediaPlaybackService.position;

    // 恢复播放列表。一次性 B 站视频不在任何文件夹里，上次如果播的是
    // 它的临时列表，就按那份列表恢复，而不是媒体库根目录。
    final watchSession = BilibiliWatchPlaylistSession.instance;
    final restoredManualQueue = playlistManager.hasManualQueue;
    var restoredWatchQueue = false;
    if (!restoredManualQueue &&
        watchSession != null &&
        watchSession.shouldRestoreWatchQueue(videoItem)) {
      restoredWatchQueue = await watchSession.restoreWatchQueue(videoItem);
    }
    var restoredPodcastQueue = false;
    if (!restoredManualQueue &&
        !restoredWatchQueue &&
        PodcastRuntime.instance.ready) {
      restoredPodcastQueue = await PodcastRuntime.instance.restoreSavedQueue(
        expectedMediaId: videoItem.id,
      );
    }
    if (mediaPlaybackService.sessionGeneration != previewGeneration) return;
    if (!restoredManualQueue && !restoredWatchQueue && !restoredPodcastQueue) {
      if (videoItem.isTransient) {
        playlistManager.setPlaylist([videoItem], currentItemId: videoItem.id);
      } else if (snapshot.playlistFolderId != null) {
        playlistManager.loadFolderPlaylist(
          snapshot.playlistFolderId,
          snapshot.currentItemId!,
        );
      } else {
        // 如果没有文件夹ID，使用媒体项的父文件夹
        playlistManager.loadFolderPlaylist(
          videoItem.parentId,
          snapshot.currentItemId!,
        );
      }
    }

    if (MediaPlaybackService.shouldPrepareNativePlayerOnRestore(videoItem)) {
      // Local files can warm a paused controller before Mini chrome is useful.
      await mediaPlaybackService.play(
        videoItem,
        startPosition: position,
        autoPlay: false,
        keepBookmarkOnFailure: true,
      );
    } else {
      // Bilibili may warm opportunistically; other remote sources keep their
      // offline bookmark until the user opens or plays it. Prepare the paused
      // player at the saved position without blocking startup. Opening the
      // card then mounts that player instead of waiting on a cold playurl.
      unawaited(
        mediaPlaybackService.warmRestoredOnlinePlayback(videoItem, position),
      );
    }
    await SystemMediaSessionService.instance.refreshNow(
      ensureNotificationVisible: true,
    );

    debugPrint('成功恢复播放状态: ${videoItem.title} at ${position.inSeconds}s');
  } catch (e) {
    debugPrint('恢复播放状态失败: $e');
    // Queue/notification failures must not discard a valid offline bookmark
    // or cancel media the user selected while restoration was running.
    // 静默处理错误，不影响应用启动
  } finally {
    // The retained watch-only card is the current item now, or there was
    // nothing to restore. Either way the janitor may sweep the rest.
    library.releaseLaunchRetainedTransients();
    BilibiliWatchCards.instance?.janitor.scheduleSweep();
  }
}
