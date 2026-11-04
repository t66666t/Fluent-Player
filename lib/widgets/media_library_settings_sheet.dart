import 'clear_playback_history_setting.dart';
import '../features/external_ai/external_ai_screen.dart';
import '../features/external_ai/external_ai_preferences.dart';
import 'media_library_style_sheet.dart';
import 'media_library_layout_profile.dart';
import 'storage_settings_dialog.dart';
import 'experimental_layout_widgets.dart';
import 'categorized_settings_page.dart';
import 'system_media_notification_setting.dart';
import 'processing_screen_protection_settings.dart';
import '../features/onboarding/onboarding_flow.dart';
import 'dart:async';
import '../features/model_center/model_center_screen.dart';
import '../features/model_center/model_center_service.dart';
import '../screens/network_settings_screen.dart';
import '../features/progress_sync/progress_sync_service.dart';
import '../features/progress_sync/progress_sync_screen.dart';
import '../screens/import_location_settings_screen.dart';
import '../models/import_card_placement.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/media_library_root_entry.dart';
import '../services/library_service.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../services/desktop_media_session_service.dart';
import '../theme/app_page_transitions.dart';
import 'desktop_media_settings_dialog.dart';
import '../utils/keyboard_shortcut_hints.dart';
import 'keyboard_shortcut_help.dart';
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
    ].contains(startupEntry)) {
      startupEntry = MediaLibraryRootEntry.folders;
    }
    var copyImportedMedia = settings.copyImportedMediaToPrivateStorage;
    var useSearchResultsAsQueue = settings.useSearchResultsAsPlaybackQueue;
    var showMiniPlaybackCard = settings.showMiniPlaybackCard;
    return StatefulBuilder(
      builder: (context, setSheetState) {
        final items = <Widget>[
          if (ExternalAiPreferences.isDesktopSupported) ...[
            const SettingsCategoryBoundary(
              ExperimentalSettingsCategory.general,
              label: '连接外部 AI',
              keywords: 'MCP Agent Codex WorkBuddy 千问 文稿 媒体库',
            ),
            ListTile(
              leading: const Icon(Icons.hub_outlined),
              title: const Text('连接外部 AI'),
              subtitle: const Text('让 Codex、WorkBuddy 等读取媒体库和文稿'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(AppMaterialPageRoute<void>(
                builder: (_) => const ExternalAiScreen(),
              )),
            ),
          ],
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '闲置屏幕保护',
            keywords: '亮屏 烧屏 等待 时间 秒 转录 OCR 屏保',
          ),
          ProcessingScreenProtectionSettings(settings: settings),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '卡片与列表样式',
            keywords: '外观 字号 大小 间距',
          ),
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('卡片与列表样式'),
            subtitle: const Text('字号、大小与间距'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => MediaLibraryStyleSheet.show(
              context: context,
              scope: MediaLibraryCardStyleScope.home,
            ),
          ),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.storage,
            label: '数据目录',
            keywords: '迁移 存储位置 文件夹 路径',
          ),
          ListTile(
            leading: const Icon(Icons.drive_file_move_outlined),
            title: const Text('数据目录'),
            subtitle: const Text('查看与迁移大文件存储位置'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showAppStorageSettingsDialog(context),
          ),
          const SizedBox(height: 10),
          if (KeyboardShortcutHints.of(context)) ...[
            const SettingsCategoryBoundary(
              ExperimentalSettingsCategory.general,
              label: '键盘快捷键',
              keywords: '快捷键 按键 键盘 帮助',
            ),
            ListTile(
              key: const ValueKey('keyboardShortcutSettings'),
              leading: const Icon(Icons.keyboard_outlined),
              title: const Text('键盘快捷键'),
              subtitle: const Text('查看页面操作与播放控制的按键说明'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showKeyboardShortcutHelp(context),
            ),
            const SizedBox(height: 10),
          ],
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.playback,
            label: '桌面媒体控制',
            keywords: '快捷键 后台 系统媒体面板',
          ),
          if (DesktopMediaSessionService.isSupportedPlatform) ...[
            ListTile(
              key: const ValueKey('desktopMediaSettings'),
              leading: const Icon(Icons.media_bluetooth_on_outlined),
              title: const Text('桌面媒体控制'),
              subtitle: const Text('系统媒体面板、后台播放控制与快捷键'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showDesktopMediaSettings(context, settings),
            ),
            const SizedBox(height: 10),
          ],
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.models,
            label: '模型中心',
            keywords: '语音转录 字幕 翻译 AI OCR 下载 服务',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            child: ListenableBuilder(
              listenable: ModelCenterService.instance,
              builder: (context, _) => ListTile(
                key: const ValueKey('modelCenterSettings'),
                leading: const Icon(
                  Icons.memory_rounded,
                  color: Colors.blueAccent,
                ),
                title: const Text(
                  '模型中心',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  ModelCenterService.instance.loaded
                      ? ModelCenterService.instance.summary
                      : '转录与翻译服务 · 本地模型与下载',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Colors.white60,
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
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.network,
            label: '设备同步',
            keywords: '局域网 进度 文件夹',
          ),
          if (progressSync != null) ...[
            Material(
              color: const Color(0xFF292929),
              borderRadius: BorderRadius.circular(12),
              child: ListTile(
                key: const ValueKey('progressSyncSettings'),
                leading: const Icon(
                  Icons.sync_rounded,
                  color: Colors.blueAccent,
                ),
                title: const Text(
                  '设备同步',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  '在自己的设备间继续观看',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Colors.white60,
                ),
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
            const SizedBox(height: 10),
          ],
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.network,
            label: '网络设置',
            keywords: '代理 直连 连接',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              key: const ValueKey('globalNetworkSettings'),
              leading: const Icon(
                Icons.language_outlined,
                color: Colors.blueAccent,
              ),
              title: const Text('网络设置', style: TextStyle(color: Colors.white)),
              trailing: const Icon(Icons.chevron_right, color: Colors.white60),
              onTap: () => unawaited(openNetworkSettings(context)),
            ),
          ),
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.storage,
            label: '存储空间管理',
            keywords: '清理 媒体 回收站 下载 缓存 字幕 遗留文件',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            child: ListTile(
              key: const ValueKey('storageManagement'),
              leading: const Icon(
                Icons.donut_large_outlined,
                color: Colors.blueAccent,
              ),
              title: const Text(
                '存储空间管理',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              subtitle: const Text(
                '查看媒体、回收站、下载、缓存及遗留文件的详细占用，并按分类清理。',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right, color: Colors.white60),
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
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.playback,
            label: '迷你播放卡片',
            keywords: '显示 隐藏 底部',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile.adaptive(
              key: const ValueKey('showMiniPlaybackCard'),
              value: showMiniPlaybackCard,
              activeThumbColor: Colors.blueAccent,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              title: const Text(
                '显示迷你播放卡片',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '关闭后底部播放卡片收起，正在播放的内容不会停。',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              onChanged: (value) {
                unawaited(AppHaptics.selectionClick(settings));
                setSheetState(() => showMiniPlaybackCard = value);
                unawaited(
                  settings.updateSetting('showMiniPlaybackCard', value),
                );
              },
            ),
          ),
          if (showNotificationSetting) ...[
            const SizedBox(height: 10),
            const SettingsCategoryBoundary(
              ExperimentalSettingsCategory.playback,
              label: '媒体通知',
              keywords: '通知栏 锁屏 系统播放控件 权限',
            ),
            SystemMediaNotificationSetting(settings: settings),
          ],
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '启动页面',
            keywords: '打开时 回到上次 页面 文件夹 继续学习 最近添加',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                SwitchListTile.adaptive(
                  key: const ValueKey('mediaLibraryRestoreLastPage'),
                  value: restoreLastPage,
                  activeThumbColor: Colors.blueAccent,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  title: const Text(
                    '打开时回到上次离开的页面',
                    style: TextStyle(color: Colors.white, fontSize: 15),
                  ),
                  subtitle: const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      '包括上次打开的文件夹。关闭后，使用下方指定的启动页面。',
                      style: TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                  onChanged: (value) {
                    unawaited(AppHaptics.selectionClick(settings));
                    setSheetState(() => restoreLastPage = value);
                    unawaited(
                      settings.updateSetting(
                        'mediaLibraryRestoreLastPage',
                        value,
                      ),
                    );
                  },
                ),
                if (!restoreLastPage)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final entry in const [
                            MediaLibraryRootEntry.folders,
                            MediaLibraryRootEntry.continueLearning,
                            MediaLibraryRootEntry.recent,
                          ])
                            ChoiceChip(
                              key: ValueKey(
                                'mediaLibraryStartupEntry-${entry.storageValue}',
                              ),
                              label: Text(entry.label),
                              selected: startupEntry == entry,
                              showCheckmark: false,
                              selectedColor: const Color(0xFF294771),
                              backgroundColor: const Color(0xFF333333),
                              side: BorderSide.none,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              labelStyle: TextStyle(
                                fontSize: 13,
                                color: startupEntry == entry
                                    ? const Color(0xFFB8D5FF)
                                    : Colors.white70,
                              ),
                              onSelected: (_) {
                                setSheetState(() => startupEntry = entry);
                                unawaited(
                                  settings.updateSetting(
                                    'mediaLibraryStartupEntry',
                                    entry.storageValue,
                                  ),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '导入媒体',
            keywords: '复制 私有目录 原文件',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile.adaptive(
              key: const ValueKey('copyImportedMediaToPrivateStorage'),
              value: copyImportedMedia,
              activeThumbColor: Colors.blueAccent,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              title: const Text(
                '导入时复制媒体到应用私有目录',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '仅对新导入生效，原文件不变。临时来源仍会保存必要副本。',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              onChanged: (value) {
                // updateSetting applies the runtime value synchronously,
                // notifies all listeners, then persists it asynchronously.
                unawaited(AppHaptics.selectionClick(settings));
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
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '导入位置与整理',
            keywords: '卡片 放置 文件夹 合集',
          ),
          _ImportCardPlacementSection(settings: settings, library: library),
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.playback,
            label: '搜索结果作为播放队列',
            keywords: '搜索列表 切集',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile.adaptive(
              key: const ValueKey('useSearchResultsAsPlaybackQueue'),
              value: useSearchResultsAsQueue,
              activeThumbColor: Colors.blueAccent,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              title: const Text(
                '搜索结果作为播放队列',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '开启后按搜索列表切集，可能跳到其他合集。',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              onChanged: (value) {
                unawaited(AppHaptics.selectionClick(settings));
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
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.storage,
            label: '清除播放记录',
            keywords: '观看时间 完成状态 继续学习 历史',
          ),
          ClearPlaybackHistorySetting(library: library),
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '使用前设置',
            keywords: '首次 新手 网络 账号 导入 字幕',
          ),
          ListTile(
            key: const ValueKey('open-onboarding-settings'),
            leading: const Icon(Icons.explore_outlined),
            title: const Text('使用前设置'),
            subtitle: const Text('重新查看网络、账号、导入和播放选项；修改直接生效。'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => OnboardingFlow.open(context, settings, preview: true),
          ),
          const ListTile(
            leading: Icon(Icons.swap_horiz),
            title: Text('调整首页入口顺序'),
            subtitle: Text('在入口横条或侧栏上长按入口，然后拖动排序。'),
          ),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.about,
            label: '开源许可与字体声明',
            keywords: '关于 GPL Fluent Player',
          ),
          ListTile(
            key: const ValueKey('open-source-licenses'),
            leading: const Icon(Icons.info_outline, color: Colors.white60),
            title: const Text(
              '开源许可与字体声明',
              style: TextStyle(color: Colors.white),
            ),
            subtitle: const Text(
              'Fluent Player · GPLv3+',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Fluent Player',
            ),
          ),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.about,
            label: '隐私与联网说明',
            keywords: '权限 数据',
          ),
          ListTile(
            key: const ValueKey('privacy-notice'),
            leading: const Icon(
              Icons.description_outlined,
              color: Colors.white60,
            ),
            title: const Text('隐私与联网说明', style: TextStyle(color: Colors.white)),
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
        ];
        return CategorizedSettingsPage(
          items: items,
          priorityLabels: const [
            '闲置屏幕保护',
            '卡片与列表样式',
            '启动页面',
            '迷你播放卡片',
            '搜索结果作为播放队列',
            '导入位置与整理',
            '导入媒体',
            '媒体通知',
            '桌面媒体控制',
            '模型中心',
            '网络设置',
            '设备同步',
            '存储空间管理',
            '数据目录',
            '清除播放记录',
            '使用前设置',
            '开源许可与字体声明',
            '隐私与联网说明',
          ],
        );
      },
    );
  }

  Navigator.of(
    context,
    rootNavigator: true,
  ).push<void>(AppMaterialPageRoute(builder: buildSurface));
}

class _ImportCardPlacementSection extends StatelessWidget {
  const _ImportCardPlacementSection({
    required this.settings,
    required this.library,
  });
  final SettingsService settings;
  final LibraryService? library;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: settings,
    builder: (context, _) => Material(
      color: const Color(0xFF292929),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: const ValueKey('import-location-settings'),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        title: const Text(
          '导入位置与整理',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        subtitle: Text(
          '${settings.importCardPlacementMode.label}${settings.importPlacementRules.overrides.isEmpty ? '' : ' · ${settings.importPlacementRules.overrides.length} 项单独设置'}',
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
        trailing: const Icon(
          Icons.chevron_right_rounded,
          color: Colors.white54,
        ),
        onTap: () => Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => ImportLocationSettingsScreen(
              settings: settings,
              library: library,
            ),
          ),
        ),
      ),
    ),
  );
}
