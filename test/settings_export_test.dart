import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_typography.dart';
import 'package:video_player_app/features/ai_chat/ai_quick_prompts.dart';
import 'package:video_player_app/features/model_center/asr_enhancement_options.dart';
import 'package:video_player_app/features/model_center/model_catalog.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/model_center/subtitle_segmentation.dart';
import 'package:video_player_app/features/podcasts/podcast_settings.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_settings_memory.dart';
import 'package:video_player_app/features/web_media/web_media_browser_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_queue_settings.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/models/subtitle_debug_preset.dart';
import 'package:video_player_app/models/subtitle_style.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/network/network_models.dart';
import 'package:video_player_app/services/settings_export_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'package:video_player_app/services/subtitle_manual_translation_settings.dart';
import 'package:video_player_app/services/subtitle_file_processing_settings.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/services/subtitle_translate_settings.dart';
import 'package:video_player_app/services/transcription_hotword_store.dart';

SettingsExportService _exporter({
  Map<String, dynamic> model = const {},
  Map<String, dynamic> podcasts = const {},
  Map<String, dynamic> mediaCache = const {},
  NetworkConfiguration? network,
  SettingsRecordReader? modelReader,
  Future<DownloadSessionConfig?> Function()? nativeYtDlpReader,
}) => SettingsExportService(
  modelPreferences: modelReader ?? () async => model,
  podcastPreferences: () async => podcasts,
  mediaCachePreferences: () async => mediaCache,
  networkPreferences: () async => network ?? NetworkConfiguration(),
  nativeYtDlpPreferences: nativeYtDlpReader ?? () async => null,
);

// Model a loaded legacy preferences object without reactivating its downloader.
class _LoadedBilibiliPreferences extends BilibiliDownloadService {
  @override
  bool get settingsLoaded => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService settings;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SubtitleDebugSession.instance.resetForTest();
    settings = SettingsService()..resetForTest();
    settings.subtitlePresets = [];
  });

  test(
    'download export keeps independent cleanup choices and omits retired switches',
    () async {
      SharedPreferences.setMockInitialValues({
        'bilibili_auto_import': false,
        'bilibili_sequential_export': true,
        'bilibili_auto_delete_import': true,
        'bilibili_online_auto_delete_import': false,
        'douyin_auto_remove_after_import': true,
        'web_media_queue_settings_v2': jsonEncode({
          'autoRemoveAfterImport': true,
        }),
        'yt_dlp_download_preferences_v1': jsonEncode({
          'autoImportToLibrary': false,
          'autoDeleteTaskAfterImport': true,
        }),
      });
      await settings.init();
      final snapshot = await _exporter().buildSnapshot(settings: settings);
      final bilibili = snapshot['bilibili'] as Map;
      expect(bilibili['autoDeleteTaskAfterImport'], isTrue);
      expect(bilibili['autoDeleteOnlineTaskAfterImport'], isFalse);
      expect(bilibili, isNot(contains('autoImportToLibrary')));
      expect(bilibili, isNot(contains('sequentialExport')));
      expect(snapshot['douyin']['autoRemoveAfterImport'], isTrue);
      expect(snapshot['webMedia']['queue']['autoRemoveAfterImport'], isTrue);
      final yt = snapshot['ytDlp']['preferences'] as Map;
      expect(yt['autoDeleteTaskAfterImport'], isTrue);
      expect(yt, isNot(contains('autoImportToLibrary')));
    },
  );

  test('file-processing export preserves explicit false and does not migrate on read', () async {
    await settings.init();
    await const SubtitleOptimizationSettings(enabled: true).save();
    final prefs = await SharedPreferences.getInstance();
    final legacy = await _exporter().buildSnapshot(settings: settings);
    expect(legacy['subtitleFileProcessing'], {'optimize': true, 'translate': true});
    expect(prefs.containsKey(SubtitleFileProcessingSettings.preferencesKey), isFalse);
    await SubtitleFileProcessingSettings.update(optimize: false, translate: false);
    final snapshot = await _exporter().buildSnapshot(settings: settings);
    expect(snapshot['subtitleFileProcessing'], {'optimize': false, 'translate': false});
    expect(snapshot['subtitleOptimization']['enabled'], isTrue);
  });

  test(
    'fresh settings export all domains without opening their pages',
    () async {
      await settings.init();
      final snapshot = await _exporter().buildSnapshot(
        settings: settings,
        viewportSize: const Size(390, 844),
        devicePixelRatio: 3,
      );
      expect(snapshot['schemaVersion'], 2);
      expect(
        snapshot.keys,
        containsAll([
          'settings',
          'bilibili',
          'ytDlp',
          'webMedia',
          'mediaCache',
          'douyin',
          'cloudDrive',
          'translation',
          'modelProcessing',
          'subtitleOptimization',
          'aiChat',
          'podcasts',
          'portableExport',
          'sleepTimer',
          'network',
          'progressSync',
        ]),
      );
      expect(snapshot['sourceDevice']['logicalWidth'], 390);
      expect(snapshot['sourceDevice']['devicePixelRatio'], 3);
      expect(snapshot['bilibili']['maxConnectionsPerVideo'], 2);
      expect(snapshot['bilibili']['downloadDanmaku'], true);
      expect(snapshot['subtitleOptimization'], {
        'enabled': false,
        'prompt': defaultSubtitleOptimizationPrompt,
      });
      expect(snapshot['mediaCache'], MediaCachePreferences().toJson());
      expect(
        snapshot['ytDlp']['preferences'],
        YtDlpDownloadPreferences.defaults().toJson(),
      );
      expect(snapshot['ytDlp']['session']['concurrentFragments'], 16);
      expect(snapshot['ytDlp']['session']['retries'], 2);
      expect(
        snapshot['webMedia']['queue'],
        const WebMediaQueueSettings().toJson(),
      );
      expect(snapshot['webMedia']['browser']['desktopMode'], isTrue);
      expect(
        snapshot['portableExport']['zip'],
        const PortableExportRememberedSettings().toJson(),
      );
      expect(
        snapshot['modelProcessing']['asrEnhancements'],
        AsrEnhancementOptions.recommended.toJson(),
      );
      expect(
        snapshot['modelProcessing']['subtitleSegmentation'],
        SubtitleSegmentationOptions.natural.toJson(),
      );
      expect(
        snapshot['translation']['manual']['prompt'],
        SubtitleManualTranslationSettings.defaultPrompt,
      );
      expect(
        snapshot['podcasts']['preferences'].keys.toSet(),
        podcastSettings.map((s) => s.key).toSet(),
      );
      expect(snapshot['podcasts']['explicitOverrides'], isEmpty);
      expect(
        snapshot['network']['featureModes'].length,
        NetworkScope.values.length,
      );
      final slots =
          snapshot['settings']['layout']['mediaLibraryOrientationOverrides']
              as Map;
      expect(
        slots.length,
        SettingsService.mediaLibraryLayoutExportKeys.length,
        reason:
            'Each orientation slot (grid, legacy list, rows, table) must export.',
      );
      expect(slots.values.every((v) => v == null), isTrue);
      expect(
        snapshot['settings']['layout']['effectiveMediaLibraryProfiles'].keys,
        containsAll(['portrait', 'landscape']),
      );
      expect(() => jsonEncode(snapshot), returnsNormally);
    },
  );

  test(
    'named hotword presets export without any video-specific words or identity',
    () async {
      final words = TranscriptionHotwordStore();
      await words.setWords('id:private-video', '只属于这个视频的姓名');
      await words.savePreset(name: '医学', words: '心房颤动\n电生理');
      await settings.init();
      final snapshot = await _exporter().buildSnapshot(
        settings: settings,
        viewportSize: const Size(390, 844),
        devicePixelRatio: 3,
      );
      final preset =
          ((snapshot['transcriptionHotwords'] as Map)['presets'] as List).single
              as Map;
      expect(preset['name'], '医学');
      expect(preset['words'], '心房颤动\n电生理');
      expect(jsonEncode(snapshot), isNot(contains('private-video')));
      expect(jsonEncode(snapshot), isNot(contains('只属于这个视频的姓名')));
    },
  );

  test(
    'shared quick prompts export full text, names, ordering and empty libraries',
    () async {
      final store = AiQuickPromptStore();
      addTearDown(store.dispose);
      await store.replace(const [
        AiQuickPrompt(id: 'notes', name: '我的笔记', text: '第一段\n\n第二段\n'),
        AiQuickPrompt(id: 'summary', name: '概括', text: '总结{{媒体}}'),
      ]);
      await settings.init();
      final snapshot = await _exporter().buildSnapshot(settings: settings);
      expect(
        snapshot['aiChat']['quickPrompts'],
        store.entries.map((e) => e.toJson()).toList(),
      );
      await store.replace([]);
      final empty = await _exporter().buildSnapshot(settings: settings);
      expect(empty['aiChat']['quickPrompts'], isEmpty);
    },
  );

  test(
    'ordinary, ghost and audio layouts retain every size and position',
    () async {
      await settings.init();
      const normal = SubtitleLayoutStyle(
        fontSize: 44,
        secondaryFontSize: 23,
        overallScale: 1.23,
        lineSpacing: .4,
        letterSpacing: 1.7,
      );
      const ghost = SubtitleLayoutStyle(
        fontSize: 51,
        secondaryFontSize: 29,
        overallScale: .83,
        lineSpacing: .9,
        letterSpacing: 2.3,
      );
      const audio = SubtitleLayoutStyle(
        fontSize: 37,
        secondaryFontSize: 19,
        overallScale: 1.45,
        lineSpacing: .6,
        letterSpacing: 3.2,
      );
      const text = SubtitleTextStyle(
        defaultFontFamily: 'Inter',
        defaultFontWeight: 700,
        textColor: Colors.orange,
        backgroundEnabled: false,
        borderWidth: 3.4,
        shadowOffset: Offset(1.2, 3.5),
      );
      await settings.saveSubtitleLayoutLandscape(normal);
      await settings.saveSubtitleLayoutGhostPortrait(ghost);
      await settings.saveAudioSubtitleLayoutPortrait(audio);
      await settings.saveSubtitleTextStyle(text);
      await settings.setAudioSubtitleStyleSyncWithVideo(false);
      await settings.saveAudioSubtitleTextStyle(
        text.copyWith(textColor: Colors.cyan),
      );
      await settings.saveSubtitleAlignment(const Alignment(.31, .65));
      await settings.saveGhostModeAlignment(const Alignment(-.21, -.12));
      await settings.saveAudioSubtitleAlignment(const Alignment(.17, .42));
      final first = subtitleDebugPresets.first;
      final other = subtitleDebugPresets[1];
      await settings.commitPresetVideoPosition(
        first.id,
        const Alignment(.23, .54),
      );
      await settings.commitPresetAudioPosition(
        first.id,
        const Alignment(-.24, .16),
      );
      final session = SubtitleDebugSession.instance;
      await session.toggle();
      await session.updatePreset(
        first.copyWith(
          textScale: 1.37,
          outline: 3.1,
          box: .7,
          secondaryColor: Colors.amber,
          shadowOffset: const Offset(2, 4),
        ),
      );
      await session.updateGhostTextScale(first.id, .78);
      await session.updatePreset(other.copyWith(textScale: .92));
      await session.updateGhostTextScale(other.id, 1.64);
      await session.select(first);
      final before = await _exporter().buildSnapshot(settings: settings);
      settings.resetForTest();
      session.resetForTest();
      await settings.init();
      final after = await _exporter().buildSnapshot(settings: settings);
      expect(after['settings']['subtitles'], before['settings']['subtitles']);
      final subtitles = after['settings']['subtitles'];
      expect(subtitles['textStyle'], text.toJson());
      expect(subtitles['audioTextStyle']['textColor'], Colors.cyan.toARGB32());
      for (final suffix in ['Landscape', 'Portrait']) {
        expect(subtitles['layout$suffix'], normal.toJson());
        expect(subtitles['ghostLayout$suffix'], ghost.toJson());
        expect(subtitles['audioLayout$suffix'], audio.toJson());
      }
      expect(subtitles['alignment'], {'x': .31, 'y': .65});
      expect(subtitles['ghostAlignment'], {'x': -.21, 'y': -.12});
      expect(subtitles['audioAlignment'], {'x': .17, 'y': .42});
      expect(
        subtitles['presetPositionOverrides']['presetOverrides'][first.id],
        {
          'video': {'x': .23, 'y': .54},
          'audio': {'x': -.24, 'y': .16},
        },
      );
      final mode = subtitles['presetMode'];
      expect(mode['presets'].length, subtitleDebugPresets.length);
      expect(mode['presets'][first.id]['textScale'], 1.37);
      expect(mode['ghostTextScales'][first.id], .78);
      expect(mode['presets'][other.id]['textScale'], .92);
      expect(mode['ghostTextScales'][other.id], 1.64);
      await session.close();
      final inactive = settings
          .exportSettingsSnapshot()['subtitles']['presetMode'];
      expect(inactive['enabled'], false);
      expect(inactive['custom'], mode['custom']);
      expect(inactive['ghostTextScales'], mode['ghostTextScales']);
    },
  );

  test(
    'portrait/landscape slots and recently added core preferences survive',
    () async {
      await settings.init();
      await settings.updateHomeCardStyleFor(
        const Size(390, 844),
        crossAxisCount: 3,
        titleScale: .12,
        heightScale: 1.3,
        crossSpacingScale: .11,
        mainSpacingScale: .14,
      );
      await settings.updateHomeCardStyleFor(
        const Size(1280, 800),
        crossAxisCount: 7,
        titleScale: .09,
        heightScale: 1.1,
        crossSpacingScale: .07,
        mainSpacingScale: .08,
      );
      await settings.updateListStyleFor(
        const Size(390, 844),
        crossAxisCount: 2,
        showThumbnail: false,
        showIndex: true,
      );
      await settings.updateListStyleFor(
        const Size(1280, 800),
        crossAxisCount: 4,
        showThumbnail: true,
        showIndex: false,
      );
      await settings.updateSetting('bilibiliDanmakuFontWeight', 800);
      await settings.updateSetting(
        'batchSubtitleEmbedSoftSuffix',
        '-subtitled',
      );
      await settings.updateSetting('videoComposeRenderSecondary', false);
      await settings.saveSkipPortraitPlayer(true);
      await settings.saveUseHardwareVideoDecoding(false);
      await settings.saveAudioPortraitDisplayAspectRatio(
        1.5,
        customWidth: 3,
        customHeight: 2,
      );
      final exported = (await _exporter().buildSnapshot(
        settings: settings,
        viewportSize: const Size(390, 844),
      ))['settings'];
      final slots = exported['layout']['mediaLibraryOrientationOverrides'];
      expect(slots['homeGridCrossAxisCountPortrait'], 3);
      expect(slots['homeGridCrossAxisCountLandscape'], 7);
      expect(slots['mediaListShowThumbnailPortrait'], false);
      expect(slots['mediaListShowIndexLandscape'], false);
      expect(exported['danmaku']['bilibiliDanmakuFontWeight'], 800);
      expect(
        exported['batchSubtitles']['batchSubtitleEmbedSoftSuffix'],
        '-subtitled',
      );
      expect(exported['videoCompose']['videoComposeRenderSecondary'], false);
      expect(exported['playback']['skipPortraitPlayer'], true);
      expect(exported['playback']['useHardwareVideoDecoding'], false);
      expect(exported['music']['audioPortraitDisplayAspectRatio'], 1.5);
      expect(exported['music']['audioPortraitCustomAspectWidth'], 3);
    },
  );

  test(
    'dormant feature stores keep saved values, false values and empty lists',
    () async {
      SharedPreferences.setMockInitialValues({
        'bilibili_max_concurrent': 4,
        'bilibili_connections_per_video': 8,
        'bilibili_download_danmaku': false,
        'bilibili_stream_preferred_quality': 80,
        'bilibili_preferred_audio_quality': 'dolby',
        'bilibili_stream_preferred_audio': 30251,
        'yt_dlp_session_config_v1': jsonEncode(
          const DownloadSessionConfig(
            concurrentFragments: 12,
            retries: 5,
            forceIpv4: true,
          ).toJson(),
        ),
        'yt_dlp_download_preferences_v1': jsonEncode(
          const YtDlpDownloadPreferences(
            maxConcurrentDownloads: 3,
            preferredQuality: '1080p',
            preferredSubtitleLanguages: [],
            autoExpandTaskOptions: false,
          ).toJson(),
        ),
        'web_media_queue_settings_v2': jsonEncode(
          const WebMediaQueueSettings(
            connections: 7,
            autoStart: false,
            retryLimit: 0,
          ).toJson(),
        ),
        WebMediaBrowserPreferences.storageKey: jsonEncode({
          'shortcuts': [],
          'desktopMode': false,
        }),
        'douyin_manual_capture_mode': true,
        'cloudDrive.quark.view': jsonEncode({
          'descending': true,
          'foldersFirst': false,
          'filter': 'audio',
        }),
        PortableExportSettingsMemory.zipKey: jsonEncode({
          'wrapInFolder': false,
          'includeDanmaku': true,
        }),
        'sleepTimer.customMinutes': 75,
        'sleepTimer.customItemCount': 9,
        AiChatReadingSettings.preferenceKey: 1.35,
        SubtitleManualTranslationSettings.promptKey: '保留术语',
        SubtitleTranslateSettings.languageProfilesKey: jsonEncode({
          'bing': {'source': 'en', 'target': 'ja', 'mode': 'fixed'},
        }),
      });
      await settings.init();
      final snapshot = await _exporter(
        model: {
          'sourcePreference': 'mirror',
          'asrCpuThreads': 6,
          'asrLanguagePreferences': {'local:qwen3-asr-0.6b-f16': 'ja'},
          'parakeetJapaneseDenoise': true,
          'asrEnhancements': AsrEnhancementOptions.recommended
              .copyWith(denoise: false)
              .toJson(),
          'subtitleSegmentation': SubtitleSegmentationOptions.standard.toJson(),
          'translationModelOptions': {
            'test-model': const LocalTranslationOptions(batchSize: 4).toJson(),
          },
        },
        podcasts: {
          'summaries': false,
          'density': 'compact',
          'continuous': false,
        },
      ).buildSnapshot(settings: settings);
      expect(snapshot['bilibili']['maxConcurrentDownloads'], 4);
      expect(snapshot['bilibili']['maxConnectionsPerVideo'], 8);
      expect(snapshot['bilibili']['downloadDanmaku'], false);
      expect(snapshot['bilibili']['streamPreferredQuality'], 80);
      expect(snapshot['bilibili']['preferredAudioQuality'], 'dolby');
      expect(snapshot['bilibili']['streamPreferredAudio'], 30251);
      expect(snapshot['ytDlp']['session']['concurrentFragments'], 12);
      expect(snapshot['ytDlp']['preferences']['maxConcurrentDownloads'], 3);
      expect(snapshot['ytDlp']['preferences']['autoExpandTaskOptions'], false);
      expect(
        snapshot['ytDlp']['preferences']['preferredSubtitleLanguages'],
        isEmpty,
      );
      expect(snapshot['webMedia']['queue']['autoStart'], false);
      expect(snapshot['webMedia']['queue']['retryLimit'], 0);
      expect(snapshot['webMedia']['browser']['desktopMode'], false);
      expect(snapshot['douyin']['manualCaptureMode'], true);
      expect(snapshot['cloudDrive']['views']['quark']['foldersFirst'], false);
      expect(snapshot['cloudDrive']['views']['quark']['filter'], 'audio');
      expect(snapshot['portableExport']['zip']['wrapInFolder'], false);
      expect(snapshot['portableExport']['zip']['includeDanmaku'], true);
      expect(snapshot['sleepTimer']['customMinutes'], 75);
      expect(snapshot['aiChat']['readingScale'], 1.35);
      expect(snapshot['translation']['manual']['prompt'], '保留术语');
      expect(
        snapshot['translation']['languageProfiles']['bing']['target'],
        'ja',
      );
      expect(snapshot['modelProcessing']['asrCpuThreads'], 6);
      expect(snapshot['modelProcessing']['asrLanguagePreferences'], {
        'local:qwen3-asr-0.6b-f16': 'ja',
      });
      expect(snapshot['modelProcessing']['parakeetJapaneseDenoise'], true);
      expect(snapshot['modelProcessing']['asrEnhancements']['denoise'], false);
      expect(
        snapshot['modelProcessing']['translationModelOptions']['test-model']['batchSize'],
        4,
      );
      expect(snapshot['podcasts']['explicitOverrides'], {
        'summaries': false,
        'density': 'compact',
        'continuous': false,
      });
      expect(
        snapshot['podcasts']['explicitOverrides'].containsKey('speed'),
        false,
      );
    },
  );

  test(
    'optimization exports stable fields without changing its local connection',
    () async {
      const connection = 'DEVICE_LOCAL_OPTIMIZATION_CONNECTION';
      const extra = 'PRIVATE_OPTIMIZATION_EXTRA';
      const prompt = 'Keep the original language and correct clear typos only.';
      final original = jsonEncode({
        'enabled': true,
        'prompt': prompt,
        'connectionId': connection,
        'endpoint': {'baseUrl': extra, 'model': extra},
        'apiKey': extra,
        'profiles': {extra: extra},
        'background': extra,
        'unknownFutureField': extra,
      });
      SharedPreferences.setMockInitialValues({
        SubtitleOptimizationSettings.preferencesKey: original,
      });
      await settings.init();
      final snapshot = await _exporter().buildSnapshot(settings: settings);
      expect(snapshot['subtitleOptimization'], {
        'enabled': true,
        'prompt': prompt,
      });
      final encoded = jsonEncode(snapshot);
      expect(encoded, isNot(contains(connection)));
      expect(encoded, isNot(contains(extra)));
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(SubtitleOptimizationSettings.preferencesKey),
        original,
      );
    },
  );

  test(
    'credentials, selections, local paths and personal state never leak',
    () async {
      const secret = 'PRIVATE_SENTINEL_DO_NOT_EXPORT';
      SharedPreferences.setMockInitialValues({
        'lastSelectedModelType': secret,
        'largeDataRootPath': secret,
        'mediaLibraryLastFolderId': secret,
        'mediaLibraryEntryAnchors': secret,
        'importSourceFolderIds': jsonEncode({'localFile': secret}),
        ImportPlacementRules.settingsKey: jsonEncode({
          'fixedFolderId': secret,
          'overrides': {
            'localFile': {'placement': 'fixedFolder', 'folderId': secret},
          },
        }),
        'subtitle_download_path': secret,
        'bilibili_custom_download_path': secret,
        'videoComposePrimarySubtitlePath': secret,
        'videoComposeSecondarySubtitlePath': secret,
        'videoComposeCustomOutputPath': secret,
        'batchSubtitleCustomOutputDir': secret,
        'clipboardLastHandledText': secret,
        'subtitleFontLanguages': jsonEncode({secret: 'en'}),
        'bilibili_session_cookies_v1': secret,
        'bilibiliOfflineDetails': jsonEncode({
          'BV_OFFLINE_CONTROL': {
            't': secret,
            'o': secret,
            'm': 123,
            'd': secret,
            'tags': [secret],
            'at': 123456,
          },
        }),
        'subtitle_ai_connections_v1': jsonEncode([
          {
            'id': secret,
            'name': secret,
            'endpoint': {
              'baseUrl': secret,
              'model': secret,
              'apiKey': secret,
              'profiles': {secret: secret},
            },
          },
        ]),
        'subtitle_optimization_v1': jsonEncode({
          'enabled': true,
          'prompt': 'Portable optimization prompt control',
          'connectionId': secret,
          // Malicious/unknown extra fields must never become preferences.
          'apiKey': secret,
          'profiles': {secret: secret},
          'background': secret,
        }),
        'cloudDrive.baidu.account': secret,
        'subtitle_translate_provider_enzh': 'local',
        'subtitle_ai_api_v1': jsonEncode({
          'model': secret,
          'apiKey': secret,
          'baseUrl': secret,
        }),
        'yt_dlp_session_config_v1': jsonEncode({
          'poTokens': [
            {'context': 'web', 'token': secret},
          ],
          'visitorData': secret,
          'cookiesFilePath': secret,
          'outputDirectory': secret,
          'referer': secret,
        }),
        AiChatSettingsStore.preferencesKey: jsonEncode({
          'baseUrl': secret,
          'model': secret,
          'apiKey': secret,
          'executablePath': secret,
          'apiProfiles': {},
          'cliProfiles': {},
        }),
        WebMediaBrowserPreferences.storageKey: jsonEncode({
          'shortcuts': [
            {'id': secret},
          ],
          'history': [secret],
          'resumePage': secret,
          'sites': [secret],
          'desktopMode': true,
        }),
        'sleepTimer.deadlineMs': 99999,
        'sleepTimer.mode': 4,
        'show_export_settings_button': true,
      });
      await settings.init();
      final snapshot =
          await _exporter(
            model: {
              'asrProfileId': secret,
              'translationModelId': secret,
              'profiles': [secret],
              'downloads': [secret],
              'diagnostics': {'test': secret},
              'inferenceTuning': {'test': secret},
              'asrPerformance': {'test': secret},
            },
            network: NetworkConfiguration(
              proxy: const ProxyProfile(
                protocol: ProxyProtocol.http,
                host: secret,
                port: 9999,
                username: secret,
                credentialKey: secret,
                transientPassword: secret,
              ),
              modes: {NetworkScope.translation: NetworkMode.custom},
            ),
          ).buildSnapshot(
            settings: settings,
            syncPreferences: () async => {
              'enabled': true,
              'privateKey': secret,
            },
          );
      final encoded = jsonEncode(snapshot);
      expect(encoded, isNot(contains(secret)));
      expect(snapshot['progressSync'], {'enabled': true});
      expect(snapshot['network']['featureModes']['translation'], 'custom');
      expect(snapshot['network'].containsKey('proxy'), false);
      expect(
        snapshot['settings']['home'][ImportPlacementRules
            .settingsKey]['overrides']['localFile'],
        {'placement': 'fixedFolder'},
      );
      expect(snapshot['sleepTimer'].containsKey('mode'), false);
      expect(snapshot['translation'].containsKey('providerEnZh'), false);
      // Building an export does not reset the actual selected provider/model.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lastSelectedModelType'), secret);
      expect(prefs.getString('subtitle_translate_provider_enzh'), 'local');
      expect(prefs.getString('bilibiliOfflineDetails'), contains(secret));
      expect(prefs.getString('subtitle_ai_connections_v1'), contains(secret));
      expect(
        jsonDecode(prefs.getString('subtitle_optimization_v1')!)[
          'connectionId'
        ],
        secret,
      );
    },
  );

  test(
    'latest runtime values win and returned snapshots are detached',
    () async {
      await settings.init();
      final bilibili = _LoadedBilibiliPreferences();
      addTearDown(bilibili.dispose);
      bilibili.maxConcurrentDownloads = 5;
      bilibili.downloadDanmaku = false;
      final gate = Completer<Map<String, dynamic>>();
      final future = _exporter(modelReader: () => gate.future).buildSnapshot(
        settings: settings,
        bilibili: bilibili,
        webQueueSettings: const WebMediaQueueSettings(
          autoStart: false,
          connections: 9,
        ),
      );
      settings.subtitlePresets.add({'x': .1, 'y': .2});
      settings.longPressSpeed = 6;
      gate.complete({});
      final snapshot = await future;
      expect(snapshot['bilibili']['maxConcurrentDownloads'], 5);
      expect(snapshot['bilibili']['downloadDanmaku'], false);
      expect(snapshot['webMedia']['queue']['connections'], 9);
      expect(snapshot['settings']['subtitles']['presets'], isEmpty);
      expect(snapshot['settings']['playback']['longPressSpeed'], 2);
    },
  );

  test(
    'unreadable stores fail instead of claiming a complete export',
    () async {
      SharedPreferences.setMockInitialValues({
        'yt_dlp_session_config_v1': '{broken',
      });
      await settings.init();
      await expectLater(
        _exporter().buildSnapshot(settings: settings),
        throwsFormatException,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('yt_dlp_session_config_v1');
      await expectLater(
        _exporter(
          modelReader: () async =>
              throw const FileSystemException('unreadable'),
        ).buildSnapshot(settings: settings),
        throwsA(isA<FileSystemException>()),
      );
    },
  );

  test(
    'dormant legacy settings stay passive without migration writes',
    () async {
      await settings.init();
      final snapshot = await _exporter(
        nativeYtDlpReader: () async => const DownloadSessionConfig(
          concurrentFragments: 4,
          retries: 99,
          fragmentRetries: 99,
          forceIpv4: true,
        ),
      ).buildSnapshot(settings: settings);
      expect(snapshot['ytDlp']['session']['forceIpv4'], true);
      expect(snapshot['ytDlp']['session']['concurrentFragments'], 4);
      expect(snapshot['ytDlp']['session']['retries'], 99);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('yt_dlp_session_config_v1'), false);
      expect(prefs.containsKey('yt_dlp_parallel_download_defaults_v3'), false);
    },
  );

  test(
    'reading size exports the live value while its save is queued',
    () async {
      await settings.init();
      final gate = Completer<SharedPreferences>();
      final reading = AiChatReadingSettings(preferences: () => gate.future);
      addTearDown(reading.dispose);
      final saved = reading.setScale(1.47);
      final snapshot = _exporter().buildSnapshot(
        settings: settings,
        readingSettings: reading,
      );
      gate.complete(await SharedPreferences.getInstance());
      expect((await snapshot)['aiChat']['readingScale'], 1.47);
      await saved;
    },
  );

  test(
    'real dormant model JSON and podcast SQLite settings are read',
    () async {
      await settings.init();
      final temporary = await Directory.systemTemp.createTemp(
        'settings_export_stores_',
      );
      final previous = AppStorageService.instance;
      addTearDown(() async {
        AppStorageService.instance = previous;
        await temporary.delete(recursive: true);
      });
      Future<Directory> directory(String name) =>
          Directory('${temporary.path}/$name').create();
      final data = await directory('data');
      final locations = StorageLocations(
        platform: StoragePlatform.windows,
        support: await directory('support'),
        documents: await directory('documents'),
        defaultData: data,
        executable: await directory('program'),
      );
      AppStorageService.instance = AppStorageService(
        locations: () async => locations,
      );
      await AppStorageService.instance.initialize();
      await File('${data.path}/model_center.json').writeAsString(
        jsonEncode({
          'asrCpuThreads': 7,
          'language': 'ja',
          'asrProfileId': 'PRIVATE_MODEL',
          'subtitleSegmentation': SubtitleSegmentationOptions.original.toJson(),
        }),
      );
      await File('${data.path}/media_cache.json').writeAsString(
        jsonEncode({
          'version': 1,
          'preferences': MediaCachePreferences(
            limits: {'bilibili': 1080, 'quark': 720},
            pruneLower: false,
            parallelTasks: 5,
            connectionsPerTask: 3,
            connectionBudget: 12,
          ).toJson(),
          'tasks': ['PRIVATE_CACHE_TASK'],
          'variants': ['PRIVATE_CACHE_PATH'],
        }),
      );
      final podcasts = await Directory('${data.path}/podcasts').create();
      final db = sqlite3.open('${podcasts.path}/podcasts.sqlite');
      db.execute('CREATE TABLE records (kind TEXT, id TEXT, payload TEXT)');
      db.execute('INSERT INTO records VALUES (?, ?, ?)', [
        'settings',
        'global',
        jsonEncode({'density': 'compact', 'speed': 1.8}),
      ]);
      db.execute('INSERT INTO records VALUES (?, ?, ?)', [
        'settings',
        'private-channel',
        jsonEncode({'skipIntro': 123, 'private': 'PERSONAL_CHANNEL'}),
      ]);
      db.dispose();
      final exporter = SettingsExportService(
        networkPreferences: () async => NetworkConfiguration(),
        nativeYtDlpPreferences: () async => null,
      );
      final snapshot = await exporter.buildSnapshot(settings: settings);
      expect(snapshot['modelProcessing']['asrCpuThreads'], 7);
      expect(
        snapshot['mediaCache'],
        MediaCachePreferences(
          limits: {'bilibili': 1080, 'quark': 720},
          pruneLower: false,
          parallelTasks: 5,
          connectionsPerTask: 3,
          connectionBudget: 12,
        ).toJson(),
      );
      expect(jsonEncode(snapshot), isNot(contains('PRIVATE_CACHE_TASK')));
      expect(jsonEncode(snapshot), isNot(contains('PRIVATE_CACHE_PATH')));
      expect(snapshot['modelProcessing']['language'], 'ja');
      expect(
        snapshot['modelProcessing']['subtitleSegmentation']['enabled'],
        false,
      );
      expect(snapshot['podcasts']['preferences']['density'], 'compact');
      expect(snapshot['podcasts']['explicitOverrides']['speed'], 1.8);
      expect(snapshot['podcasts']['preferences']['skipIntro'], 0);
      expect(jsonEncode(snapshot), isNot(contains('PERSONAL_CHANNEL')));
      expect(jsonEncode(snapshot), isNot(contains('PRIVATE_MODEL')));
    },
  );

  test(
    'JSON file replaces the previous complete export and leaves no temp file',
    () async {
      await settings.init();
      final directory = await Directory.systemTemp.createTemp(
        'settings_export_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final exporter = _exporter();
      final snapshot = await exporter.buildSnapshot(settings: settings);
      await exporter.writeSnapshot({'old': true}, directory: directory);
      final file = await exporter.writeSnapshot(snapshot, directory: directory);
      expect(file.path.endsWith(SettingsExportService.fileName), true);
      expect(jsonDecode(await file.readAsString()), snapshot);
      expect(directory.listSync().length, 1);
      final withInvalidNumber = {'bad': double.nan};
      await expectLater(
        Future.sync(
          () => exporter.writeSnapshot(withInvalidNumber, directory: directory),
        ),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      expect(jsonDecode(await file.readAsString()), snapshot);
    },
  );
}
