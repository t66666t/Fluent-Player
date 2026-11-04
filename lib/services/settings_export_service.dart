import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import '../features/ai_chat/ai_chat_settings.dart';
import '../features/ai_chat/ai_chat_typography.dart';
import '../features/ai_chat/ai_quick_prompts.dart';
import '../features/cloud_drive/services/cloud_drive_view_preferences.dart';
import '../features/douyin_download/douyin_download_preferences.dart';
import '../features/media_cache/media_cache_models.dart';
import '../features/media_cache/media_cache_service.dart';
import '../features/model_center/asr_acceleration.dart';
import '../features/model_center/asr_enhancement_options.dart';
import '../features/model_center/model_catalog.dart';
import '../features/model_center/model_center_service.dart';
import '../features/model_center/subtitle_segmentation.dart';
import '../features/podcasts/podcast_runtime.dart';
import '../features/podcasts/podcast_settings.dart';
import '../features/portable_transfer/portable_export_settings_memory.dart';
import '../features/web_media/web_media_browser_preferences.dart';
import '../features/web_media/web_media_queue_settings.dart';
import '../features/youtube_download/models/youtube_download_models.dart';
import '../features/youtube_download/services/yt_dlp_download_service.dart';
import '../models/subtitle_punctuation.dart';
import '../utils/serial_task_queue.dart';
import 'ai_subtitle_translator.dart';
import 'app_storage_service.dart';
import 'bilibili/bilibili_download_service.dart';
import 'network/network_models.dart';
import 'network/network_settings_service.dart';
import 'settings_service.dart';
import 'sleep_timer_controller.dart';
import 'subtitle_manual_translation_settings.dart';
import 'subtitle_translate_settings.dart';
import 'transcription_hotword_store.dart';

typedef SettingsRecordReader = Future<Map<String, dynamic>> Function();

/// A portable initial-preference snapshot, never a user-data/account backup.
/// Read dormant stores without initializing downloaders, models or podcasts:
/// exporting must not start a queue, contact a server or request notification
/// permissions. Missing stores use their owning model's defaults; unreadable
/// stores fail the export instead of silently producing an incomplete file.
class SettingsExportService {
  SettingsExportService({
    Future<SharedPreferences> Function()? preferences,
    SettingsRecordReader? modelPreferences,
    SettingsRecordReader? podcastPreferences,
    SettingsRecordReader? mediaCachePreferences,
    Future<NetworkConfiguration> Function()? networkPreferences,
    Future<DownloadSessionConfig?> Function()? nativeYtDlpPreferences,
  }) : _preferences = preferences ?? SharedPreferences.getInstance,
       _modelPreferences = modelPreferences ?? _readModelPreferences,
       _podcastPreferences = podcastPreferences ?? _readPodcastPreferences,
       _mediaCachePreferences =
           mediaCachePreferences ?? _readMediaCachePreferences,
       _networkPreferences = networkPreferences ?? _readNetworkPreferences,
       _nativeYtDlpPreferences = nativeYtDlpPreferences ?? (() async => null);

  static const schemaVersion = 2;
  static const fileName = 'video_player_settings_export.json';
  static final _fileWrites = SerialTaskQueue();
  final Future<SharedPreferences> Function() _preferences;
  final SettingsRecordReader _modelPreferences, _podcastPreferences;
  final SettingsRecordReader _mediaCachePreferences;
  final Future<NetworkConfiguration> Function() _networkPreferences;
  final Future<DownloadSessionConfig?> Function() _nativeYtDlpPreferences;

  static const aiChatPreferenceKeys = <String>{
    'contextTokens',
    'contextMode',
    'fastSummaries',
    'maxOutputTokens',
    'optimizeTokens',
    'autoCompact',
    'temperature',
    'systemPrompt',
    'titlePrompt',
    'cliPrompt',
    'transcriptPrompt',
    'thinkingEnabled',
    'reasoningEffort',
    'thinkingBudget',
  };

  /// Explicit decisions for mixed stores; also checked against their schemas.
  static const aiChatExcludedKeys = <String>{
    'version',
    'backend',
    'apiProtocol',
    'baseUrl',
    'model',
    'executablePath',
    'savedModels',
    'modelCatalogBaseUrl',
    'modelCatalogProtocol',
    'developerMode',
    'cliProfiles',
    'apiModel',
    'apiReasoningEffort',
    'apiProfileId',
    'apiProfiles',
  };
  static const ytDlpSessionPreferenceKeys = <String>{
    'singleVideo',
    'useCustomUserAgent',
    'userAgent',
    'socketTimeoutSeconds',
    'retries',
    'fragmentRetries',
    'concurrentFragments',
    'rateLimit',
    'forceIpv4',
    'enabledPlayerClients',
  };
  static const ytDlpSessionExcludedKeys = <String>{
    'referer',
    'useCookies',
    'cookiesFilePath',
    'useProxy',
    'proxy',
    'poTokens',
    'visitorData',
    'debugLoggingEnabled',
    'outputDirectory',
  };
  static const modelPreferenceKeys = <String>{
    'sourcePreference',
    'ocrSourcePreference',
    'language',
    'asrLanguagePreferences',
    'threads',
    'asrCpuThreads',
    'asrExecution',
    'asrEnhancements',
    'parakeetJapaneseDenoise',
    'subtitlePunctuation',
    'asrAccelerationOptions',
    'translationOptions',
    'translationModelOptions',
    'subtitleSegmentation',
  };
  static const modelExcludedKeys = <String>{
    'ocrLegacyMigrationComplete',
    'ocrPerformance',
    'version',
    'asrProfileId',
    'translationModelId',
    'inferenceTuning',
    'asrPerformance',
    'translationPerformance',
    'tab',
    'search',
    'filter',
    'selectedModelId',
    'scrollPositions',
    'expandedPerformanceSections',
    'profiles',
    'downloads',
    'diagnostics',
  };

  Future<Map<String, dynamic>> buildSnapshot({
    required SettingsService settings,
    Size? viewportSize,
    double? devicePixelRatio,
    BilibiliDownloadService? bilibili,
    YtDlpDownloadService? ytDlp,
    SubtitleTranslateSettings? translation,
    SleepTimerController? sleepTimer,
    WebMediaQueueSettings? webQueueSettings,
    AiChatReadingSettings? readingSettings,
    SettingsRecordReader? syncPreferences,
  }) async {
    // Freeze runtime values before yielding to disk. In-memory changes can be
    // newer than queued preference writes when a settings sheet just closed.
    final core = _copy(
      settings.exportSettingsSnapshot(viewportSize: viewportSize),
    );
    final liveBilibili = bilibili?.settingsLoaded == true
        ? <String, dynamic>{
            'maxConcurrentDownloads': bilibili!.maxConcurrentDownloads,
            'maxConnectionsPerVideo': bilibili.maxConnectionsPerVideo,
            'preferredQuality': bilibili.preferredQuality,
            'preferredAudioQuality': bilibili.preferredAudioQuality.name,
            'preferredSubtitleLang': bilibili.preferredSubtitleLang,
            'preferAiSubtitles': bilibili.preferAiSubtitles,
            'downloadDanmaku': bilibili.downloadDanmaku,
            'autoDeleteTaskAfterImport': bilibili.autoDeleteTaskAfterImport,
            'autoDeleteOnlineTaskAfterImport':
                bilibili.autoDeleteOnlineTaskAfterImport,
            'keepScreenAwakeDuringProcessing':
                bilibili.keepScreenAwakeDuringProcessing,
          }
        : null;
    final liveYtDlp = ytDlp?.isInitialized == true
        ? _copy({
            'preferences': ytDlp!.downloadPreferences.toJson(),
            'session': _pick(
              ytDlp.sessionConfig.toJson(),
              ytDlpSessionPreferenceKeys,
            ),
            'keepScreenAwakeDuringProcessing':
                ytDlp.keepScreenAwakeDuringProcessing,
          })
        : null;
    final liveTranslation = translation?.exportSettingsSnapshot();
    final liveSleep = sleepTimer == null
        ? null
        : {
            'countOnlyWhilePlaying': sleepTimer.countOnlyWhilePlaying,
            'customMinutes': sleepTimer.customMinutes,
            'customItemCount': sleepTimer.customItemCount,
          };
    final prefs = await _preferences();
    if (readingSettings != null) await readingSettings.load();
    final liveReadingScale = readingSettings?.value;
    final model = await _modelPreferences();
    final podcasts = await _podcastPreferences();
    final mediaCache = await _mediaCachePreferences();
    final network = await _networkPreferences();
    final sync = syncPreferences == null
        ? {'enabled': false}
        : await syncPreferences();
    final ai = AiChatSettings.fromJson(
      _jsonPreference(prefs, AiChatSettingsStore.preferencesKey),
    );
    final browser = _jsonPreference(
      prefs,
      WebMediaBrowserPreferences.storageKey,
    );
    final cloud = CloudDriveViewPreferences(prefs);
    final sessionRaw = _jsonPreference(prefs, 'yt_dlp_session_config_v1');
    // Preserve dormant, non-secret preferences as data. Exporting local settings
    // must not initialize, normalize through, or call a disabled downloader.
    // Defaults only fill fields absent from a never-opened preference record.
    final nativeSession = liveYtDlp == null && sessionRaw.isEmpty
        ? await _nativeYtDlpPreferences()
        : null;
    final session =
        nativeSession ??
        DownloadSessionConfig.fromJson({
          ...DownloadSessionConfig.defaults().toJson(),
          ...sessionRaw,
        });
    final languageProfiles = _jsonPreference(
      prefs,
      SubtitleTranslateSettings.languageProfilesKey,
    );
    final translate =
        liveTranslation ??
        {
          'direction': TranscriptTranslateDirection.fromStorage(
            prefs.getString(SubtitleTranslateSettings.directionKey),
          ).name,
          'languageProfiles': {
            'bing': const SubtitleTranslationPair().toJson(),
            for (final entry in languageProfiles.entries)
              entry.key: SubtitleTranslationPair.fromJson(
                entry.value as Map,
              ).toJson(),
          },
          'aiOptions': AiSubtitleTranslationSettings.fromJson(
            _jsonPreference(
              prefs,
              AiSubtitleTranslationSettings.preferencesKey,
            ),
          ).toJson(),
        };
    final readingScale =
        liveReadingScale ?? prefs.get(AiChatReadingSettings.preferenceKey);
    final result = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'exportKind': 'initialPreferences',
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'sourceDevice': {
        'platform': defaultTargetPlatform.name,
        if (viewportSize != null) ...{
          'logicalWidth': viewportSize.width,
          'logicalHeight': viewportSize.height,
        },
        'devicePixelRatio': ?devicePixelRatio,
      },
      'settings': core,
      'bilibili': {
        ...?liveBilibili,
        if (liveBilibili == null) ...{
          'maxConcurrentDownloads':
              prefs.getInt('bilibili_max_concurrent') ?? 1,
          'maxConnectionsPerVideo':
              prefs.getInt('bilibili_connections_per_video') ?? 2,
          'preferredQuality': prefs.getInt('bilibili_preferred_quality') ?? 116,
          'preferredAudioQuality':
              prefs.getString('bilibili_preferred_audio_quality') ??
              'bestAvailable',
          'preferredSubtitleLang':
              prefs.getString('bilibili_preferred_subtitle_lang') ?? 'zh',
          'preferAiSubtitles':
              prefs.getBool('bilibili_prefer_ai_subtitles') ?? false,
          'downloadDanmaku': prefs.getBool('bilibili_download_danmaku') ?? true,
          'autoDeleteTaskAfterImport':
              prefs.getBool('bilibili_auto_delete_import') ?? false,
          'autoDeleteOnlineTaskAfterImport':
              prefs.getBool('bilibili_online_auto_delete_import') ?? false,
          'keepScreenAwakeDuringProcessing':
              prefs.getBool('bilibili_keep_screen_awake_during_processing') ??
              false,
        },
        'streamPreferredQuality': prefs.getInt(
          'bilibili_stream_preferred_quality',
        ),
        'streamPreferredAudio': prefs.getInt('bilibili_stream_preferred_audio'),
      },
      'ytDlp': {
        ...?liveYtDlp,
        if (liveYtDlp == null) ...{
          'preferences': YtDlpDownloadPreferences.fromJson(
            _jsonPreference(prefs, 'yt_dlp_download_preferences_v1'),
          ).toJson(),
          'session': _pick(session.toJson(), ytDlpSessionPreferenceKeys),
          'keepScreenAwakeDuringProcessing':
              prefs.getBool('yt_dlp_keep_screen_awake_during_processing') ??
              false,
        },
        'outputContainer':
            prefs.getString('yt_dlp_last_output_container') ?? 'mp4',
        'audioOnly': prefs.getBool('yt_dlp_last_audio_only') ?? false,
      },
      'webMedia': {
        'queue':
            (webQueueSettings ??
                    WebMediaQueueSettings.decode(
                      prefs.getString('web_media_queue_settings_v2'),
                      legacyConnections: prefs.getInt('web_media_connections'),
                    ))
                .toJson(),
        'browser': {
          'desktopMode': browser['desktopMode'] is bool
              ? browser['desktopMode']
              : WebMediaBrowserPreferences.defaultDesktopMode,
        },
      },
      'mediaCache': MediaCachePreferences.fromJson(mediaCache).toJson(),
      'douyin': {
        'manualCaptureMode':
            prefs.getBool(DouyinDownloadPreferences.manualModeKey) ?? false,
        'autoRemoveAfterImport':
            prefs.getBool(DouyinDownloadPreferences.autoRemoveAfterImportKey) ??
            false,
      },
      'cloudDrive': {
        'lastProvider': cloud.providerId,
        'views': {
          for (final provider in const ['baidu', 'quark', 'uc', 'aliyun'])
            provider: cloud.options(provider).toJson(),
        },
      },
      'translation': {
        ...translate,
        'manual': {
          'enabled':
              prefs.getBool(SubtitleManualTranslationSettings.enabledKey) ??
              false,
          'subtitleFirst':
              prefs.getBool(
                SubtitleManualTranslationSettings.subtitleFirstKey,
              ) ??
              true,
          'prompt':
              prefs.getString(SubtitleManualTranslationSettings.promptKey) ??
              SubtitleManualTranslationSettings.defaultPrompt,
        },
      },
      'modelProcessing': _modelSnapshot(model),
      'transcriptionHotwords': {
        'presets': TranscriptionHotwordStore.decodePresets(
          prefs.getString(TranscriptionHotwordStore.presetsKey),
        ).map((entry) => entry.toJson()).toList(),
      },
      'aiChat': {
        ..._pick(ai.toJson(), aiChatPreferenceKeys),
        'quickPrompts': AiQuickPromptStore.decode(
          prefs.getString(AiQuickPromptStore.preferenceKey),
        ).map((entry) => entry.toJson()).toList(),
        'readingScale': AiChatReadingSettings.normalize(
          readingScale is num ? readingScale.toDouble() : 1,
        ),
      },
      'podcasts': {
        'preferences': PodcastPreferences(podcasts).values,
        // In particular, absence of speed/continuous means "follow software".
        // Preserve that distinction from an explicit 1x/false override.
        'explicitOverrides': {
          for (final definition in podcastSettings)
            if (podcasts.containsKey(definition.key))
              definition.key: definition.normalize(podcasts[definition.key]),
        },
      },
      'portableExport': {
        'fluentPack': PortableExportRememberedSettings.fromJson(
          _jsonPreference(prefs, PortableExportSettingsMemory.fluentPackKey),
        ).toJson(),
        'zip': PortableExportRememberedSettings.fromJson(
          _jsonPreference(prefs, PortableExportSettingsMemory.zipKey),
        ).toJson(),
      },
      'sleepTimer':
          liveSleep ??
          {
            'countOnlyWhilePlaying':
                prefs.getBool('sleepTimer.countOnlyWhilePlaying') ?? false,
            'customMinutes': (prefs.getInt('sleepTimer.customMinutes') ?? 30)
                .clamp(1, 1440),
            'customItemCount': (prefs.getInt('sleepTimer.customItemCount') ?? 3)
                .clamp(
                  SleepTimerController.minCustomItemCount,
                  SleepTimerController.maxCustomItemCount,
                ),
          },
      'network': {
        'unifiedMode': network.unifiedMode?.name,
        'featureModes': {
          for (final entry in network.featureModes.entries)
            entry.key.name: entry.value.name,
        },
      },
      'progressSync': {'enabled': sync['enabled'] == true},
      'excluded': {
        'core': SettingsService.settingsExportExclusions,
        'categories': [
          '账号、Cookie、Token、API Key、接口地址与模型选择',
          '本机路径、代理服务器与认证、导入目标文件夹 ID',
          '单个媒体/播客频道/文件夹的覆盖设置、字幕语言标注与播放记录',
          '浏览器快捷网址、访问历史、恢复页面与字幕搜索草稿',
          '同步配对、设备身份、WebDAV 连接、任务队列与缓存',
          '运行中的睡眠定时器、窗口状态、调试开关与本机性能测量',
        ],
      },
    };
    return _copy(result);
  }

  /// Serialize before touching the old file; replace it only after a flushed,
  /// complete write. The shared queue also handles repeated button presses.
  Future<File> writeSnapshot(
    Map<String, dynamic> snapshot, {
    Directory? directory,
  }) {
    final encoded = const JsonEncoder.withIndent('  ').convert(snapshot);
    return _fileWrites.enqueue(() async {
      final target = directory ?? await _exportDirectory();
      await target.create(recursive: true);
      final file = File(p.join(target.path, fileName));
      final temporary = File('${file.path}.tmp');
      try {
        await temporary.writeAsString(encoded, flush: true);
        return await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  static Map<String, dynamic> _pick(
    Map<String, dynamic> value,
    Set<String> keys,
  ) => {for (final key in keys) key: value[key]};
  static Map<String, dynamic> _jsonPreference(
    SharedPreferences prefs,
    String key,
  ) {
    final raw = prefs.getString(key);
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw FormatException('无法完整导出设置：$key');
    return Map<String, dynamic>.from(decoded);
  }

  static Map<String, dynamic> _modelSnapshot(Map<String, dynamic> raw) => {
    'sourcePreference': raw['sourcePreference'] ?? 'auto',
    'ocrSourcePreference': raw['ocrSourcePreference'] ?? 'auto',
    'language': raw['language'] ?? 'auto',
    if (raw['asrLanguagePreferences'] is Map &&
        (raw['asrLanguagePreferences'] as Map).isNotEmpty)
      'asrLanguagePreferences': {
        for (final entry in (raw['asrLanguagePreferences'] as Map).entries)
          if (entry.key is String && entry.value is String)
            entry.key as String: entry.value,
      },
    'threads': raw['threads'] ?? 2,
    'asrCpuThreads':
        raw['asrCpuThreads'] ??
        ((raw['threads'] ?? 2) == 2 ? 0 : raw['threads']),
    'asrExecution': raw['asrExecution'] ?? AsrExecutionMode.auto.name,
    'asrEnhancements': AsrEnhancementOptions.fromJson(
      raw['asrEnhancements'],
    ).toJson(),
    if (raw['parakeetJapaneseDenoise'] == true) 'parakeetJapaneseDenoise': true,
    'subtitlePunctuation': SubtitlePunctuation.fromStorage(
      raw['subtitlePunctuation'],
    ).name,
    'asrAccelerationOptions': {
      for (final entry in (raw['asrAccelerationOptions'] as Map? ?? {}).entries)
        entry.key as String: AsrAcceleration.values
            .firstWhere(
              (v) => v.name == entry.value,
              orElse: () => AsrAcceleration.auto,
            )
            .name,
    },
    'translationOptions': _translationOptionsSnapshot(
      raw['translationOptions'],
    ),
    'translationModelOptions': {
      for (final entry
          in (raw['translationModelOptions'] as Map? ?? {}).entries)
        entry.key as String: _translationOptionsSnapshot(entry.value),
    },
    'subtitleSegmentation': SubtitleSegmentationOptions.fromJson(
      raw['subtitleSegmentation'],
      migrateDefaults: true,
    ).toJson(),
  };

  static Map<String, dynamic> _translationOptionsSnapshot(Object? raw) {
    final options = LocalTranslationOptions.fromJson(
      Map<String, dynamic>.from(raw as Map? ?? {}),
    );
    // Persistence omits this field at its default, but an initial-settings
    // snapshot should make even the "all layers" choice explicit.
    return {...options.toJson(), 'gpuLayers': options.gpuLayers};
  }

  static Future<Map<String, dynamic>> _readModelPreferences() async {
    final center = ModelCenterService.instance;
    if (center.loaded) {
      return _copy({
        'sourcePreference': center.sourcePreference,
        'ocrSourcePreference': center.ocrSourcePreference,
        'language': center.selectedLanguage,
        if (center.asrLanguagePreferences.isNotEmpty)
          'asrLanguagePreferences': Map<String, String>.of(
            center.asrLanguagePreferences,
          ),
        'threads': center.threads,
        'asrCpuThreads': center.asrCpuThreads,
        'asrExecution': center.asrExecution.name,
        'asrEnhancements': center.asrEnhancements.toJson(),
        if (center.parakeetJapaneseDenoise) 'parakeetJapaneseDenoise': true,
        'subtitlePunctuation': center.subtitlePunctuation.name,
        'asrAccelerationOptions': {
          for (final entry in center.asrAccelerationOptions.entries)
            entry.key: entry.value.name,
        },
        'translationOptions': center.defaultTranslationOptions.toJson(),
        'translationModelOptions': {
          for (final entry in center.translationModelOptions.entries)
            entry.key: entry.value.toJson(),
        },
        'subtitleSegmentation': center.subtitleSegmentation.toJson(),
      });
    }
    final raw = await readStorageJson(
      await AppStorageService.instance.dataRecord('model_center.json'),
    );
    if (raw == null) return {};
    if (raw is! Map) throw const FormatException('模型处理设置无法读取');
    return Map<String, dynamic>.from(raw);
  }

  static Future<Map<String, dynamic>> _readPodcastPreferences() async {
    final runtime = PodcastRuntime.instance;
    if (runtime.ready) return runtime.store.read('settings', 'global') ?? {};
    final directory = await AppStorageService.instance.featureDirectory(
      'podcasts',
      marker: 'podcasts.sqlite',
    );
    final file = File(p.join(directory.path, 'podcasts.sqlite'));
    if (!await file.exists()) return {};
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      final rows = db.select(
        'SELECT payload FROM records WHERE kind=? AND id=?',
        ['settings', 'global'],
      );
      return rows.isEmpty
          ? {}
          : Map<String, dynamic>.from(
              jsonDecode(rows.first['payload'] as String) as Map,
            );
    } finally {
      db.dispose();
    }
  }

  static Future<NetworkConfiguration> _readNetworkPreferences() async {
    final service = NetworkSettingsService.instance;
    return service.isLoaded
        ? service.configuration
        : await service.store.read() ?? NetworkConfiguration();
  }

  static Future<Map<String, dynamic>> _readMediaCachePreferences() async {
    final service = MediaCacheService.instance;
    if (service?.ready == true) return _copy(service!.preferences.toJson());
    final file =
        service?.journal ??
        await AppStorageService.instance.dataRecord(
          MediaCacheService.journalName,
        );
    final raw = await readStorageJson(file);
    if (raw == null) return {};
    if (raw is! Map || raw['version'] != 1) {
      throw const FormatException('缓存设置无法完整读取');
    }
    return Map<String, dynamic>.from(raw['preferences'] as Map? ?? {});
  }

  static Future<Directory> _exportDirectory() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    }
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      if (external != null) return external;
    }
    return getApplicationDocumentsDirectory();
  }
}
