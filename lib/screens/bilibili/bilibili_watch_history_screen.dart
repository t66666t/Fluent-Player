import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/screens/bilibili/bilibili_import_buttons.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/theme/app_page_transitions.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/utils/bilibili_image_url.dart';
import 'package:video_player_app/widgets/bilibili_adaptive_list.dart';
import 'package:video_player_app/widgets/bilibili_video_list_tile.dart';
import 'package:video_player_app/widgets/media_library_shell.dart';
import 'package:video_player_app/widgets/desktop_button_click_region.dart';

/// Opens a watch history entry. The default plays it through
/// [watchBilibiliVideo], continuing at the saved part and position.
typedef BilibiliWatchHistoryOpener =
    Future<void> Function(
      BuildContext context,
      BilibiliWatchHistoryEntry entry,
    );

Future<void> openBilibiliWatchHistory(
  BuildContext context, {
  BilibiliPublicApiService? api,
}) {
  return pushAboveMediaLibrary(
    context,
    AppMaterialPageRoute<void>(
      builder: (_) => BilibiliWatchHistoryScreen(api: api),
    ),
  );
}

Future<void> _openThroughCard(
  BuildContext context,
  BilibiliWatchHistoryEntry entry,
) {
  return watchBilibiliVideo(
    context,
    bvid: entry.bvid,
    page: entry.page,
    preview: BilibiliWatchPreview(
      title: entry.title,
      coverUrl: bilibiliCoverThumbnailUrl(entry.coverUrl),
    ),
  );
}

/// Videos watched from the Bilibili pages, newest first.
class BilibiliWatchHistoryScreen extends StatefulWidget {
  const BilibiliWatchHistoryScreen({
    super.key,
    this.api,
    this.history,
    this.onOpen,
    this.fetchCover,
    this.onImport,
  });

  final BilibiliPublicApiService? api;
  final BilibiliHistoryService? history;
  final BilibiliWatchHistoryOpener? onOpen;

  /// Runs the import buttons; defaults to [importBilibiliVideoQuick].
  final BilibiliQuickImporter? onImport;

  /// Cover lookup for entries without one; defaults to the cookie-free
  /// video detail request.
  final BilibiliCoverFetcher? fetchCover;

  @override
  State<BilibiliWatchHistoryScreen> createState() =>
      _BilibiliWatchHistoryScreenState();
}

class _BilibiliWatchHistoryScreenState
    extends State<BilibiliWatchHistoryScreen> {
  late final BilibiliHistoryService _history =
      widget.history ?? BilibiliHistoryService.instance;
  BilibiliPublicApiService? _ownApi;

  @override
  void initState() {
    super.initState();
    unawaited(_fillCovers());
  }

  Future<void> _fillCovers() async {
    final fetch = widget.fetchCover ?? _fetchCoverFromDetail;
    await _history.fillMissingCovers(fetch);
  }

  Future<String?> _fetchCoverFromDetail(String bvid) async {
    final api = widget.api ?? (_ownApi ??= BilibiliPublicApiService());
    final detail = await api.fetchVideoDetail(bvid: bvid);
    return detail.coverUrl;
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空观看历史'),
        content: const Text('只会删除这里的记录，媒体库里的卡片不受影响。'),
        actions: [
          DesktopButtonClickRegion(
            child: TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
          ),
          DesktopButtonClickRegion(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTokens.brandBilibili,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('清空'),
            ),
          ),
        ],
      ),
    );
    if (ok == true) await _history.clearWatch();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _history,
      builder: (context, _) {
        final entries = _history.watchHistory;
        return BilibiliQuietTap(
          child: Scaffold(
            backgroundColor: AppTokens.bgBase,
            appBar: AppBar(
              backgroundColor: AppTokens.bgBase,
              foregroundColor: AppTokens.text1,
              elevation: 0,
              title: const Text('观看历史', style: TextStyle(fontSize: 16)),
              actions: [
                if (entries.isNotEmpty)
                  DesktopButtonClickRegion(
                    child: TextButton(
                      onPressed: _confirmClear,
                      child: const Text(
                        '清空',
                        style: TextStyle(color: AppTokens.text2),
                      ),
                    ),
                  ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: entries.isEmpty
                  ? const _EmptyHistory()
                  : BilibiliAdaptiveList(
                      itemKey: (index) => entries[index].bvid,
                      padding: const EdgeInsets.only(top: 4, bottom: 24),
                      itemCount: entries.length,
                      itemBuilder: (context, index) =>
                          _buildTile(entries[index]),
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTile(BilibiliWatchHistoryEntry entry) {
    final part = <String>[
      if (entry.page > 1 || entry.partTitle.isNotEmpty) 'P${entry.page}',
      if (entry.partTitle.isNotEmpty) entry.partTitle,
    ].join(' · ');
    final watchedAt = formatBilibiliWatchTime(entry.watchedAt);
    final position = entry.positionSeconds > 0
        ? '看到 ${formatBilibiliWatchPosition(entry.positionMs)}'
        : null;
    return BilibiliVideoListTile(
      key: ValueKey<String>('bilibili-watch-${entry.bvid}'),
      onTap: () =>
          unawaited((widget.onOpen ?? _openThroughCard)(context, entry)),
      title: entry.title.isEmpty ? entry.bvid : entry.title,
      coverUrl: bilibiliCoverThumbnailUrl(entry.coverUrl),
      metadata: [
        Text(
          [
            entry.ownerName.isEmpty ? '未知 UP 主' : entry.ownerName,
            if (part.isNotEmpty) part,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTokens.text2, fontSize: 12),
        ),
        Tooltip(
          message: [watchedAt, ?position].join(' · '),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in [watchedAt, ?position])
                Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTokens.text3, fontSize: 11),
                ),
            ],
          ),
        ),
      ],
      actions: BilibiliImportButtons(
        bvid: entry.bvid,
        page: entry.page,
        history: _history,
        onImport: widget.onImport,
        onRemove: () => _history.removeWatch(entry.bvid),
      ),
    );
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history, size: 40, color: AppTokens.text3),
            SizedBox(height: 12),
            Text(
              '还没有观看记录',
              style: TextStyle(color: AppTokens.text1, fontSize: 14),
            ),
            SizedBox(height: 6),
            Text(
              '在 B 站页播放的视频会出现在这里',
              style: TextStyle(color: AppTokens.text3, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// "今天 08:05", "昨天 21:30", "10-03 12:00" or "2025-10-03 12:00".
String formatBilibiliWatchTime(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final clock = '${two(local.hour)}:${two(local.minute)}';
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(current.year, current.month, current.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return '今天 $clock';
  if (diff == 1) return '昨天 $clock';
  if (local.year == current.year) {
    return '${two(local.month)}-${two(local.day)} $clock';
  }
  return '${local.year}-${two(local.month)}-${two(local.day)} $clock';
}

/// "3:07" or "1:02:05" for a playback position in milliseconds.
String formatBilibiliWatchPosition(int positionMs) {
  final total = positionMs < 0 ? 0 : positionMs ~/ 1000;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:${two(minutes)}:${two(seconds)}';
  return '$minutes:${two(seconds)}';
}
