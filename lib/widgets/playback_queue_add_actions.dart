import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../features/cloud_drive/models/cloud_drive_models.dart';
import '../features/cloud_drive/models/cloud_drive_view_options.dart';
import '../features/cloud_drive/services/cloud_drive_directory_session.dart';
import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/media_cache/media_cache_models.dart';
import '../features/media_cache/media_cache_selection.dart';
import '../features/podcasts/podcast_runtime.dart';
import '../models/media_source_ref.dart';
import '../models/bilibili_pending_card_data.dart';
import '../models/video_item.dart';
import '../services/bilibili/bilibili_collection_import.dart';
import '../services/bilibili/bilibili_download_service.dart';
import '../services/bilibili/bilibili_uploader_service.dart';
import '../services/library_service.dart';
import '../services/playback_queue_add_service.dart';
import '../services/playlist_manager.dart';

/// Successful and duplicate additions stay silent. Only long-running work has
/// cancellable progress, and failures have one short, coalesced message.
Future<QueueAddResult> _runAddition(
  BuildContext context,
  Future<QueueAddBatch> Function(_QueueCollector) resolve,
  QueueAddProgress? supplied,
) async {
  final progress = supplied ?? QueueAddProgress();
  final messenger = ScaffoldMessenger.maybeOf(context);
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? notice;
  final timer = Timer(const Duration(milliseconds: 1200), () {
    if (!context.mounted || progress.cancelled) return;
    notice = messenger?.showSnackBar(
      SnackBar(
        duration: const Duration(days: 1),
        content: ListenableBuilder(
          listenable: progress,
          builder: (_, _) =>
              Text('正在整理播放列表 · ${progress.resolved} 项', maxLines: 1),
        ),
        action: SnackBarAction(label: '取消', onPressed: progress.cancel),
      ),
    );
  });
  _QueueCollector? collector;
  PlaylistManager? targetQueue;
  QueueAddResult result;
  try {
    final queue = context.read<PlaylistManager>();
    targetQueue = queue;
    final library = context.read<LibraryService>();
    collector = _QueueCollector(
      context.read<BilibiliDownloadService?>(),
      library,
      queue,
      progress,
    );
    result = await PlaybackQueueAddService.of(
      queue,
    ).add((_) => resolve(collector!), progress);
    if (result.added.isNotEmpty) {
      final addedIds = result.added.toSet();
      final newCards = collector.items
          .where(
            (item) =>
                addedIds.contains(item.id) &&
                item.isTransient &&
                library.getVideo(item.id) == null,
          )
          .toList();
      if (newCards.isNotEmpty) await library.addTransientVideos(newCards);
      final podcasts = PodcastRuntime.instance;
      if (podcasts.ready && identical(podcasts.playlist, queue)) {
        podcasts.rememberActiveQueue();
      }
    }
  } catch (error) {
    debugPrint('Queue addition could not start: $error');
    result = const QueueAddResult(failed: ['添加失败，请稍后重试']);
  } finally {
    timer.cancel();
    notice?.close();
  }
  // Obtaining lightweight Bilibili cards does not import them. Cancelled or
  // duplicate preparations must not accumulate abandoned transient entries.
  if (collector != null) {
    for (final id in collector.created) {
      if (targetQueue?.playlist.any((item) => item.id == id) != true) {
        await collector.library.discardTransientVideo(id);
      }
    }
  }
  if (context.mounted && !result.cancelled) {
    final message = result.queueChanged
        ? '播放列表已切换，请重新添加'
        : result.failed.isNotEmpty
        ? (result.added.isEmpty
              ? '未能添加，请检查来源或网络后重试'
              : '已加入可用内容，${result.failed.length} 项未能添加')
        : null;
    if (message != null) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
      );
    }
  }
  if (supplied == null) progress.dispose();
  return result;
}

Future<QueueAddResult> addLibrarySelectionToQueue(
  BuildContext context,
  Iterable<String> ids, {
  QueueAddProgress? progress,
}) async {
  final selected = List<String>.of(ids);
  final result = await _runAddition(
    context,
    (collector) => collector.librarySelection(selected),
    progress,
  );
  if (result.failed.isNotEmpty &&
      result.added.isEmpty &&
      result.duplicates == 0) {
    return QueueAddResult(failed: selected);
  }
  return result;
}

Future<QueueAddResult> addCloudSelectionToQueue(
  BuildContext context,
  Iterable<CloudDriveEntry> entries, {
  QueueAddProgress? progress,
}) async {
  final selected = List<CloudDriveEntry>.of(entries);
  final result = await _runAddition(
    context,
    (collector) => collector.cloudSelection(selected),
    progress,
  );
  if (result.failed.isNotEmpty &&
      result.added.isEmpty &&
      result.duplicates == 0) {
    return QueueAddResult(failed: selected.map(cloudDriveEntryKey).toList());
  }
  return result;
}

/// Subscription collections expand from the podcast catalog, including episodes
/// that have never been opened. Queue addition must not materialize the catalog
/// as library cards or start playback.
Future<QueueAddResult> addPodcastChannelsToQueue(
  BuildContext context,
  Iterable<String> channelIds, {
  QueueAddProgress? progress,
}) => _runAddition(context, (collector) async {
  final runtime = PodcastRuntime.instance;
  if (!runtime.ready) return QueueAddBatch(failed: channelIds);
  final visited = <String>{};
  for (final channelId in channelIds) {
    if (collector.progress.cancelled) break;
    final settings = runtime.store.effective(channelId);
    final ids = runtime.store.queryEpisodeIds(
      channelId: channelId,
      sort: settings.text('sort'),
      hidePlayed: settings.flag('hidePlayed'),
    );
    for (final id in ids) {
      if (collector.progress.cancelled) break;
      if (!visited.add(id)) continue;
      final episode = runtime.store.episode(id);
      if (episode == null) continue;
      try {
        collector.items.add(runtime.previewItemFor(episode));
        collector.progress.update(runtime.episodeTitle(episode));
      } catch (_) {
        collector.failed.add(channelId);
      }
      if (visited.length % 64 == 0) await Future<void>.delayed(Duration.zero);
    }
  }
  return QueueAddBatch(items: collector.items, failed: collector.failed);
}, progress);

/// Add selected episodes in their visible order without starting playback.
Future<QueueAddResult> addPodcastEpisodesToQueue(
  BuildContext context,
  Iterable<String> episodeIds, {
  QueueAddProgress? progress,
}) => _runAddition(context, (collector) async {
  final ids = episodeIds.toList(growable: false);
  final runtime = PodcastRuntime.instance;
  if (!runtime.ready) return QueueAddBatch(failed: ids);
  for (final id in ids) {
    if (collector.progress.cancelled) break;
    try {
      final episode = runtime.store.episode(id);
      if (episode == null) {
        collector.failed.add(id);
        continue;
      }
      collector.items.add(runtime.previewItemFor(episode));
      collector.progress.update(runtime.episodeTitle(episode));
    } catch (_) {
      collector.failed.add(id);
    }
    if (collector.items.length % 64 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  return QueueAddBatch(items: collector.items, failed: collector.failed);
}, progress);

Future<QueueAddResult> addBilibiliVideoToQueue(
  BuildContext context,
  String bvid, {
  int? page,
  QueueAddProgress? progress,
}) => _runAddition(
  context,
  (collector) => collector.bilibiliSelection([bvid], page: page),
  progress,
);

Future<QueueAddResult> addBilibiliCollectionToQueue(
  BuildContext context,
  BilibiliCollectionImportSource source,
  BilibiliUploaderService uploader, {
  QueueAddProgress? progress,
}) => _runAddition(context, (collector) async {
  final ids = await loadBilibiliCollectionBvids(
    source: source,
    uploader: uploader,
    isCancelled: () => collector.progress.cancelled,
  );
  return collector.bilibiliSelection(ids);
}, progress);

Future<QueueAddResult> addCachedSourceToQueue(
  BuildContext context,
  CacheSource source, {
  QueueAddProgress? progress,
}) => _runAddition(context, (collector) async {
  final item = collector.library.getVideo(source.itemId) ?? source.toItem();
  if (collector.library.getVideo(item.id) == null) item.isTransient = true;
  collector.items.add(item);
  return QueueAddBatch(items: collector.items);
}, progress);

class _QueueCollector {
  _QueueCollector(this.bilibili, this.library, this.queue, this.progress);
  final BilibiliDownloadService? bilibili;
  final PlaylistManager queue;
  final LibraryService library;
  final QueueAddProgress progress;
  final items = <VideoItem>[];
  final failed = <String>[];
  final created = <String>{};
  final visited = <String>{};

  Future<QueueAddBatch> librarySelection(List<String> ids) async {
    for (final id in ids) {
      if (progress.cancelled) break;
      final failedBefore = failed.length;
      try {
        await _libraryEntry(id);
      } catch (_) {
        failed.add(id);
      }
      if (failed.length > failedBefore) {
        failed.removeRange(failedBefore, failed.length);
        failed.add(id);
      }
    }
    return QueueAddBatch(items: items, failed: failed);
  }

  Future<void> _libraryEntry(String id) async {
    if (progress.cancelled || !visited.add('local:$id')) return;
    if (visited.length % 64 == 0) await Future<void>.delayed(Duration.zero);
    if (progress.cancelled) return;
    final item = library.getVideo(id);
    if (item != null) {
      if (queue.isQueueEligible(item)) {
        items.add(item);
      } else {
        failed.add(id);
      }
      progress.update(item.title);
      return;
    }
    final folder = library.getCollection(id);
    if (folder == null || folder.isRecycled) {
      failed.add(id);
      return;
    }
    if (folder.sourceRef?.cloudDrive != null) {
      await _remoteFolder(folder.sourceRef!, folder.name);
    } else {
      for (final child in library.getContents(id)) {
        if (progress.cancelled) break;
        await _libraryEntry(child.id as String);
      }
    }
  }

  Future<QueueAddBatch> cloudSelection(List<CloudDriveEntry> entries) async {
    for (final entry in entries) {
      if (progress.cancelled) break;
      try {
        await _cloudEntry(entry);
      } catch (_) {
        failed.add(cloudDriveEntryKey(entry));
      }
    }
    return QueueAddBatch(items: items, failed: failed);
  }

  Future<void> _cloudEntry(CloudDriveEntry entry) async {
    if (progress.cancelled) return;
    if (entry.kind == CloudDriveEntryKind.folder) {
      await _remoteFolder(cloudDriveEntrySource(entry), entry.name);
    } else {
      final source = cacheSourceForCloudEntry(entry);
      if (source == null) return;
      final item = library.getVideo(source.itemId) ?? source.toItem();
      if (library.getVideo(item.id) == null) item.isTransient = true;
      items.add(item);
      progress.update(entry.name);
    }
  }

  Future<void> _remoteFolder(MediaSourceRef source, String name) async {
    final ref = source.cloudDrive!;
    if (progress.cancelled || !visited.add('cloud:${ref.sourceKey}')) return;
    final runtime = await CloudDriveRuntime.ensureInstalled();
    final account = runtime.accounts.findRemote(
      ref.providerId,
      ref.remoteAccountId,
    );
    if (account == null) throw StateError('需要登录网盘');
    final directory = CloudDriveDirectorySession(
      runtime: runtime,
      account: account,
      directoryId: ref.providerId == 'baidu'
          ? ref.pathHint ?? ref.fileId
          : ref.fileId,
    );
    progress.cancelReader = directory.pause;
    try {
      await directory.finish();
      if (!directory.complete && !progress.cancelled) {
        throw StateError('$name 未读取完整');
      }
      final entries = const CloudDriveViewOptions().project(
        List.of(directory.entries),
      );
      for (final entry in entries) {
        if (progress.cancelled) break;
        await _cloudEntry(entry);
      }
    } finally {
      progress.cancelReader = null;
      directory.release();
    }
  }

  Future<QueueAddBatch> bilibiliSelection(
    List<String> bvids, {
    int? page,
  }) async {
    final service = bilibili;
    if (service == null) throw StateError('B站服务尚未就绪');
    for (final bvid in bvids) {
      if (progress.cancelled) break;
      try {
        final info = await service.apiService.fetchVideoInfo(bvid);
        final parts =
            info.pages
                .where((part) => page == null || part.page == page)
                .toList()
              ..sort((a, b) => a.page.compareTo(b.page));
        if (parts.isEmpty) {
          failed.add(bvid);
          continue;
        }
        for (final part in parts) {
          if (progress.cancelled) break;
          try {
            final card = await service.obtainWatchCard(
              library,
              bvid: bvid,
              page: part.page,
              videoInfo: info,
              deferPlayerData: true,
            );
            items.add(card.item);
            if (card.created && card.item.isTransient) {
              created.add(card.item.id);
              card.item.bilibiliPendingCardData ??= BilibiliPendingCardData(
                coverUrl: info.pic,
                subtitleLanguage: service.preferredSubtitleLang,
                preferAiSubtitles: service.preferAiSubtitles,
              );
            }
            progress.update(card.item.title);
          } catch (_) {
            failed.add('$bvid:${part.page}');
          }
        }
      } catch (_) {
        failed.add(bvid);
      }
    }
    return QueueAddBatch(items: items, failed: failed);
  }
}
