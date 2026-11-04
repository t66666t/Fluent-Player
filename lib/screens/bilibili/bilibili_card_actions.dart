import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import '../../services/bilibili/bilibili_download_service.dart';
import '../../services/bilibili/bilibili_history_service.dart';
import '../../services/bilibili/bilibili_stream_card.dart';
import '../../services/bilibili/bilibili_watch_cards.dart';
import '../../services/bilibili/bilibili_watch_launch.dart';
import '../../services/library_service.dart';
import '../../services/media_playback_service.dart';

typedef BilibiliVideoWatcher =
    Future<void> Function(
      BuildContext context, {
      required String bvid,
      int? page,
      Duration? startAt,
      BilibiliWatchPreview? preview,
    });

/// Compatibility entry used by search/history/uploader pages. Every watch goes
/// directly to the official external player; it creates no native stream card.
Future<void> watchBilibiliVideo(
  BuildContext context, {
  required String bvid,
  int? page,
  Duration? startAt,
  bool? replaceCurrent,
  bool rememberCurrent = false,
  BilibiliWatchPreview? preview,
}) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(const SnackBar(content: Text('社区版仅支持本地媒体，不提供在线播放')));
  return Future<void>.value();
}

Future<void> playBilibiliVideoAsCard(
  BuildContext context, {
  required String bvid,
  required int page,
}) => watchBilibiliVideo(context, bvid: bvid, page: page);

/// Retired native-card API must stay closed even for callers outside the UI.
Future<BilibiliStreamCardBatch> obtainBilibiliPlaybackCard(
  BilibiliDownloadService service,
  LibraryService library, {
  required String bvid,
  required int page,
  BilibiliHistoryService? history,
  bool recordHistory = true,
  void Function(BilibiliWatchHistoryEntry entry)? onHistoryEntry,
}) async => throw UnsupportedError('社区版仅支持本地媒体，在线播放与媒体获取已移除');

Future<void> saveCurrentWatchPosition(
  MediaPlaybackService playback, {
  BilibiliWatchCards? cards,
}) async {
  final current = playback.currentItem;
  if (current == null) return;
  try {
    await playback.persistCurrentProgress(expectedItemId: current.id);
    await (cards ?? BilibiliWatchCards.instance)?.recorder.flush(current.id);
  } catch (error) {
    developer.log('Position before switching not saved', error: error);
  }
}

/// Historical action routes to official playback, with no download fallback.
Future<void> openBilibiliVideoDownload(
  BuildContext context, {
  required String bvid,
  required int page,
  required int partCount,
}) => watchBilibiliVideo(context, bvid: bvid, page: page);
