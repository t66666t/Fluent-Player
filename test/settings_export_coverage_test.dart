import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_settings.dart';
import 'package:video_player_app/features/youtube_download/models/youtube_download_models.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/services/settings_export_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/subtitle_debug_session.dart';

Set<String> _allKeys(Object? value) => {
  if (value is Map)
    for (final entry in value.entries) ...{
      entry.key as String,
      ..._allKeys(entry.value),
    },
  if (value is List)
    for (final child in value) ..._allKeys(child),
};

String _source(String name) => File('lib/$name').readAsStringSync();
Set<String> _literalMapKeys(String source) =>
    RegExp(r"'([^']+)'\s*:").allMatches(source).map((m) => m[1]!).toSet();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'subtitle sidebar toggle defaults on and persists independently',
    () async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      expect(settings.showSubtitleSidebarToggle, isTrue);
      final sidebarVisible = settings.isLandscapeSubtitleSidebarVisible;
      await settings.saveShowSubtitleSidebarToggle(false);
      expect(settings.showSubtitleSidebarToggle, isFalse);
      expect(settings.isLandscapeSubtitleSidebarVisible, sidebarVisible);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          'showSubtitleSidebarToggle',
        ),
        isFalse,
      );
      settings.resetForTest();
      await settings.init();
      expect(settings.showSubtitleSidebarToggle, isFalse);
      await settings.saveShowSubtitleSidebarToggle(true);
      expect(settings.showSubtitleSidebarToggle, isTrue);
    },
  );

  test(
    'every registered preference is exported or explicitly excluded',
    () async {
      SharedPreferences.setMockInitialValues({});
      SubtitleDebugSession.instance.resetForTest();
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final source = _source('services/settings_service.dart');
      final registry = source.substring(
        source.indexOf(
          '  List<_RegisteredSetting<dynamic>> _createRegisteredSettings()',
        ),
        source.indexOf('  Future<void> _loadRegisteredSettings()'),
      );
      const constantKeys = {
        'ImportPlacementRules.settingsKey': ImportPlacementRules.settingsKey,
        'ImportSourceFolders.namesKey': ImportSourceFolders.namesKey,
        'ImportSourceFolders.idsKey': ImportSourceFolders.idsKey,
      };
      final registered = RegExp(r"\bkey:\s*(?:'([^']+)'|([\w.]+))")
          .allMatches(registry)
          .map((m) {
            if (m[1] != null) return m[1]!;
            expect(
              constantKeys,
              contains(m[2]),
              reason: 'Classify the new setting constant ${m[2]}',
            );
            return constantKeys[m[2]]!;
          })
          .toSet();
      expect(registered.length, greaterThan(120));
      final exported = _allKeys(settings.exportSettingsSnapshot());
      final excluded = SettingsService.settingsExportExclusions.keys.toSet();
      expect(
        registered.difference({...exported, ...excluded}),
        isEmpty,
        reason:
            'New settings must be exported or given an explicit exclusion reason.',
      );
      expect(
        exported.intersection(excluded),
        isEmpty,
        reason:
            'A deliberately excluded setting must not appear in the snapshot.',
      );

      final layoutSection = source.substring(
        source.indexOf('  MediaCardStyleSettings homeCardStyleFor'),
        source.indexOf('  /// Whether newly imported media'),
      );
      final layoutKeys = RegExp(
        r"'((?:home|mediaList(?:Rows|Table)?)\w+(?:Portrait|Landscape))'",
      ).allMatches(layoutSection).map((m) => m[1]!).toSet();
      expect(
        SettingsService.mediaLibraryLayoutExportKeys.toSet(),
        layoutKeys,
        reason: 'Every orientation-specific layout slot must be exported.',
      );
    },
  );

  test('mixed model/API/session stores cannot grow unclassified fields', () {
    final aiKeys = const AiChatSettings().toJson().keys.toSet();
    expect({
      ...SettingsExportService.aiChatPreferenceKeys,
      ...SettingsExportService.aiChatExcludedKeys,
    }, aiKeys);
    final sessionKeys = DownloadSessionConfig.defaults()
        .toRuntimeJson()
        .keys
        .toSet();
    expect({
      ...SettingsExportService.ytDlpSessionPreferenceKeys,
      ...SettingsExportService.ytDlpSessionExcludedKeys,
    }, sessionKeys);
    final modelSource = _source(
      'features/model_center/model_center_service.dart',
    );
    final saved = modelSource.substring(
      modelSource.indexOf('  Future<void> save()'),
      modelSource.indexOf('    final write = _writes.then'),
    );
    expect({
      ...SettingsExportService.modelPreferenceKeys,
      ...SettingsExportService.modelExcludedKeys,
    }, _literalMapKeys(saved));
    expect(
      SettingsExportService.aiChatPreferenceKeys.intersection(
        SettingsExportService.aiChatExcludedKeys,
      ),
      isEmpty,
    );
    expect(
      SettingsExportService.ytDlpSessionPreferenceKeys.intersection(
        SettingsExportService.ytDlpSessionExcludedKeys,
      ),
      isEmpty,
    );
    expect(
      SettingsExportService.modelPreferenceKeys.intersection(
        SettingsExportService.modelExcludedKeys,
      ),
      isEmpty,
    );
  });

  test('all persistent preference owners have an audited export policy', () {
    // Owner-level guard catches new pages/stores, including those whose keys
    // are constants/dynamic. Field-level guards above cover the central and
    // mixed stores. Full settings-only models are serialized with toJson().
    const policies = <String, String>{
      'features/onboarding/onboarding_store.dart':
          'first-run completion is local and excluded from exported preferences',
      'screens/home_screen.dart':
          'shared export action; navigation/hidden-button state excluded',
      'screens/collection_screen.dart':
          'shared export action; hidden-button state excluded',
      'features/ai_chat/ai_chat_settings.dart':
          'generic preferences; connections/models/secrets excluded',
      'features/ai_chat/ai_chat_typography.dart': 'reading scale',
      'features/ai_chat/ai_quick_prompts.dart':
          'shared quick prompt names, complete text and ordering',
      'features/cloud_drive/services/cloud_drive_view_preferences.dart':
          'provider and views; account identities excluded',
      'features/cloud_drive/presentation/cloud_drive_screen.dart':
          'uses CloudDriveViewPreferences',
      'features/douyin_download/douyin_browser_history.dart':
          'personal browser history excluded',
      'features/douyin_download/douyin_download_preferences.dart':
          'manual capture preference',
      'features/portable_transfer/portable_export_settings_memory.dart':
          'both format profiles',
      'features/subtitle_search/subtitle_search_workspace.dart':
          'credentials, search history and media drafts excluded',
      'features/web_media/web_media_browser_preferences.dart':
          'desktop mode; bookmarks, history and resume identity excluded',
      'features/web_media/web_media_download_queue.dart':
          'queue preferences; tasks and cleanup excluded',
      'features/youtube_download/services/yt_dlp_binary_location_store.dart':
          'machine-specific executable/path setup excluded',
      'features/youtube_download/services/yt_dlp_download_service.dart':
          'download/session preferences; tasks/accounts/paths excluded',
      'services/ai_subtitle_api_settings.dart':
          'model/endpoint/secret connection setup excluded',
      'services/ai_subtitle_translator.dart':
          'batch/concurrency/reflection/prompt',
      'services/app_storage_service.dart':
          'machine-specific data locations and migrations excluded',
      'services/bilibili/bilibili_danmaku_auto_update.dart':
          'per-media update bookkeeping excluded; global switch in SettingsService',
      'services/bilibili/bilibili_device_identity.dart':
          'device/login identity excluded',
      'services/bilibili/bilibili_download_service.dart':
          'all general download preferences; paths/tasks excluded',
      'services/bilibili/bilibili_history_service.dart':
          'personal histories excluded; recording switches in SettingsService',
      'services/bilibili/bilibili_offline_details.dart':
          'media-bound episode/folder data excluded',
      'services/bilibili/bilibili_streaming_service.dart':
          'preferred streaming quality; stream cache excluded',
      'services/library_service.dart':
          'library/media records and local output paths excluded',
      'services/clipboard_link_history.dart':
          'device-local prompt fingerprints excluded; master switch and repeat preference in SettingsService',
      'services/media_playback_service.dart':
          'mute shared with SettingsService; playback session excluded',
      'services/network/network_settings_service.dart':
          'global/feature modes; custom proxy endpoints/credentials excluded',
      'services/ocr_subtitle_manager.dart':
          'OCR model choices, per-video tracks/regions/jobs and machine benchmarks excluded',
      'services/playback_state_store.dart': 'playback history/session excluded',
      'services/startup_notification_permission.dart':
          'device-local notification prompt history excluded',
      'services/settings_export_service.dart': 'read-only export coordinator',
      'services/default_settings_trial.dart':
          'immutable local trial backups excluded; never export original settings or trial status',
      'services/settings_service.dart':
          'registered-preference and layout-slot coverage guards',
      'services/sleep_timer_controller.dart':
          'remembered choices only; active countdown excluded',
      'services/subtitle_debug_session.dart':
          'all presets/customizations and independent ghost scales',
      'services/subtitle_font_service.dart':
          'per-subtitle language/path annotations and font assets excluded; font choices in styles',
      'services/subtitle_position_store.dart':
          'all global/preset video/audio/ghost positions',
      'services/subtitle_translate_settings.dart':
          'directions/languages/smart policy; provider/model choice excluded',
      'services/transcription_hotword_store.dart':
          'named presets exported; per-media hotwords excluded',
      'widgets/subtitle_management_sheet.dart':
          'manual translation preferences; subtitle file paths excluded',
    };
    final owners = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where(
          (f) => f.readAsStringSync().contains(
            'package:shared_preferences/shared_preferences.dart',
          ),
        )
        .map((f) => f.path.replaceAll('\\', '/').substring(4))
        .toSet();
    expect(
      owners.difference(policies.keys.toSet()),
      isEmpty,
      reason:
          'Audit new persistent stores before shipping: export their portable settings and document exclusions.',
    );
    expect(
      policies.keys.toSet().difference(owners),
      isEmpty,
      reason: 'Remove stale audit entries when a store is retired.',
    );
  });

  test(
    'direct preference keys and mixed browser/timer records stay classified',
    () async {
      SharedPreferences.setMockInitialValues({});
      SubtitleDebugSession.instance.resetForTest();
      final settings = SettingsService()..resetForTest();
      await settings.init();
      final coreKeys = _allKeys(settings.exportSettingsSnapshot());
      final exporterSource = _source('services/settings_export_service.dart');
      final exporterLiterals = RegExp(
        r"'([^'\r\n]+)'",
      ).allMatches(exporterSource).map((m) => m[1]!).toSet();
      const aliases = <String, String>{
        'subtitleTextStyle': 'textStyle',
        'subtitleLayoutLandscape': 'layoutLandscape',
        'subtitleLayoutPortrait': 'layoutPortrait',
        'subtitleLayoutGhostLandscape': 'ghostLayoutLandscape',
        'subtitleLayoutGhostPortrait': 'ghostLayoutPortrait',
        'audioSubtitleTextStyle': 'audioTextStyle',
        'audioSubtitleLayoutLandscape': 'audioLayoutLandscape',
        'audioSubtitleLayoutPortrait': 'audioLayoutPortrait',
        'subtitleStyle': 'subtitleStyleLandscape',
        'subtitlePresets': 'presets',
        'subtitleOffset': 'subtitleDelayMs',
        'sidebarFontSizeScale': 'landscapeSidebarFontSizeScale',
        'ghostSubtitleFontSize': 'fontSize',
        'ghostSubtitleLetterSpacing': 'letterSpacing',
      };
      expect(aliases.values.toSet().difference(coreKeys), isEmpty);
      const excluded = <String, String>{
        r'cloudDrive.$provider.account': 'account identity',
        'subtitle_search_drafts_v1': 'media-specific drafts',
        'transcription_video_hotwords_v1': 'media-specific hotwords',
        'subtitle_search_recent_v1': 'search history',
        'web_media_native_queue_v1': 'tasks',
        'web_media_waiting_queue_v1': 'tasks',
        r'${_taskStateV2PrefsKey}_backup': 'task backup',
        'show_export_settings_button': 'hidden developer entry',
        'playback_state_snapshot': 'playback session',
        'largeDataRootPath': 'device path',
        'bilibili_custom_download_path': 'device path',
        r'ocrSubtitlePerformanceV2.${Platform.operatingSystem}.${Platform.numberOfProcessors}':
            'device benchmark',
        'subtitleFontLanguages': 'per-subtitle paths and language annotations',
        'videoComposeCustomOutputPath': 'device path',
        'videoComposePrimarySubtitlePath': 'media-specific subtitle file',
        'videoComposeSecondarySubtitlePath': 'media-specific subtitle file',
        'subtitle_download_path': 'device path',
      };
      final directKeys = <String>{};
      for (final file in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        directKeys.addAll(
          RegExp(
            r"\.(?:get|set)(?:StringList|String|Int|Double|Bool)\(\s*'([^']+)'",
          ).allMatches(file.readAsStringSync()).map((m) => m[1]!),
        );
      }
      expect(
        directKeys.difference({
          ...coreKeys,
          ...exporterLiterals,
          ...aliases.keys,
          'cloudDrive.lastProvider',
          r'cloudDrive.$provider.view',
          ...excluded.keys,
          ...SettingsService.settingsExportExclusions.keys,
        }),
        isEmpty,
        reason:
            'Classify new direct preference keys, including unregistered settings.',
      );
      final browserSource = _source(
        'features/web_media/web_media_browser_preferences.dart',
      );
      final browserRecord = browserSource.substring(
        browserSource.indexOf('jsonEncode({'),
        browserSource.indexOf("if (!saved) throw StateError"),
      );
      expect(
        _literalMapKeys(browserRecord),
        {
          'desktopMode',
          'shortcuts',
          'sites',
          'history',
          'resumePage',
          'resumeHome',
        },
        reason: 'New browser options need an export/exclusion decision.',
      );
      final timerSource = _source('services/sleep_timer_controller.dart');
      final timerKeys = RegExp(
        r"static const String _\w+Key = '([^']+)'",
      ).allMatches(timerSource).map((m) => m[1]!).toSet();
      expect(
        timerKeys.difference(exporterLiterals),
        {
          'sleepTimer.mode',
          'sleepTimer.deadlineMs',
          'sleepTimer.playbackRemainingMs',
          'sleepTimer.remainingItemCount',
          'sleepTimer.scheduledItemCount',
          'sleepTimer.awaitingCurrentItemEnd',
        },
        reason:
            'Only active timer state is excluded; new persistent choices must be exported.',
      );
    },
  );

  test('file-backed stores, cache journal and encrypted sync stay audited', () {
    const jsonStores = <String, String>{
      'media_cache.json':
          'general preferences exported; tasks/variants excluded',
      'model_center.json':
          'processing preferences exported; models/accounts/jobs excluded',
      'library.json': 'library contents and per-media/folder settings excluded',
      'bilibili_watch_playlist.json': 'personal watch queue excluded',
      'bilibili_download_tasks.json': 'download tasks excluded',
      'compose_tasks.json': 'per-video jobs excluded',
      'transcription_slice_checkpoints.json': 'recognition progress excluded',
      'transcription_queue_cache.json': 'recognition tasks excluded',
      'transient_cards.json': 'temporary media excluded',
      'batch_import_state.json': 'import progress excluded',
      'batch_import_cache.json': 'import progress excluded',
      'storage_runtime_registry.json': 'device paths excluded',
      'cloud_drive_accounts.json': 'account data excluded',
    };
    expect(
      AppStorageService.ownedNames
          .where((name) => name.endsWith('.json'))
          .toSet(),
      jsonStores.keys.toSet(),
      reason:
          'Audit newly registered JSON stores, including preferences nested in task journals.',
    );
    final cache = _source('features/media_cache/media_cache_service.dart');
    final cacheSave = cache.substring(
      cache.indexOf('  Future<void> _save()'),
      cache.indexOf(
        '    final operation = _writes.catchError',
        cache.indexOf('  Future<void> _save()'),
      ),
    );
    expect(_literalMapKeys(cacheSave), {
      'version',
      'preferences',
      'tasks',
      'variants',
    });
    final sync = _source('features/progress_sync/progress_sync_service.dart');
    final syncSave = sync.substring(
      sync.indexOf('  Future<void> _persist()'),
      sync.indexOf('  void _notify()'),
    );
    expect(
      _literalMapKeys(syncSave),
      {
        'version',
        'enabled',
        'deviceId',
        'deviceName',
        'privateKey',
        'trustedKeys',
        'sequence',
        'localSignatures',
        'localClocks',
        'pairedNames',
        'groups',
        'envelopes',
        'fingerprints',
        'folderCatalogs',
        'pausedFolderFiles',
        'revokedFolderGroups',
        'folderTransfers',
        'webDav',
        'url',
        'username',
        'password',
      },
      reason:
          'Only the global enabled switch is portable; classify any new global setting.',
    );
  });

  test('both hidden buttons and keyboard shortcuts use the shared exporter', () {
    for (final page in ['home_screen.dart', 'collection_screen.dart']) {
      final source = _source('screens/$page');
      expect(
        source,
        contains(
          'Future<void> _exportSettingsSnapshot() => exportAppSettings(context);',
        ),
      );
      expect(source, isNot(contains("'schemaVersion': 1")));
      expect(source, contains('onLongPress: _toggleExportButtonVisibility'));
      expect(
        source,
        contains('DesktopMediaManagementShortcutAction.exportSettings'),
      );
    }
  });
}
