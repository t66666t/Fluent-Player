import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/podcasts/podcast_settings.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/features/portable_transfer/portable_export_settings_memory.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/features/youtube_download/platform/yt_dlp_native_bridge.dart';
import 'package:video_player_app/features/youtube_download/services/yt_dlp_download_service.dart';
import 'package:video_player_app/models/recommended_app_defaults.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/services/app_default_settings_trial.dart';
import 'package:video_player_app/services/default_settings_trial.dart';
import 'package:video_player_app/services/network/network_models.dart';
import 'package:video_player_app/services/network/network_settings_service.dart';
import 'package:video_player_app/services/settings_export_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';
import 'support/default_trial_features.dart';

class _NetworkStore implements NetworkConfigStore {
  NetworkConfiguration? value;
  @override
  Future<NetworkConfiguration?> read() async => value;
  @override
  Future<void> write(NetworkConfiguration next) async {
    value = next;
  }
}

class _Credentials implements NetworkCredentialStore {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

class _SessionBridge extends YtDlpNativeBridge {
  DownloadSessionConfig? value;
  @override
  Future<DownloadSessionConfig?> loadYoutubeSessionConfig() async => value;
  @override
  Future<bool> saveYoutubeSessionConfig(DownloadSessionConfig config) async {
    value = config;
    return true;
  }
}

Map<String, Object?> _raw(
  SharedPreferences prefs,
  SettingsService settings,
) => {
  for (final key in settings.defaultAppTrialPreferenceKeys) key: prefs.get(key),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final generatedProfiles = <String, dynamic>{};
  tearDownAll(() async {
    if (Platform.environment['APP_DEFAULT_PROFILES'] != '1') return;
    final profilesFile = File('docs/recommended-default-settings.json');
    final pendingProfilesFile = File('${profilesFile.path}.tmp');
    await pendingProfilesFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'version': RecommendedAppDefaults.version,
        'purpose':
            'Reviewable trial defaults; does not change shipped factory defaults',
        'profiles': generatedProfiles,
      }),
    );
    await pendingProfilesFile.rename(profilesFile.path);
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SubtitleDebugSession.instance.resetForTest();
    final settings = SettingsService()..resetForTest();
    settings.featureSettingsForTrial = MemoryTrialFeatures();
    settings.defaultTrialDevice = const DefaultSettingsDevice(
      TargetPlatform.windows,
      Size(1280, 720),
    );
    DefaultTrialRuntime.bindings.clear();
  });

  test(
    'every generic registered preference and mixed-store field has a default policy',
    () async {
      final settings = SettingsService();
      await settings.init();
      final base = settings.registeredDefaultPreferences;
      expect(base.length, greaterThan(120));
      expect(
        RecommendedAppDefaults.coreOverrides(
          settings.defaultTrialDevice,
        ).keys.toSet().difference(base.keys.toSet()),
        isEmpty,
      );
      expect(
        base.keys.toSet().intersection(
          SettingsService.settingsExportExclusions.keys.toSet(),
        ),
        isEmpty,
      );
      expect(
        RecommendedAppDefaults.aiFields,
        SettingsExportService.aiChatPreferenceKeys,
      );
      expect(
        RecommendedAppDefaults.sessionFields,
        SettingsExportService.ytDlpSessionPreferenceKeys,
      );
      expect(
        RecommendedAppDefaults.modelFields,
        SettingsExportService.modelPreferenceKeys,
      );
      expect(
        RecommendedAppDefaults.podcastValues(
            settings.defaultTrialDevice,
          ).keys.toSet()
          ..addAll(RecommendedAppDefaults.podcastOperationalExclusions.keys),
        podcastSettings.map((e) => e.key).toSet(),
      );
      expect(
        settings.defaultAppTrialPreferenceKeys,
        containsAll(SettingsService.mediaLibraryLayoutExportKeys),
      );
      expect(settings.defaultAppTrialPreferenceKeys.length, greaterThan(200));
    },
  );

  for (final device in [
    const DefaultSettingsDevice(TargetPlatform.android, Size(390, 844)),
    const DefaultSettingsDevice(TargetPlatform.iOS, Size(430, 932)),
    const DefaultSettingsDevice(TargetPlatform.android, Size(1280, 800)),
    const DefaultSettingsDevice(TargetPlatform.iOS, Size(768, 1024)),
    const DefaultSettingsDevice(TargetPlatform.windows, Size(1920, 1080)),
    const DefaultSettingsDevice(TargetPlatform.macOS, Size(1440, 900)),
    const DefaultSettingsDevice(TargetPlatform.linux, Size(1024, 768)),
  ]) {
    test(
      'real profile applies and fully restores on ${device.platform.name} ${device.size}',
      () async {
        SharedPreferences.setMockInitialValues({
          'playbackSpeed': 1.6,
          'globalMute': true,
          'autoPlayNextVideo': false,
          'homeGridCrossAxisCountLandscape': 9,
          'bilibili_preferred_quality': 120,
          'showBilibiliDanmaku': false,
          'bilibiliDanmakuOpacity': .42,
          'bilibiliDanmakuFontScale': 1.3,
          'bilibiliDanmakuReadableFontDefaults': false,
          'bilibiliDanmakuSpeed': 1.3,
          'bilibiliDanmakuUseLockedSpeedAsBaseline': false,
          'bilibiliDanmakuAutoUpdate': false,
          'bilibili_download_danmaku': false,
        });
        final settings = SettingsService()..defaultTrialDevice = device;
        await settings.init();
        final prefs = await SharedPreferences.getInstance();
        final before = _raw(prefs, settings);
        final features =
            settings.featureSettingsForTrial as MemoryTrialFeatures;
        final originalFeatures = Map.of(features.values);
        await settings.defaultSettingsTrial.toggle();
        expect(settings.playbackSpeed, 1);
        expect(settings.globalMute, false);
        expect(settings.mediaLibraryRestoreLastPage, false);
        expect(settings.mediaLibraryStartupEntry, 'folders');
        expect(settings.mediaLibraryReadableCardDefaults, true);
        final ai = AiChatSettings.fromJson(
          jsonDecode(prefs.getString('ai_chat_settings_v1')!)
              as Map<String, dynamic>,
        );
        const aiDefaults = AiChatSettings();
        expect(ai.contextTokens, aiDefaults.contextTokens);
        expect(ai.maxOutputTokens, aiDefaults.maxOutputTokens);
        expect(ai.thinkingEnabled, aiDefaults.thinkingEnabled);
        expect(ai.reasoningEffort, aiDefaults.reasoningEffort);
        expect(ai.thinkingBudget, aiDefaults.thinkingBudget);
        expect(ai.autoCompact, isTrue);
        expect(ai.contextMode, AiContextMode.automatic);
        expect(ai.optimizeTokens, isFalse);
        expect(ai.fastSummaries, isFalse);
        expect(ai.titlePrompt, aiDefaults.titlePrompt);
        for (final key in [
          'subtitleLayoutLandscape',
          'subtitleLayoutPortrait',
          'subtitleLayoutGhostLandscape',
          'subtitleLayoutGhostPortrait',
          'audioSubtitleLayoutLandscape',
          'audioSubtitleLayoutPortrait',
        ]) {
          final layout = jsonDecode(prefs.getString(key)!) as Map;
          expect(layout['fontSize'], 39.7, reason: key);
          expect(
            layout['secondaryFontSize'],
            closeTo(39.7 * .85, 1e-8),
            reason: key,
          );
          expect(layout['balancedScreenSizing'], true, reason: key);
        }
        expect(settings.showBilibiliDanmaku, true);
        expect(settings.bilibiliDanmakuOnlyInVideoArea, false);
        expect(settings.bilibiliDanmakuOpacity, .95);
        expect(settings.bilibiliDanmakuFontScale, 1.0);
        expect(settings.bilibiliDanmakuReadableFontDefaults, true);
        expect(
          settings.bilibiliDanmakuSpeed,
          RecommendedAppDefaults.danmakuSpeed(device),
        );
        expect(settings.bilibiliDanmakuUseLockedSpeedAsBaseline, true);
        expect(settings.bilibiliDanmakuAutoUpdate, true);
        expect(prefs.getBool('bilibili_download_danmaku'), true);
        expect(settings.skipPortraitPlayer, !device.phone);
        expect(settings.pausePlaybackWhenAppBackgrounded, device.mobile);
        expect(settings.autoPauseOnExit, device.mobile);
        expect(settings.copyImportedMediaToPrivateStorage, device.mobile);
        expect(settings.videoComposeResolutionHeight, 1080);
        expect(settings.videoComposeDeleteOutputOnTaskDelete, false);
        expect(
          settings.subtitleTextStyle.defaultFont.family,
          'Swei Gothic CJK SC',
        );
        expect(prefs.getInt('bilibili_preferred_quality'), 80);
        expect(
          prefs.getInt('bilibili_max_concurrent'),
          device.parallelDownloads,
        );
        expect(prefs.getInt('bilibili_connections_per_video'), 2);
        expect(prefs.getInt('web_media_connections'), 32);
        expect(
          (jsonDecode(prefs.getString('web_media_browser_home_v1')!)
              as Map)['desktopMode'],
          isTrue,
        );
        expect(
          (jsonDecode(prefs.getString('web_media_queue_settings_v2')!)
              as Map)['connections'],
          32,
        );
        expect(
          (jsonDecode(prefs.getString('yt_dlp_session_config_v1')!)
              as Map)['concurrentFragments'],
          16,
        );
        expect(features.values['cache']['connectionsPerTask'], 4);
        expect(features.values['cache']['connectionBudget'], 8);
        for (final format in PortableExportFormat.values) {
          final export = await PortableExportSettingsMemory.load(format);
          expect(export.verifyChecksums, false);
          expect(export.includeSidecars, true);
          expect(export.zipEmbedSubtitles, true);
          expect(export.zipExternalSubtitles, true);
          expect(export.includeDanmaku, true);
        }
        expect(
          prefs.getString('yt_dlp_download_preferences_v1'),
          contains('1080p'),
        );
        expect(prefs.containsKey('homeGridCrossAxisCountLandscape'), false);
        expect(prefs.containsKey('homeGridCrossAxisCount'), false);
        expect(features.values['model']['asrCpuThreads'], 0);
        if (Platform.environment['APP_DEFAULT_PROFILES'] == '1') {
          generatedProfiles['${device.platform.name}-${device.phone
              ? 'phone'
              : device.tablet
              ? 'tablet'
              : 'desktop'}'] = {
            'platform': device.platform.name,
            'device': device.label,
            'referenceSize': [device.size.width, device.size.height],
            'mediaLibraryCardDefaults': {
              'portraitColumns': settings
                  .homeCardStyleFor(
                    Size(device.size.shortestSide, device.size.longestSide),
                  )
                  .crossAxisCount,
              'landscapeColumns': settings
                  .homeCardStyleFor(
                    Size(device.size.longestSide, device.size.shortestSide),
                  )
                  .crossAxisCount,
              'referenceCardWidth': 150,
              'referenceTitleFontSize': 12.5,
              'allElementsScaleWithCardWidth': true,
              'reservedTitleLines': 2,
              'columnsFollowPaneWidth': false,
            },
            'preferences': {
              for (final key
                  in settings.defaultAppTrialPreferenceKeys.toList()..sort())
                key: prefs.get(key),
            },
            'modelProcessing': RecommendedAppDefaults.modelValues(device),
            'mediaCache': RecommendedAppDefaults.cacheValues(device),
            'podcasts': RecommendedAppDefaults.podcastValues(device),
            'network': {
              'unifiedMode': null,
              'featureModes': {
                for (final entry in NetworkConfiguration().featureModes.entries)
                  entry.key.name: entry.value.name,
              },
            },
          };
        }
        await settings.updateSetting('globalMute', true);
        await settings.updateSetting('homeGridCrossAxisCount', 7);
        await prefs.setInt('bilibili_preferred_quality', 64);
        await settings.defaultSettingsTrial.toggle();
        expect(_raw(prefs, settings), before);
        expect(settings.playbackSpeed, 1.6);
        expect(settings.globalMute, true);
        expect(settings.autoPlayNextVideo, false);
        expect(features.values, originalFeatures);
        expect(settings.defaultSettingsTrial.hasBackup, false);
      },
    );
  }

  test(
    'interrupted full-app trial restores all preferences before cold-start loading',
    () async {
      final settings = SettingsService()
        ..defaultTrialDevice = const DefaultSettingsDevice(
          TargetPlatform.android,
          Size(390, 844),
        );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('playbackSpeed', 1.75);
      await prefs.setBool('globalMute', true);
      await prefs.setInt('bilibili_preferred_quality', 64);
      await settings.init();
      final original = _raw(prefs, settings);
      await settings.defaultSettingsTrial.toggle();
      final journal = settings.defaultSettingsTrial.journal;
      await journal.setPhase((await journal.read())!, 'restoring');
      settings.resetForTest();
      SubtitleDebugSession.instance.resetForTest();
      settings.defaultTrialDevice = const DefaultSettingsDevice(
        TargetPlatform.windows,
        Size(1280, 720),
      );
      await settings.init();
      expect(settings.defaultSettingsTrial.hasBackup, false);
      expect(settings.defaultTrialDevice.phone, true);
      expect(_raw(prefs, settings), original);
      expect((settings.featureSettingsForTrial as MemoryTrialFeatures).values, {
        'original': true,
      });
      expect(settings.playbackSpeed, 1.75);
      expect(settings.globalMute, true);
    },
  );

  test(
    'mixed JSON restores only safe fields and retains newly changed credentials/history',
    () async {
      SharedPreferences.setMockInitialValues({
        'ai_chat_settings_v1': jsonEncode({
          'temperature': .8,
          'optimizeTokens': true,
          'fastSummaries': true,
          'model': 'private-model',
          'apiKey': 'SECRET-ORIGINAL',
        }),
        'yt_dlp_session_config_v1': jsonEncode({
          'retries': 9,
          'cookiesFilePath': '/private/old',
          'visitorData': 'SECRET-VISITOR',
        }),
        'web_media_browser_home_v1': jsonEncode({
          'desktopMode': false,
          'shortcuts': [],
          'history': ['PRIVATE-HISTORY'],
        }),
        'lastSelectedModelType': 'keep-model',
        'perVideoState': 'keep-video',
        'show_export_settings_button': true,
      });
      final settings = SettingsService();
      await settings.init();
      await settings.defaultSettingsTrial.toggle();
      final prefs = await SharedPreferences.getInstance();
      final backup = prefs.getString(DefaultSettingsTrialJournal.originalKey)!;
      expect(backup, isNot(contains('SECRET-')));
      expect(backup, isNot(contains('PRIVATE-HISTORY')));
      expect(backup, isNot(contains('private-model')));
      final ai =
          jsonDecode(prefs.getString('ai_chat_settings_v1')!)
              as Map<String, dynamic>;
      expect(ai['temperature'], .3);
      expect(ai['optimizeTokens'], false);
      expect(ai['fastSummaries'], false);
      expect(ai['model'], 'private-model');
      ai['apiKey'] = 'NEW-SECRET';
      ai['model'] = 'new-model';
      ai['temperature'] = .1;
      await prefs.setString('ai_chat_settings_v1', jsonEncode(ai));
      final browser =
          jsonDecode(prefs.getString('web_media_browser_home_v1')!)
              as Map<String, dynamic>;
      browser['history'] = ['new-history'];
      await prefs.setString('web_media_browser_home_v1', jsonEncode(browser));
      await settings.defaultSettingsTrial.toggle();
      final restored =
          jsonDecode(prefs.getString('ai_chat_settings_v1')!) as Map;
      expect(restored['temperature'], .8);
      expect(restored['optimizeTokens'], true);
      expect(restored['fastSummaries'], true);
      expect(restored['apiKey'], 'NEW-SECRET');
      expect(restored['model'], 'new-model');
      expect(restored.containsKey('thinkingEnabled'), false);
      final restoredBrowser =
          jsonDecode(prefs.getString('web_media_browser_home_v1')!) as Map;
      expect(restoredBrowser['desktopMode'], false);
      expect(restoredBrowser['history'], ['new-history']);
      expect(prefs.getString('lastSelectedModelType'), 'keep-model');
      expect(prefs.getString('perVideoState'), 'keep-video');
      expect(prefs.getBool('show_export_settings_button'), true);
    },
  );

  test(
    'feature application failure rolls back the whole app and keeps originals on failed restore',
    () async {
      SharedPreferences.setMockInitialValues({'playbackSpeed': 1.8});
      final settings = SettingsService();
      await settings.init();
      final prefs = await SharedPreferences.getInstance();
      final original = _raw(prefs, settings);
      final feature = settings.featureSettingsForTrial as MemoryTrialFeatures;
      feature.failApply = true;
      feature.failRestore = true;
      await expectLater(
        settings.defaultSettingsTrial.toggle(),
        throwsStateError,
      );
      expect(settings.defaultSettingsTrial.hasBackup, true);
      final backup = prefs.getString(DefaultSettingsTrialJournal.originalKey);
      feature.failRestore = false;
      await settings.defaultSettingsTrial.toggle();
      expect(_raw(prefs, settings), original);
      expect(settings.playbackSpeed, 1.8);
      expect(feature.values, {'original': true});
      expect(backup, isNotNull);
    },
  );

  test(
    'real model/cache JSON and podcast SQLite restore fields without reverting tasks or proxy credentials',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'whole_app_defaults_',
      );
      addTearDown(() => directory.delete(recursive: true));
      final files = {
        for (final key in ['model', 'cache', 'podcasts'])
          key: File(
            '${directory.path}/$key${key == 'podcasts' ? '.sqlite' : '.json'}',
          ),
      };
      await files['model']!.writeAsString(
        jsonEncode({
          'version': 1,
          'language': 'ja',
          'threads': 3,
          'asrProfileId': 'PRIVATE-PROFILE',
          'profiles': [
            {'key': 'SECRET'},
          ],
          'downloads': ['old-task'],
        }),
      );
      await files['cache']!.writeAsString(
        jsonEncode({
          'version': 1,
          'preferences': {'parallelTasks': 3, 'pruneLower': true},
          'tasks': ['old-task'],
        }),
      );
      final podcasts = PodcastStore.open(files['podcasts']!.path);
      addTearDown(podcasts.close);
      podcasts.write('settings', 'global', {
        'speed': 1.6,
        'density': 'compact',
        'pauseAllDownloads': true,
      });
      podcasts.write('settings', 'channel-1', {'speed': 2.0});
      final networkStore = _NetworkStore()
        ..value = NetworkConfiguration(
          unifiedMode: NetworkMode.direct,
          proxy: const ProxyProfile(
            protocol: ProxyProtocol.http,
            host: '127.0.0.1',
            port: 7890,
          ),
        );
      final network = NetworkSettingsService(
        store: networkStore,
        credentials: _Credentials(),
        migrateLegacy: false,
      );
      await network.init();
      final native = _SessionBridge()
        ..value = const DownloadSessionConfig(
          retries: 9,
          concurrentFragments: 7,
          useCookies: true,
          cookiesFilePath: 'LEGACY-SECRET-COOKIE',
        );
      final feature = FileDefaultTrialFeatureStore(
        files: () async => files,
        network: network,
        readNativeSession: native.loadYoutubeSessionConfig,
        writeNativeSession: native.saveYoutubeSessionConfig,
      );
      final original = await feature.capture();
      expect(jsonEncode(original), isNot(contains('SECRET')));
      expect(jsonEncode(original), isNot(contains('PRIVATE-PROFILE')));
      expect(jsonEncode(original), isNot(contains('127.0.0.1')));
      expect(jsonEncode(original), isNot(contains('LEGACY-SECRET-COOKIE')));
      expect(jsonEncode(original), isNot(contains('pauseAllDownloads')));
      await feature.apply(
        const DefaultSettingsDevice(TargetPlatform.windows, Size(1280, 720)),
      );
      var model =
          jsonDecode(await files['model']!.readAsString())
              as Map<String, dynamic>;
      expect(model['asrProfileId'], 'PRIVATE-PROFILE');
      expect(model['language'], 'auto');
      model['downloads'] = ['new-task'];
      await files['model']!.writeAsString(jsonEncode(model));
      final cache =
          jsonDecode(await files['cache']!.readAsString())
              as Map<String, dynamic>;
      cache['tasks'] = ['new-cache-task'];
      await files['cache']!.writeAsString(jsonEncode(cache));
      podcasts.write('settings', 'channel-1', {'speed': 2.5});
      native.value = native.value!.copyWith(
        retries: 3,
        concurrentFragments: 4,
        cookiesFilePath: 'NEW-SECRET-COOKIE',
      );
      expect(podcasts.read('settings', 'global')!.containsKey('speed'), false);
      expect(podcasts.read('settings', 'global')!['pauseAllDownloads'], true);
      podcasts.write('settings', 'global', {
        ...podcasts.read('settings', 'global')!,
        'pauseAllDownloads': false,
      });
      await feature.restore(original);
      model =
          jsonDecode(await files['model']!.readAsString())
              as Map<String, dynamic>;
      expect(model['language'], 'ja');
      expect(model['threads'], 3);
      expect(model['downloads'], ['new-task']);
      expect(model.containsKey('asrCpuThreads'), false);
      final restoredCache =
          jsonDecode(await files['cache']!.readAsString()) as Map;
      expect(restoredCache['preferences'], {
        'parallelTasks': 3,
        'pruneLower': true,
      });
      expect(restoredCache['tasks'], ['new-cache-task']);
      expect(podcasts.read('settings', 'global'), {
        'speed': 1.6,
        'density': 'compact',
        'pauseAllDownloads': false,
      });
      expect(podcasts.read('settings', 'channel-1'), {'speed': 2.5});
      expect(network.configuration.unifiedMode, NetworkMode.direct);
      expect(network.configuration.proxy?.host, '127.0.0.1');
      expect(native.value!.retries, 9);
      expect(native.value!.concurrentFragments, 7);
      expect(native.value!.cookiesFilePath, 'NEW-SECRET-COOKIE');
    },
  );

  test(
    'partial trial session preferences retain legacy native credentials',
    () async {
      final native = _SessionBridge()
        ..value = const DownloadSessionConfig(
          useCookies: true,
          cookiesFilePath: 'legacy-cookie',
          visitorData: 'visitor',
          retries: 9,
        );
      final service = YtDlpDownloadService.forTesting(
        nativeBridge: native,
        binaryStatus: const YtDlpBinaryStatus(),
        sessionConfig: DownloadSessionConfig.defaults(),
      );
      addTearDown(service.dispose);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'yt_dlp_session_config_v1',
        jsonEncode({'retries': 3, 'singleVideo': true}),
      );
      await service.reloadPreferencesForTrial();
      expect(service.sessionConfig.retries, 3);
      expect(service.sessionConfig.useCookies, true);
      expect(service.sessionConfig.cookiesFilePath, 'legacy-cookie');
      expect(service.sessionConfig.visitorData, 'visitor');
      native.value = native.value!.copyWith(
        retries: 9,
        visitorData: 'new-visitor',
      );
      await prefs.remove('yt_dlp_session_config_v1');
      await service.reloadPreferencesForTrial();
      expect(service.sessionConfig.retries, 9);
      expect(service.sessionConfig.visitorData, 'new-visitor');
      // Platforms without a native session still return to factory generic
      // values, while private runtime connection metadata survives.
      native.value = null;
      await service.reloadPreferencesForTrial();
      expect(
        service.sessionConfig.retries,
        DownloadSessionConfig.defaults().retries,
      );
      expect(service.sessionConfig.cookiesFilePath, 'legacy-cookie');
    },
  );
}
