import 'package:flutter/widgets.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';

import '../features/progress_sync/progress_sync_service.dart';
import '../features/ai_chat/ai_chat_typography.dart';
import '../features/web_media/web_media_download_queue.dart';
import '../features/youtube_download/services/yt_dlp_download_service.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/library_service.dart';
import '../services/media_playback_service.dart';
import '../services/settings_export_service.dart';
import '../services/settings_service.dart';
import '../services/subtitle_translate_settings.dart';
import '../utils/app_toast.dart';

T? _optional<T>(BuildContext context) {
  try {
    return context.read<T>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Home, folder pages and desktop shortcuts share the same export operation.
Future<void> exportAppSettings(BuildContext context) async {
  try {
    final library = _optional<LibraryService>(context);
    final exporter = SettingsExportService();
    final snapshot = await exporter.buildSnapshot(
      settings: context.read<SettingsService>(),
      viewportSize: MediaQuery.sizeOf(context),
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      bilibili: _optional<BilibiliDownloadService>(context),
      ytDlp: _optional<YtDlpDownloadService>(context),
      translation: _optional<SubtitleTranslateSettings>(context),
      sleepTimer: _optional<MediaPlaybackService>(context)?.sleepTimer,
      webQueueSettings: library == null
          ? null
          : WebMediaDownloadQueue.settingsForLibrary(library),
      readingSettings: AiChatReadingSettings.instance,
      syncPreferences: _optional<ProgressSyncService>(
        context,
      )?.exportSettingsSnapshot,
    );
    final file = await exporter.writeSnapshot(snapshot);
    if (!context.mounted) return;
    final result = await OpenFilex.open(file.path, type: 'application/json');
    if (!context.mounted) return;
    AppToast.show(
      result.type == ResultType.done
          ? '设置已导出并打开: ${file.path}'
          : '设置已导出，但打开失败: ${file.path}',
      type: result.type == ResultType.done
          ? AppToastType.success
          : AppToastType.error,
    );
  } catch (error) {
    if (!context.mounted) return;
    AppToast.show('导出失败: $error', type: AppToastType.error);
  }
}
