import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../models/bilibili_browse_models.dart';
import '../../models/bilibili_models.dart';
import '../../models/video_item.dart';
import '../library_service.dart';
import '../media_playback_service.dart';
import '../playlist_manager.dart';
import '../settings_service.dart';
import 'bilibili_download_service.dart';
import 'bilibili_history_service.dart';
import 'bilibili_player_video.dart';
import 'bilibili_watch_cards.dart';
import 'bilibili_watch_launch.dart';
import 'bilibili_watch_playlist.dart';

typedef BilibiliPartSwitcher =
    Future<void> Function(
      BuildContext context,
      BilibiliVideoDetail detail,
      int page,
    );

/// Replace this video's entries with its ordered parts, preserving the
/// surrounding queue and the identities of unrelated cards.
List<VideoItem> projectBilibiliPartsQueue({
  required List<VideoItem> queue,
  required String bvid,
  required List<VideoItem> parts,
}) {
  final result = <VideoItem>[];
  var inserted = false;
  for (final item in queue) {
    if (bilibiliPlayerVideoOf(item)?.bvid == bvid) {
      if (!inserted) result.addAll(parts);
      inserted = true;
    } else {
      result.add(item);
    }
  }
  if (!inserted) result.addAll(parts);
  return result;
}

/// Part selection never imports, even with auto-import-on-play enabled.
/// Missing parts are lightweight, transient entries; their player data is
/// filled by the same playback hooks as ordinary temporary Bilibili cards.
Future<BilibiliWatchPlan> prepareBilibiliPartSwitch({
  required BilibiliDownloadService service,
  required LibraryService library,
  required BilibiliVideoInfo info,
  required int page,
  required List<VideoItem> existingQueue,
  VideoItem? currentItem,
  BilibiliHistoryService? history,
  BilibiliWatchCards? cards,
  bool Function()? isCancelled,
}) async {
  if (!info.pages.any((part) => part.page == page && part.cid > 0)) {
    throw StateError('这个分P暂时无法播放，请刷新视频详情后重试');
  }
  final watchHistory = history ?? BilibiliHistoryService.instance;
  await watchHistory.ensureLoaded();
  if (isCancelled?.call() ?? false) {
    throw const BilibiliWatchCancelledException();
  }
  final created = <String>{};
  final preferredItems = <VideoItem>[?currentItem, ...existingQueue];
  try {
    VideoItem? selected;
    for (final item in preferredItems) {
      final video = bilibiliPlayerVideoOf(item);
      if (!item.isRecycled && video?.bvid == info.bvid && video?.page == page) {
        selected = item;
        break;
      }
    }
    if (selected == null) {
      final result = await service.obtainWatchCard(
        library,
        bvid: info.bvid,
        page: page,
        videoInfo: info,
        deferPlayerData: true,
      );
      selected = result.item;
      if (result.created && selected.isTransient) created.add(selected.id);
    }
    final item = selected;
    final saved = watchHistory.watchEntryOf(info.bvid);
    if (item.isTransient &&
        item.lastPositionMs <= 0 &&
        SettingsService().bilibiliRecordWatchHistory &&
        saved?.page == page) {
      item.lastPositionMs = saved!.positionMs;
    }
    final parts = await bilibiliWatchPartsQueue(
      service: service,
      library: library,
      info: info,
      bvid: info.bvid,
      current: item,
      currentPage: page,
      created: created,
      preferredItems: preferredItems,
    );
    if (isCancelled?.call() ?? false) {
      throw const BilibiliWatchCancelledException();
    }
    for (final part in parts) {
      cards?.track(part);
    }
    return BilibiliWatchPlan(
      item: item,
      videoInfo: info,
      imported: false,
      queue: parts,
      createdItemIds: Set<String>.unmodifiable(created),
      historyEntry: bilibiliWatchHistoryEntry(
        info: info,
        bvid: info.bvid,
        page: page,
        positionMs: item.lastPositionMs,
      ),
    );
  } catch (_) {
    for (final id in created) {
      await library.discardTransientVideo(id);
    }
    rethrow;
  }
}

/// Uses the existing playback page and its serialized media-switch path:
/// fullscreen, orientation and open panels do not reset between parts.
Future<void> switchBilibiliPart(
  BuildContext context,
  BilibiliVideoDetail detail,
  int page,
) async {
  final playback = context.read<MediaPlaybackService>();
  final playlist = context.read<PlaylistManager>();
  final library = context.read<LibraryService>();
  final service = context.read<BilibiliDownloadService>();
  final previous = playback.currentItem;
  final video = bilibiliPlayerVideoOf(previous);
  if (previous == null || video?.bvid != detail.bvid || video?.page == page) {
    return;
  }
  final originalQueue = List<VideoItem>.of(playlist.playlist);
  final originalIds = originalQueue.map((item) => item.id).toList();
  final route = ModalRoute.of(context);
  bool cancelled() =>
      !context.mounted ||
      route?.isCurrent != true ||
      playback.currentItem?.id != previous.id ||
      playback.pendingSwitchItem != null ||
      !listEquals(
        originalIds,
        playlist.playlist.map((item) => item.id).toList(),
      );
  final plan = await prepareBilibiliPartSwitch(
    service: service,
    library: library,
    info: bilibiliWatchInfoFromDetail(detail),
    page: page,
    existingQueue: originalQueue,
    currentItem: previous,
    cards: BilibiliWatchCards.instance,
    isCancelled: cancelled,
  );
  final items = projectBilibiliPartsQueue(
    queue: originalQueue,
    bvid: detail.bvid,
    parts: plan.queue!,
  );
  // Save the old part before the next watch entry changes the BV's history.
  await playback.persistCurrentProgress(expectedItemId: previous.id);
  await BilibiliWatchCards.instance?.recorder.flush(previous.id);
  if (cancelled()) {
    await discardAbandonedWatch(
      plan,
      library: library,
      playingItemId: playback.currentItem?.id,
      openPageItemIds: const <String>[],
      keep: playlist.playlist.map((item) => item.id).toSet(),
    );
    return;
  }
  final session = BilibiliWatchPlaylistSession.instance;
  if (!(session?.preparePartSwitch(items, previous.id) ?? false)) {
    playlist.setPlaylist(items, currentItemId: previous.id);
  }
  // A deliberate selection starts playback regardless of auto-next settings.
  await playback.playPlaylistItem(plan.item, autoPlay: true);
  // The switch path saves the old part too. Record the selected part after
  // that path commits so an old progress write cannot restore its page.
  if (playback.currentItem?.id == plan.item.id) {
    await noteOpenedWatch(plan);
  }
}
