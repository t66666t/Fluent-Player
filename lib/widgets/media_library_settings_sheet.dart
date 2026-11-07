import '../utils/app_branding.dart';
import 'clear_playback_history_setting.dart';
import 'storage_settings_dialog.dart';
import 'experimental_layout_widgets.dart';
import 'media_library_settings_page.dart';
import 'media_library_settings_controls.dart';
import 'system_media_notification_setting.dart';
import 'processing_screen_protection_settings.dart';
import '../features/onboarding/onboarding_flow.dart';
import 'dart:async';
import '../features/model_center/model_center_screen.dart';
import '../features/model_center/model_center_service.dart';
import '../screens/network_settings_screen.dart';
import '../features/progress_sync/progress_sync_service.dart';
import '../features/progress_sync/progress_sync_screen.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_library_root_entry.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/desktop_media_session_service.dart';
import '../theme/app_page_transitions.dart';
import 'desktop_media_settings_dialog.dart';
import '../screens/storage_management_screen.dart';
import '../services/app_storage_audit.dart';
import '../services/media_playback_service.dart';
import '../services/transcription_manager.dart';
import '../services/ocr_subtitle_manager.dart';
import '../services/video_compose_manager.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

LibraryService? _maybeLibraryService(BuildContext context) {
  try {
    return Provider.of<LibraryService>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

/// Opens media-library settings with the shared full-page transition.
void showMediaLibrarySettingsBottomSheet(
  BuildContext context,
  SettingsService settings, {
  bool? showSystemMediaNotificationSetting,
}) {
  final library = _maybeLibraryService(context);
  T? optionalService<T>() {
    try {
      return Provider.of<T>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  final playback = optionalService<MediaPlaybackService>();
  final transcription = optionalService<TranscriptionManager>();
  final ocr = optionalService<OcrSubtitleManager>();
  final compose = optionalService<VideoComposeManager>();
  final progressSync = optionalService<ProgressSyncService>();
  final showNotificationSetting =
      showSystemMediaNotificationSetting ??
      platformShowsSystemMediaNotificationSetting();
  Widget buildSurface(BuildContext context) {
    var restoreLastPage = settings.mediaLibraryRestoreLastPage;
    var startupEntry =
        MediaLibraryRootEntryX.tryParse(settings.mediaLibraryStartupEntry) ??
        MediaLibraryRootEntry.folders;
    if (!const [
      MediaLibraryRootEntry.folders,
      MediaLibraryRootEntry.continueLearning,
      MediaLibraryRootEntry.recent,
      MediaLibraryRootEntry.podcasts,
    ].contains(startupEntry)) {
      startupEntry = MediaLibraryRootEntry.folders;
    }
    var copyImportedMedia = settings.copyImportedMediaToPrivateStorage;
    var useSearchResultsAsQueue = settings.useSearchResultsAsPlaybackQueue;
    var showMiniPlaybackCard = settings.showMiniPlaybackCard;
    return StatefulBuilder(
      builder: (context, setSheetState) {
        final items = <Widget>[
          KeyedSubtree(
            key: const ValueKey('library-setting-模型中心'),
            child: ListenableBuilder(
              listenable: ModelCenterService.instance,
              builder: (context, _) => MediaLibrarySettingsRow(
                key: const ValueKey('modelCenterSettings'),
                title: const Text('模型中心'),
                description: Text(
                  ModelCenterService.instance.loaded
                      ? ModelCenterService.instance.summary
                      : '转录、翻译与本地模型',
                ),
                onTap: () {
                  final navigator = Navigator.of(context, rootNavigator: true);
                  unawaited(
                    navigator.push<void>(
                      MaterialPageRoute(
                        builder: (_) => const ModelCenterScreen(),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-存储空间管理'),
            child: MediaLibrarySettingsRow(
              key: const ValueKey('storageManagement'),
              title: const Text('存储空间管理'),
              description: const Text('媒体、下载、缓存与回收站'),
              onTap: library == null
                  ? null
                  : () {
                      final audit = AppStorageAudit(
                        library: library,
                        playback: playback,
                        transcription: transcription,
                        ocr: ocr,
                        compose: compose,
                      );
                      final navigator = Navigator.of(
                        context,
                        rootNavigator: true,
                      );
                      navigator.push(
                        MaterialPageRoute<void>(
                          builder: (_) => StorageManagementScreen(
                            service: audit.service,
                            library: library,
                            onDispose: audit.dispose,
                          ),
                        ),
                      );
                    },
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-网络设置'),
            child: MediaLibrarySettingsRow(
              key: const ValueKey('globalNetworkSettings'),
              title: const Text('网络设置'),
              description: const Text('代理与连接方式'),
              onTap: () => unawaited(openNetworkSettings(context)),
            ),
          ),
          if (progressSync != null)
            KeyedSubtree(
              key: const ValueKey('library-setting-设备同步'),
              child: MediaLibrarySettingsRow(
                key: const ValueKey('progressSyncSettings'),
                title: const Text('设备同步'),
                description: const Text('在自己的设备间继续观看'),
                onTap: () {
                  final navigator = Navigator.of(context, rootNavigator: true);
                  unawaited(
                    navigator.push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            ProgressSyncScreen(service: progressSync),
                      ),
                    ),
                  );
                },
              ),
            ),
          KeyedSubtree(
            key: const ValueKey('library-setting-启动页面'),
            child: MediaLibrarySettingsSwitchTile(
              key: const ValueKey('mediaLibraryRestoreLastPage'),
              value: restoreLastPage,
              title: const Text('恢复上次页面'),
              description: Text(restoreLastPage ? '同时恢复文件夹位置' : '固定启动页面'),
              valueControl: restoreLastPage
                  ? null
                  : MediaLibrarySettingsDropdown<MediaLibraryRootEntry>(
                      key: const ValueKey('mediaLibraryStartupEntry'),
                      value: startupEntry,
                      items: [
                        for (final entry in const [
                          MediaLibraryRootEntry.folders,
                          MediaLibraryRootEntry.continueLearning,
                          MediaLibraryRootEntry.recent,
                          MediaLibraryRootEntry.podcasts,
                        ])
                          DropdownMenuItem(
                            key: ValueKey(
                              'mediaLibraryStartupEntry-${entry.storageValue}',
                            ),
                            value: entry,
                            child: Text(entry.label),
                          ),
                      ],
                      onChanged: (entry) {
                        if (entry == null) return;
                        setSheetState(() => startupEntry = entry);
                        unawaited(
                          settings.updateSetting(
                            'mediaLibraryStartupEntry',
                            entry.storageValue,
                          ),
                        );
                      },
                    ),
              onChanged: (value) {
                setSheetState(() => restoreLastPage = value);
                unawaited(
                  settings.updateSetting('mediaLibraryRestoreLastPage', value),
                );
              },
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-迷你播放卡片'),
            child: MediaLibrarySettingsSwitchTile(
              key: const ValueKey('showMiniPlaybackCard'),
              value: showMiniPlaybackCard,
              title: const Text('显示迷你播放卡片'),
              description: const Text('隐藏卡片不影响播放'),
              onChanged: (value) {
                setSheetState(() => showMiniPlaybackCard = value);
                unawaited(
                  settings.updateSetting('showMiniPlaybackCard', value),
                );
              },
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-搜索结果作为播放队列'),
            child: MediaLibrarySettingsSwitchTile(
              key: const ValueKey('useSearchResultsAsPlaybackQueue'),
              value: useSearchResultsAsQueue,
              title: const Text('搜索结果作为播放队列'),
              description: const Text('按结果顺序切集，可跨合集'),
              onChanged: (value) {
                setSheetState(() => useSearchResultsAsQueue = value);
                unawaited(
                  settings.updateSetting(
                    'useSearchResultsAsPlaybackQueue',
                    value,
                  ),
                );
              },
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-导入媒体'),
            child: MediaLibrarySettingsSwitchTile(
              key: const ValueKey('copyImportedMediaToPrivateStorage'),
              value: copyImportedMedia,
              title: const Text('导入时保存副本'),
              description: const Text('新导入存入私有目录，保留原文件'),
              onChanged: (value) {
                // updateSetting applies the runtime value synchronously,
                // notifies all listeners, then persists it asynchronously.
                setSheetState(() => copyImportedMedia = value);
                unawaited(
                  settings.updateSetting(
                    'copyImportedMediaToPrivateStorage',
                    value,
                  ),
                );
              },
            ),
          ),
          if (showNotificationSetting)
            KeyedSubtree(
              key: const ValueKey('library-setting-媒体通知'),
              child: SystemMediaNotificationSetting(
                settings: settings,
                flat: true,
              ),
            ),
          if (DesktopMediaSessionService.isSupportedPlatform)
            KeyedSubtree(
              key: const ValueKey('library-setting-桌面媒体控制'),
              child: MediaLibrarySettingsRow(
                key: const ValueKey('desktopMediaSettings'),
                title: const Text('桌面媒体控制'),
                description: const Text('系统媒体面板、后台播放控制与快捷键'),
                onTap: () => showDesktopMediaSettings(context, settings),
              ),
            ),
          KeyedSubtree(
            key: const ValueKey('library-setting-数据目录'),
            child: MediaLibrarySettingsRow(
              title: const Text('数据目录'),
              description: const Text('查看与迁移大文件存储位置'),
              onTap: () => showAppStorageSettingsDialog(context),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-闲置屏幕保护'),
            child: ProcessingScreenProtectionSettings(settings: settings),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-清除播放记录'),
            child: ClearPlaybackHistorySetting(library: library, flat: true),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-使用前设置'),
            child: MediaLibrarySettingsRow(
              key: const ValueKey('open-onboarding-settings'),
              title: const Text('使用前设置'),
              description: const Text('网络、导入与播放的初始选项'),
              onTap: () =>
                  OnboardingFlow.open(context, settings, preview: true),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-首页布局'),
            child: Tooltip(
              message: '首页布局实验室',
              child: MediaLibrarySettingsRow(
                key: const ValueKey('home-layout-settings'),
                title: const Text('首页布局'),
                description: const Text('切换首页布局；长按入口可排序'),
                onTap: () => showLayoutExperiment(context),
              ),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-开源许可与字体声明'),
            child: MediaLibrarySettingsRow(
              key: const ValueKey('open-source-licenses'),
              title: const Text('开源许可与字体声明'),
              description: const Text('$kAppDisplayName · GPLv3+'),
              onTap: () => showLicensePage(
                context: context,
                applicationName: kAppDisplayName,
              ),
            ),
          ),
          KeyedSubtree(
            key: const ValueKey('library-setting-隐私与联网说明'),
            child: MediaLibrarySettingsRow(
              key: const ValueKey('privacy-notice'),
              title: const Text('隐私与联网说明'),
              onTap: () async {
                final text = await rootBundle.loadString('PRIVACY.md');
                if (!context.mounted) return;
                await showDialog<void>(
                  context: context,
                  builder: (dialog) => AlertDialog(
                    title: const Text('隐私与联网说明'),
                    content: SingleChildScrollView(child: SelectableText(text)),
                    actions: [
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () => Navigator.pop(dialog),
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ];
        return MediaLibrarySettingsPage(items: items);
      },
    );
  }

  Navigator.of(
    context,
    rootNavigator: true,
  ).push<void>(AppMaterialPageRoute(builder: buildSurface));
}
