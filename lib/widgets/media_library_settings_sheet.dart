import 'clear_playback_history_setting.dart';
import 'media_library_style_sheet.dart';
import 'media_library_layout_profile.dart';
import 'storage_settings_dialog.dart';
import 'experimental_layout_widgets.dart';
import 'categorized_settings_page.dart';
import 'operation_status.dart';
import 'system_media_notification_setting.dart';
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
import '../models/video_item.dart';
import '../services/library_service.dart';
import '../services/app_haptics.dart';
import '../services/settings_service.dart';
import '../services/desktop_media_session_service.dart';
import 'desktop_media_settings_dialog.dart';
import '../utils/keyboard_shortcut_hints.dart';
import 'keyboard_shortcut_help.dart';
import 'stable_width_label.dart';
import 'clipboard_detection_control.dart';
import 'clipboard_detection_scope.dart';
import '../services/bilibili/bilibili_streaming_service.dart';
import '../features/youtube_download/services/yt_dlp_download_service.dart';
import '../screens/storage_management_screen.dart';
import '../services/app_storage_audit.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/media_playback_service.dart';
import '../services/transcription_manager.dart';
import '../services/ocr_subtitle_manager.dart';
import '../services/video_compose_manager.dart';
import 'package:provider/provider.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

String _formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 KB';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 ? 0 : (value >= 100 ? 0 : 1);
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

/// Phone library sheets use the same 600dp shortest-side breakpoint as the rest
/// of the media library, so tablet/desktop keep the roomier trailing actions.
@visibleForTesting
bool mediaLibraryCacheUsesPhoneLayout(Size size) => size.shortestSide < 600;

@visibleForTesting
const Duration mediaLibraryCacheRowCollapseDuration = Duration(
  milliseconds: 220,
);

@visibleForTesting
ButtonStyle? mediaLibraryCacheActionStyle({required bool compact}) {
  if (!compact) return null;
  // Default TextButtons reserve a 64dp minimum width, which pushes 明细/清除
  // far apart on a phone. Shrink only the compact layout.
  return TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );
}

BilibiliStreamingService? _maybeBilibiliStreamingService(BuildContext context) {
  try {
    return Provider.of<BilibiliStreamingService>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

LibraryService? _maybeLibraryService(BuildContext context) {
  try {
    return Provider.of<LibraryService>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

class _ItemCacheRow {
  final VideoItem item;
  final BilibiliItemCacheBreakdown breakdown;

  const _ItemCacheRow(this.item, this.breakdown);
}

/// Opens the global media-library settings using the same bottom-sheet
/// presentation as the card-style controls.
void showMediaLibrarySettingsBottomSheet(
  BuildContext context,
  SettingsService settings, {
  bool? showSystemMediaNotificationSetting,
}) {
  final streamService = _maybeBilibiliStreamingService(context);
  final library = _maybeLibraryService(context);
  T? optionalService<T>() {
    try {
      return Provider.of<T>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  final bilibili = optionalService<BilibiliDownloadService>();
  final ytDlp = optionalService<YtDlpDownloadService>();
  final playback = optionalService<MediaPlaybackService>();
  final transcription = optionalService<TranscriptionManager>();
  final ocr = optionalService<OcrSubtitleManager>();
  final compose = optionalService<VideoComposeManager>();
  final progressSync = optionalService<ProgressSyncService>();
  final showNotificationSetting =
      showSystemMediaNotificationSetting ??
      platformShowsSystemMediaNotificationSetting();
  final inspectClipboard = ClipboardDetectionScope.maybeOf(
    context,
  )?.inspectClipboard;
  Widget buildSurface(BuildContext context) {
    var restoreLastPage = settings.mediaLibraryRestoreLastPage;
    var startupEntry =
        MediaLibraryRootEntryX.tryParse(settings.mediaLibraryStartupEntry) ??
        MediaLibraryRootEntry.folders;
    var copyImportedMedia = settings.copyImportedMediaToPrivateStorage;
    var useSearchResultsAsQueue = settings.useSearchResultsAsPlaybackQueue;
    var saveBilibiliBackgroundData = settings.bilibiliBackgroundAudioOnly;
    var showMiniPlaybackCard = settings.showMiniPlaybackCard;
    bool? clipboardSaveRetry;
    var clipboardSaveEpoch = 0;
    return StatefulBuilder(
      builder: (context, setSheetState) {
        Future<void> saveClipboardRepeat(bool value) async {
          final epoch = ++clipboardSaveEpoch;
          setSheetState(() => clipboardSaveRetry = null);
          try {
            await settings.updateSetting('skipRepeatedClipboardText', value);
            if (context.mounted && epoch == clipboardSaveEpoch) {
              setSheetState(() => clipboardSaveRetry = null);
            }
          } catch (error) {
            debugPrint('剪贴板提示偏好保存失败: $error');
            if (context.mounted && epoch == clipboardSaveEpoch) {
              setSheetState(() => clipboardSaveRetry = value);
            }
          }
        }

        final items = <Widget>[
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '闲置屏幕保护',
            keywords: '亮屏 烧屏 下载 转录 OCR 屏保',
          ),
          SwitchListTile(
            title: const Text('闲置屏幕保护'),
            subtitle: const Text('任务保持亮屏时，闲置 10 秒进入黑色保护显示。点击、按键或返回即可退出；播放时不启用。降低烧屏风险，不能完全避免。'),
            value: settings.processingScreenProtection,
            onChanged: (value) async {
              await settings.updateSetting('processingScreenProtection', value);
              if (context.mounted) setSheetState(() {});
            },
          ),
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
                        bilibili: bilibili,
                        ytDlp: ytDlp,
                        streaming: streamService,
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
                            MediaLibraryRootEntry.bilibili,
                            MediaLibraryRootEntry.podcasts,
                            MediaLibraryRootEntry.cloudDrive,
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
            ExperimentalSettingsCategory.playback,
            label: 'B 站后台播放',
            keywords: '哔哩哔哩 只加载音频 节省流量',
          ),
          Material(
            color: const Color(0xFF292929),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: SwitchListTile.adaptive(
              key: const ValueKey('bilibiliBackgroundAudioOnly'),
              value: saveBilibiliBackgroundData,
              activeThumbColor: Colors.blueAccent,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 4,
              ),
              title: const Text(
                '后台播放 B 站时只加载音频',
                style: TextStyle(color: Colors.white, fontSize: 15),
              ),
              subtitle: const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '关闭时后台同样加载视频，从迷你播放卡片或通知栏进入播放页可接上画面。开启后仅加载音频以节省流量。',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              onChanged: (value) {
                unawaited(AppHaptics.selectionClick(settings));
                setSheetState(() => saveBilibiliBackgroundData = value);
                unawaited(
                  settings.updateSetting('bilibiliBackgroundAudioOnly', value),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.general,
            label: '自动检测剪贴板链接',
            keywords: '剪贴板 重新复制 重复 提示 识别',
          ),
          ListenableBuilder(
            listenable: settings,
            builder: (context, _) => Column(
              children: [
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('clipboardLinkDetectionEnabled'),
                    value: settings.clipboardLinkDetectionEnabled,
                    activeThumbColor: Colors.blueAccent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    title: const Text(
                      clipboardDetectionLabel,
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    onChanged: (value) {
                      unawaited(AppHaptics.selectionClick(settings));
                      setClipboardDetectionEnabled(settings, value);
                    },
                  ),
                ),
                const SizedBox(height: 10),
                Material(
                  color: const Color(0xFF292929),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('skipRepeatedClipboardText'),
                    value: settings.skipRepeatedClipboardText,
                    activeThumbColor: Colors.blueAccent,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 4,
                    ),
                    title: const Text(
                      '避免重复弹出剪贴板提示',
                      style: TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: clipboardSaveRetry == null
                          ? const Text(
                              '同一次复制只提示一次，重新复制后可再次提示。',
                              style: TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            )
                          : Wrap(
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 8,
                              children: [
                                const Text(
                                  '设置未能保存',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.white70,
                                  ),
                                ),
                                DesktopButtonClickRegion(
                                  child: TextButton(
                                    onPressed: () {
                                      final value = clipboardSaveRetry;
                                      if (value != null) {
                                        unawaited(saveClipboardRepeat(value));
                                      }
                                    },
                                    child: const Text('重试'),
                                  ),
                                ),
                              ],
                            ),
                    ),
                    onChanged: settings.clipboardLinkDetectionEnabled
                        ? (value) {
                            unawaited(AppHaptics.selectionClick(settings));
                            unawaited(saveClipboardRepeat(value));
                          }
                        : null,
                  ),
                ),
                if (inspectClipboard != null)
                  Align(
                    alignment: Alignment.centerRight,
                    child: DesktopButtonClickRegion(
                      child: TextButton.icon(
                        key: const ValueKey('inspectClipboard'),
                        icon: const Icon(Icons.content_paste_search, size: 18),
                        label: const Text('识别剪贴板'),
                        onPressed: () {
                          if (ModalRoute.of(context)?.isCurrent != true) return;
                          inspectClipboard();
                          Navigator.of(context, rootNavigator: true).pop();
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const SettingsCategoryBoundary(
            ExperimentalSettingsCategory.storage,
            label: '清除播放记录',
            keywords: '观看时间 完成状态 继续学习 历史',
          ),
          ClearPlaybackHistorySetting(library: library),
          if (streamService != null) ...[
            const SizedBox(height: 10),
            const SettingsCategoryBoundary(
              ExperimentalSettingsCategory.storage,
              label: '在线视频缓存',
              keywords: 'B 站 哔哩哔哩 清理 空间 明细',
            ),
            MediaLibraryBilibiliCacheSection(
              streamService: streamService,
              library: library,
            ),
          ],
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
            '自动检测剪贴板链接',
            '搜索结果作为播放队列',
            '导入位置与整理',
            '导入媒体',
            'B 站后台播放',
            '媒体通知',
            '桌面媒体控制',
            '模型中心',
            '网络设置',
            '设备同步',
            '存储空间管理',
            '数据目录',
            '在线视频缓存',
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
  ).push<void>(MaterialPageRoute(builder: buildSurface));
}

/// 统一的在线视频缓存管理区块：总量统计 + 按卡片明细（素材文件 / 播放网关
/// 缓存分类）+ 单卡与全局清除。下载中的素材受租约保护，清除时自动转为
/// 延迟删除，不会损坏正在合成/OCR 的任务。
@visibleForTesting
class MediaLibraryBilibiliCacheSection extends StatefulWidget {
  final BilibiliStreamingService? streamService;
  final LibraryService? library;
  final Future<BilibiliStreamCacheReport> Function()? inspectCache;
  final Future<void> Function()? clearCache;

  const MediaLibraryBilibiliCacheSection({
    super.key,
    this.streamService,
    this.library,
    this.inspectCache,
    this.clearCache,
  }) : assert(
         streamService != null || (inspectCache != null && clearCache != null),
       );

  @override
  State<MediaLibraryBilibiliCacheSection> createState() =>
      _MediaLibraryBilibiliCacheSectionState();
}

class _MediaLibraryBilibiliCacheSectionState
    extends State<MediaLibraryBilibiliCacheSection> {
  late Future<BilibiliStreamCacheReport> _reportFuture;
  List<_ItemCacheRow>? _detailRows;
  bool _showDetail = false;
  bool _detailLoading = false;
  bool _detailReadFailed = false;
  bool _clearingAll = false;
  final Set<String> _clearingCardIds = <String>{};
  final Set<String> _collapsingIds = <String>{};

  @override
  void initState() {
    super.initState();
    _reportFuture = _inspectCache();
  }

  Future<BilibiliStreamCacheReport> _inspectCache() {
    return widget.inspectCache?.call() ??
        widget.streamService!.inspectCache(strict: true);
  }

  Future<void> _clearGatewayCache() {
    return widget.clearCache?.call() ?? widget.streamService!.clearCache();
  }

  Future<List<_ItemCacheRow>> _loadRows() async {
    final library = widget.library;
    if (library == null) return const <_ItemCacheRow>[];
    final rows = <_ItemCacheRow>[];
    for (final item in library.onlineCacheItems) {
      try {
        final breakdown = await library.inspectOnlineCacheBreakdown(
          item.id,
          throwOnError: true,
        );
        if (breakdown == null || breakdown.isEmpty) continue;
        rows.add(_ItemCacheRow(item, breakdown));
      } catch (_) {
        rethrow;
      }
    }
    rows.sort(
      (a, b) => b.breakdown.totalBytes.compareTo(a.breakdown.totalBytes),
    );
    return rows;
  }

  Future<void> _ensureDetailRows() async {
    if (_detailRows != null || _detailLoading) return;
    setState(() {
      _detailLoading = true;
      _detailReadFailed = false;
    });
    try {
      final rows = await _loadRows();
      if (mounted) setState(() => _detailRows = rows);
    } catch (_) {
      if (mounted) {
        setState(() {
          _clearFailed = true;
          _detailReadFailed = true;
          _clearMessage = '无法读取缓存明细，请检查存储位置后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _detailLoading = false);
    }
  }

  void _toggleDetail() {
    final opening = !_showDetail;
    setState(() => _showDetail = opening);
    if (opening) unawaited(_ensureDetailRows());
  }

  String? _clearMessage;
  String? _failedItemId;
  bool _clearFailed = false;
  final Map<String, OnlineCacheClearStatus> _itemResults = {};

  Future<void> _refreshAfterClear() async {
    final report = _inspectCache();
    if (mounted) {
      setState(() {
        _reportFuture = report;
      });
    }
    await report;
    if (widget.library != null) {
      final rows = await _loadRows();
      if (mounted) setState(() => _detailRows = rows);
    }
  }

  Future<void> _clearItemCache(String itemId) async {
    final library = widget.library;
    if (library == null || _clearingAll || _clearingCardIds.isNotEmpty) return;
    setState(() {
      _clearingCardIds.add(itemId);
      _clearMessage = null;
    });
    try {
      final result = await library.clearOnlineCacheForItem(itemId);
      if (!mounted) return;
      _itemResults[itemId] = result;
      await _refreshAfterClear();
      if (!mounted) return;
      setState(() {
        _clearFailed = result == OnlineCacheClearStatus.failed;
        _failedItemId = result == OnlineCacheClearStatus.cleared
            ? null
            : itemId;
        _clearMessage = switch (result) {
          OnlineCacheClearStatus.cleared => null,
          OnlineCacheClearStatus.deferred => '缓存正在使用，结束后会清理。',
          OnlineCacheClearStatus.failed => '部分缓存未能清理，条目已保留，请停止使用后重试。',
        };
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _clearFailed = true;
          _failedItemId = itemId;
          _clearMessage = '无法完成清理或确认剩余缓存，请重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _clearingCardIds.remove(itemId));
    }
  }

  Future<void> _clearAll() async {
    if (_clearingAll || _clearingCardIds.isNotEmpty) return;
    setState(() {
      _clearingAll = true;
      _clearMessage = null;
      _failedItemId = null;
    });
    var deferred = 0, failed = 0;
    try {
      final library = widget.library;
      if (library != null) {
        final ids = library.onlineCacheItems.map((item) => item.id).toList();
        for (final id in ids) {
          final result = await library.clearOnlineCacheForItem(id);
          _itemResults[id] = result;
          switch (result) {
            case OnlineCacheClearStatus.cleared:
              break;
            case OnlineCacheClearStatus.deferred:
              deferred++;
            case OnlineCacheClearStatus.failed:
              failed++;
          }
        }
      }
      // A global gateway sweep must not bypass a materialized-track lease.
      if (deferred == 0 &&
          failed == 0 &&
          !(library?.hasOnlineCacheStorageUse ?? false)) {
        await _clearGatewayCache();
      }
      await _refreshAfterClear();
      final after = await _reportFuture;
      if (!mounted) return;
      setState(() {
        _clearFailed = failed > 0 || (after.fileCount > 0 && deferred == 0);
        _clearMessage = _clearFailed
            ? '部分缓存未能清理，请停止使用后重试。'
            : after.fileCount > 0 && deferred > 0
            ? '缓存正在使用，结束后会清理。'
            : null;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _clearFailed = true;
          _clearMessage = '清理未完成，请检查存储位置后重试。未清理的缓存仍会保留。';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _clearingAll = false;
          _collapsingIds.clear();
        });
      }
    }
  }

  Widget _buildActions({required bool compact, required bool waiting}) {
    final style = mediaLibraryCacheActionStyle(compact: compact);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.library != null)
          DesktopButtonClickRegion(
            child: TextButton(
              key: const ValueKey('bilibili-cache-detail-button'),
              style: style,
              onPressed: _clearingAll ? null : _toggleDetail,
              child: StableWidthLabel(
                _showDetail ? '收起' : '明细',
                variants: const ['明细', '收起'],
              ),
            ),
          ),
        DesktopButtonClickRegion(
          child: TextButton(
            key: const ValueKey('bilibili-cache-clear-all-button'),
            style: style,
            onPressed: waiting || _clearingAll
                ? null
                : () => unawaited(_clearAll()),
            // 「清除」与「转圈+清除中」叠放，取较宽者定宽，切换时按钮不变宽。
            child: Stack(
              alignment: Alignment.center,
              children: [
                Visibility(
                  visible: !_clearingAll,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: const Text('清除'),
                ),
                Visibility(
                  visible: _clearingAll,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: compact ? 12 : 14,
                        height: compact ? 12 : 14,
                        child: _clearingAll
                            ? const CircularProgressIndicator(strokeWidth: 2)
                            : null,
                      ),
                      SizedBox(width: compact ? 4 : 6),
                      const Text('清除中'),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader({
    required bool waiting,
    required BilibiliStreamCacheReport? report,
  }) {
    final compact = mediaLibraryCacheUsesPhoneLayout(
      MediaQuery.sizeOf(context),
    );
    const titleStyle = TextStyle(color: Colors.white, fontSize: 15);
    const subtitleStyle = TextStyle(color: Colors.white60, fontSize: 12);
    final title = const Text('Bilibili 在线视频缓存', style: titleStyle);
    final subtitle = Text(
      _clearingAll
          ? '正在清除...'
          : waiting
          ? '正在统计...'
          : '${_formatStorageBytes(report?.bytes ?? 0)} · '
                '${report?.fileCount ?? 0} 个文件',
      style: subtitleStyle,
    );
    final actions = _buildActions(compact: compact, waiting: waiting);

    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.cloud_download_outlined,
                    color: Colors.white70,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [title, const SizedBox(height: 4), subtitle],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Align(alignment: Alignment.centerRight, child: actions),
          ],
        ),
      );
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      leading: const Icon(Icons.cloud_download_outlined, color: Colors.white70),
      title: title,
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: subtitle,
      ),
      trailing: actions,
    );
  }

  Widget _buildDetailRow(_ItemCacheRow row, {required bool compact}) {
    final collapsing = _collapsingIds.contains(row.item.id);
    final clearing = _clearingCardIds.contains(row.item.id);
    return _CollapsingCacheRow(
      collapsing: collapsing,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(
          left: compact ? 12 : 14,
          right: compact ? 4 : 8,
        ),
        title: Text(
          row.item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '素材 ${_formatStorageBytes(row.breakdown.materializedBytes)}'
            ' · 播放缓存 ${_formatStorageBytes(row.breakdown.gatewayBytes)}'
            ' · 共 ${_formatStorageBytes(row.breakdown.totalBytes)}'
            '${_itemResults[row.item.id] == OnlineCacheClearStatus.deferred
                ? ' · 使用结束后清理'
                : _itemResults[row.item.id] == OnlineCacheClearStatus.failed
                ? ' · 清理失败，可重试'
                : ''}',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),
        trailing: clearing
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : DesktopButtonClickRegion(
                child: TextButton(
                  style: mediaLibraryCacheActionStyle(compact: compact),
                  onPressed: _clearingAll || _clearingCardIds.isNotEmpty
                      ? null
                      : () => unawaited(_clearItemCache(row.item.id)),
                  child: const Text('清除'),
                ),
              ),
      ),
    );
  }

  Widget _buildDetailBody({required bool compact}) {
    if (_detailReadFailed && _detailRows == null) {
      return const SizedBox.shrink();
    }
    if (_detailLoading && _detailRows == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final rows = _detailRows ?? const <_ItemCacheRow>[];
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
        child: Text(
          '暂无在线视频缓存',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      );
    }
    return Column(
      children: [
        for (final row in rows) _buildDetailRow(row, compact: compact),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = mediaLibraryCacheUsesPhoneLayout(
      MediaQuery.sizeOf(context),
    );
    return Material(
      color: const Color(0xFF292929),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          FutureBuilder<BilibiliStreamCacheReport>(
            future: _reportFuture,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: OperationStatus(
                    title: '无法统计在线缓存',
                    message: '请检查存储位置后重试。',
                    kind: OperationStatusKind.error,
                    actions: [
                      DesktopButtonClickRegion(
                        child: TextButton(
                          onPressed: () => setState(() {
                            _reportFuture = _inspectCache();
                          }),
                          child: const Text('重新统计'),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return _buildHeader(
                waiting:
                    snapshot.connectionState == ConnectionState.waiting &&
                    !_clearingAll,
                report: snapshot.data,
              );
            },
          ),
          if (_clearMessage != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: OperationStatus(
                title: _clearMessage!,
                kind: _clearFailed
                    ? OperationStatusKind.error
                    : OperationStatusKind.info,
                actions: _detailReadFailed
                    ? [
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: _ensureDetailRows,
                            child: const Text('重读明细'),
                          ),
                        ),
                      ]
                    : !_clearingAll
                    ? [
                        DesktopButtonClickRegion(
                          child: TextButton(
                            onPressed: () => _failedItemId == null
                                ? _clearAll()
                                : _clearItemCache(_failedItemId!),
                            child: const Text('重新清理'),
                          ),
                        ),
                      ]
                    : const [],
              ),
            ),
          if (_showDetail && widget.library != null)
            _buildDetailBody(compact: compact),
        ],
      ),
    );
  }
}

class _CollapsingCacheRow extends StatelessWidget {
  final bool collapsing;
  final Widget child;

  const _CollapsingCacheRow({required this.collapsing, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedOpacity(
        duration: mediaLibraryCacheRowCollapseDuration,
        opacity: collapsing ? 0 : 1,
        child: AnimatedSize(
          duration: mediaLibraryCacheRowCollapseDuration,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: collapsing
              ? const SizedBox(width: double.infinity, height: 0)
              : child,
        ),
      ),
    );
  }
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
