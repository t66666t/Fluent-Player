import '../models/media_source_ref.dart';
import '../models/library_activity.dart';
import '../models/media_library_continue_policy.dart';
import '../models/video_collection.dart';
import '../models/video_item.dart';

/// Read-only queries over activity records plus live library identity.
///
/// Visibility always excludes recycled items and anything under a recycled
/// ancestor. Ancestor walks use a visited set so a parent cycle cannot hang.
class LibraryActivityProjection {
  LibraryActivityProjection({
    required this.store,
    required this.videoOf,
    required this.collectionOf,
    required this.allVideos,
  });

  final LibraryActivityStore store;
  final VideoItem? Function(String id) videoOf;
  final VideoCollection? Function(String id) collectionOf;

  /// Live library videos. Used so unknown addedAt rows include pre-activity items.
  final Iterable<VideoItem> Function() allVideos;

  MediaActivityRecord? mediaRecord(String mediaId) => store.media[mediaId];

  bool isMediaHidden(String mediaId) => store.media[mediaId]?.hidden == true;

  /// True when this media or folder card was removed from 最近添加.
  ///
  /// Independent of [isMediaHidden]. A later play does not clear it.
  bool isDismissedFromRecent(String id) =>
      store.recentDismissedIds.contains(id);

  bool isPinned(String id) => store.pinnedIds.contains(id);

  bool isVisibleMedia(String mediaId) {
    final item = videoOf(mediaId);
    if (item == null || item.isRecycled) return false;
    return !hasRecycledAncestor(item.parentId);
  }

  bool isVisibleCollection(String collectionId) {
    final collection = collectionOf(collectionId);
    if (collection == null || collection.isRecycled) return false;
    return !hasRecycledAncestor(collection.parentId);
  }

  /// Cycle-safe walk toward root. Missing parents count as not recycled.
  bool hasRecycledAncestor(String? parentId) {
    final visited = <String>{};
    var currentId = parentId;
    while (currentId != null && visited.add(currentId)) {
      final parent = collectionOf(currentId);
      if (parent == null) return false;
      if (parent.isRecycled) return true;
      currentId = parent.parentId;
    }
    return false;
  }

  /// Pins keep their saved order; missing or recycled targets are skipped.
  List<String> visiblePinnedIds() {
    final seenCloud = <String>{};
    return store.pinnedIds
        .where((id) {
          if (!isVisibleMedia(id) && !isVisibleCollection(id)) return false;
          final key = videoOf(id)?.sourceRef?.cloudDrive?.sourceKey;
          return key == null || seenCloud.add(key);
        })
        .toList(growable: false);
  }

  bool _isRecentMedia(String id) {
    final item = videoOf(id);
    return item != null &&
        isVisibleMedia(id) &&
        !isCloudDriveMedia(source: item.sourceRef, path: item.path);
  }

  Iterable<VideoItem> _activityVideos() sync* {
    final cloud = <String, List<VideoItem>>{};
    for (final item in allVideos()) {
      final key = item.sourceRef?.cloudDrive?.sourceKey;
      if (key == null) {
        yield item;
        continue;
      }
      if (isVisibleMedia(item.id)) cloud.putIfAbsent(key, () => []).add(item);
    }
    for (final peers in cloud.values) {
      peers.sort((a, b) {
        if (a.id == b.id) return 0;
        final ar = store.media[a.id], br = store.media[b.id];
        final preferred =
            ar?.sharedLastPlayedCardId ?? br?.sharedLastPlayedCardId;
        if (a.id == preferred) return -1;
        if (b.id == preferred) return 1;
        final played = (br?.lastPlayedAtMs ?? 0).compareTo(
          ar?.lastPlayedAtMs ?? 0,
        );
        return played != 0 ? played : b.lastUpdated.compareTo(a.lastUpdated);
      });
      yield peers.first;
    }
  }

  /// Newest known addedAt first. Unknown times stay in [unknownAdded], unsorted
  /// by lastUpdated so callers cannot accidentally invent an import clock.
  RecentAddedPartition recentAddedMediaIds() {
    final dated = <_DatedId>[];
    final unknown = <String>[];
    for (final item in allVideos()) {
      if (!_isRecentMedia(item.id)) continue;
      final addedAt = store.media[item.id]?.addedAtMs;
      if (addedAt == null) {
        unknown.add(item.id);
      } else {
        dated.add(_DatedId(item.id, addedAt));
      }
    }
    dated.sort((a, b) => b.atMs.compareTo(a.atMs));
    return RecentAddedPartition(
      datedIds: dated.map((entry) => entry.id).toList(growable: false),
      unknownAddedIds: List<String>.unmodifiable(unknown),
    );
  }

  /// Import batches plus orphan singles, never sorted by lastUpdated.
  ///
  /// A batch that created folders shows each top folder's first layer:
  /// direct new files as cards, direct child folders as folder cards.
  /// Bilibili and YT-DLP loose files stay individual cards so a source
  /// name is not used as a collection title.
  ///
  /// Ids in [LibraryActivityStore.recentDismissedIds] are omitted after
  /// coverage is recorded, so hiding a folder card does not spill its files
  /// out as new singles. The import clock in [recentAddedMediaIds] is unchanged.
  List<RecentAddedEntry> recentAddedEntries() {
    final partition = recentAddedMediaIds();
    final mediaInBatch = <String>{};
    final dated = <RecentAddedEntry>[];

    for (final batch in store.batches) {
      if (batch.sourceKind == LibraryImportSourceKind.cloudDrive) continue;
      final visible = <String>[];
      for (final mediaId in batch.createdMediaIds) {
        if (!_isRecentMedia(mediaId)) continue;
        visible.add(mediaId);
        mediaInBatch.add(mediaId);
      }
      if (visible.isEmpty) continue;
      dated.addAll(_entriesForBatch(batch, visible));
    }

    for (final mediaId in partition.datedIds) {
      if (mediaInBatch.contains(mediaId)) continue;
      if (isDismissedFromRecent(mediaId)) continue;
      final addedAtMs = store.media[mediaId]?.addedAtMs;
      if (addedAtMs == null) continue;
      dated.add(
        RecentAddedEntry.single(
          mediaId: mediaId,
          sortKeyMs: addedAtMs,
          sortId: mediaId,
        ),
      );
    }

    dated.sort((a, b) {
      final byTime = b.sortKeyMs.compareTo(a.sortKeyMs);
      if (byTime != 0) return byTime;
      final byId = b.sortId.compareTo(a.sortId);
      if (byId != 0) return byId;
      return a.innerIndex.compareTo(b.innerIndex);
    });

    final unknownIds = partition.unknownAddedIds
        .where((id) => !mediaInBatch.contains(id) && !isDismissedFromRecent(id))
        .toList(growable: false);
    if (unknownIds.isEmpty) {
      return List<RecentAddedEntry>.unmodifiable(dated);
    }
    return List<RecentAddedEntry>.unmodifiable([
      ...dated,
      RecentAddedEntry.unknown(
        visibleMediaIds: List<String>.unmodifiable(unknownIds),
      ),
    ]);
  }

  List<RecentAddedEntry> _entriesForBatch(
    ImportBatchRecord batch,
    List<String> visibleMedia,
  ) {
    final created = <String>{
      for (final id in batch.createdCollectionIds)
        if (isVisibleCollection(id)) id,
    };
    final batchMedia = visibleMedia.toSet();
    final roots = <String>[];
    for (final id in batch.createdCollectionIds) {
      if (!created.contains(id)) continue;
      final parentId = collectionOf(id)?.parentId;
      if (parentId != null && created.contains(parentId)) continue;
      roots.add(id);
    }

    final covered = <String>{};
    final entries = <RecentAddedEntry>[];
    var inner = 0;
    for (final rootId in roots) {
      final children = _firstLayerChildren(rootId, created, batchMedia);
      if (children.isEmpty) continue;
      for (final child in children) {
        if (child.kind == RecentAddedChildKind.media) {
          covered.add(child.id);
        }
      }
      covered.addAll(_descendantBatchMedia(rootId, created, batchMedia));
      // Coverage uses the full first layer. Dismissed cards drop out after
      // that, so a hidden folder keeps its files from reappearing as singles.
      final shown = <RecentAddedChild>[
        for (final child in children)
          if (!isDismissedFromRecent(child.id)) child,
      ];
      if (shown.isEmpty) continue;
      final onlyOneFile =
          shown.length == 1 && shown.single.kind == RecentAddedChildKind.media;
      if (onlyOneFile) {
        entries.add(
          RecentAddedEntry.single(
            mediaId: shown.single.id,
            sortKeyMs: batch.startedAtMs,
            sortId: batch.id,
            innerIndex: inner,
            sourceBatchId: batch.id,
          ),
        );
      } else {
        final name = collectionOf(rootId)?.name.trim();
        entries.add(
          RecentAddedEntry.batch(
            batchId: '${batch.id}:$rootId',
            title: (name == null || name.isEmpty) ? batch.title : name,
            sortKeyMs: batch.startedAtMs,
            sortId: batch.id,
            innerIndex: inner,
            sourceBatchId: batch.id,
            children: shown,
          ),
        );
      }
      inner++;
    }

    final loose = <String>[
      for (final id in visibleMedia)
        if (!covered.contains(id) && !isDismissedFromRecent(id)) id,
    ];
    if (loose.isEmpty) return entries;

    final keepLooseFlat =
        loose.length > 1 &&
        roots.isEmpty &&
        batch.sourceKind != LibraryImportSourceKind.bilibili &&
        batch.sourceKind != LibraryImportSourceKind.ytDlp;
    if (keepLooseFlat) {
      entries.add(
        RecentAddedEntry.batch(
          batchId: batch.id,
          title: batch.title,
          sortKeyMs: batch.startedAtMs,
          sortId: batch.id,
          innerIndex: inner,
          sourceBatchId: batch.id,
          children: [for (final id in loose) RecentAddedChild.media(id)],
        ),
      );
      return entries;
    }
    for (final id in loose) {
      entries.add(
        RecentAddedEntry.single(
          mediaId: id,
          sortKeyMs: batch.startedAtMs,
          sortId: batch.id,
          innerIndex: inner,
          sourceBatchId: batch.id,
        ),
      );
      inner++;
    }
    return entries;
  }

  List<RecentAddedChild> _firstLayerChildren(
    String rootId,
    Set<String> created,
    Set<String> batchMedia,
  ) {
    final collection = collectionOf(rootId);
    if (collection == null) return const <RecentAddedChild>[];
    final children = <RecentAddedChild>[];
    for (final childId in collection.childrenIds) {
      if (created.contains(childId)) {
        if (_descendantBatchMedia(childId, created, batchMedia).isNotEmpty) {
          children.add(RecentAddedChild.folder(childId));
        }
        continue;
      }
      if (batchMedia.contains(childId)) {
        children.add(RecentAddedChild.media(childId));
      }
    }
    return children;
  }

  Set<String> _descendantBatchMedia(
    String collectionId,
    Set<String> created,
    Set<String> batchMedia,
  ) {
    final found = <String>{};
    final pending = <String>[collectionId];
    final seen = <String>{};
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!seen.add(current)) continue;
      final collection = collectionOf(current);
      if (collection == null) continue;
      for (final childId in collection.childrenIds) {
        if (batchMedia.contains(childId)) {
          found.add(childId);
          continue;
        }
        if (created.contains(childId)) pending.add(childId);
      }
    }
    return found;
  }

  /// Live against [policy]; changing sliders refilters without rewatching.
  bool isContinueEligible(
    VideoItem item, {
    ContinueWatchPolicy? policy,
    DateTime? now,
  }) {
    if (!isVisibleMedia(item.id)) return false;
    final record = store.media[item.id];
    if (record == null || record.hidden) return false;
    final rules = policy ?? ContinueWatchPolicy.defaults;
    if (rules.excludeCompleted && record.completed) return false;
    if (rules.minItemDurationMs > 0 &&
        item.durationMs > 0 &&
        item.durationMs < rules.minItemDurationMs) {
      return false;
    }
    if (rules.hideRemainingBelowMs > 0 &&
        item.durationMs > 0 &&
        item.lastPositionMs > 0) {
      final remaining = item.durationMs - item.lastPositionMs;
      if (remaining <= rules.hideRemainingBelowMs) return false;
    }
    if (rules.maxAgeDays > 0) {
      final playedAt = record.lastPlayedAtMs;
      if (playedAt == null) return false;
      final clock = now ?? DateTime.now();
      final age = clock.millisecondsSinceEpoch - playedAt;
      if (age > rules.maxAgeDays * 24 * 60 * 60 * 1000) return false;
    }
    var watchMs = record.accumulatedWatchMs;
    final legacyResume =
        watchMs <= 0 &&
        rules.useProgressIfNoWatchClock &&
        item.lastPositionMs > 0;
    if (!legacyResume &&
        !rules.hasReachedWatchGate(
          watchMs,
          item.durationMs > 0 ? item.durationMs : null,
        )) {
      return false;
    }
    if (rules.minProgressFraction > 0) {
      if (item.durationMs <= 0) return item.lastPositionMs > 0;
      if (item.lastPositionMs / item.durationMs < rules.minProgressFraction) {
        return false;
      }
    }
    return true;
  }

  /// Any counted play, including short previews and completed items.
  /// Hidden / recycled rows stay out. Newest first. There is no small cap:
  /// a play stamp is a few integers, and the UI groups by day.
  bool isPlaybackHistoryEligible(VideoItem item) {
    if (!isVisibleMedia(item.id)) return false;
    final record = store.media[item.id];
    if (record == null || record.hidden) return false;
    if (record.lastPlayedAtMs != null) return true;
    if (record.accumulatedWatchMs > 0) return true;
    return item.lastPositionMs > 0;
  }

  List<String> playbackHistoryMediaIds() {
    final dated = <_DatedId>[];
    final unknown = <String>[];
    for (final item in _activityVideos()) {
      if (!isPlaybackHistoryEligible(item)) continue;
      final playedAt = store.media[item.id]?.lastPlayedAtMs;
      if (playedAt != null) {
        dated.add(_DatedId(item.id, playedAt));
      } else {
        unknown.add(item.id);
      }
    }
    dated.sort((a, b) {
      final byTime = b.atMs.compareTo(a.atMs);
      if (byTime != 0) return byTime;
      return a.id.compareTo(b.id);
    });
    unknown.sort();
    return <String>[...dated.map((entry) => entry.id), ...unknown];
  }

  /// History rows bucketed by local calendar day, newest day first.
  List<PlaybackHistoryDayGroup> playbackHistoryDayGroups({DateTime? now}) {
    final clock = now ?? DateTime.now();
    final ids = playbackHistoryMediaIds();
    final buckets = <int, List<String>>{};
    final unknown = <String>[];
    for (final id in ids) {
      final playedAt = store.media[id]?.lastPlayedAtMs;
      if (playedAt == null) {
        unknown.add(id);
        continue;
      }
      final local = DateTime.fromMillisecondsSinceEpoch(playedAt);
      final dayStart = DateTime(
        local.year,
        local.month,
        local.day,
      ).millisecondsSinceEpoch;
      buckets.putIfAbsent(dayStart, () => <String>[]).add(id);
    }
    final days = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    final groups = <PlaybackHistoryDayGroup>[
      for (final dayStart in days)
        PlaybackHistoryDayGroup(
          dayStartMs: dayStart,
          label: playbackHistoryDayLabel(
            DateTime.fromMillisecondsSinceEpoch(dayStart),
            now: clock,
          ),
          mediaIds: List<String>.unmodifiable(buckets[dayStart]!),
        ),
    ];
    if (unknown.isNotEmpty) {
      groups.add(
        PlaybackHistoryDayGroup(
          dayStartMs: 0,
          label: '更早',
          mediaIds: List<String>.unmodifiable(unknown),
        ),
      );
    }
    return groups;
  }

  static String playbackHistoryDayLabel(DateTime day, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final today = DateTime(clock.year, clock.month, clock.day);
    final start = DateTime(day.year, day.month, day.day);
    final diff = today.difference(start).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff > 1 && diff < 7) {
      const names = <String>['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
      return names[start.weekday - 1];
    }
    return '${start.year}年${start.month}月${start.day}日';
  }

  /// Incomplete rows grouped by direct parent. Folder groups keep every
  /// sibling (latest first) so the UI can expand; root items stay individual.
  /// Pinned media IDs are omitted here; pinned folders do not hide children.
  List<ContinueLearningGroup> continueLearningGroups({
    bool excludePinnedMedia = true,
    bool unknownPlayedOnly = false,
    ContinueWatchPolicy? policy,
    DateTime? now,
  }) {
    final groups = <String?, List<VideoItem>>{};
    for (final item in _continueLearningItems(
      excludePinnedMedia: excludePinnedMedia,
      policy: policy,
      now: now,
    )) {
      final playedAt = store.media[item.id]?.lastPlayedAtMs;
      if (unknownPlayedOnly ? playedAt != null : playedAt == null) continue;
      groups.putIfAbsent(item.parentId, () => <VideoItem>[]).add(item);
    }
    return _buildContinueLearningGroups(groups);
  }

  Iterable<VideoItem> _continueLearningItems({
    bool excludePinnedMedia = true,
    ContinueWatchPolicy? policy,
    DateTime? now,
  }) sync* {
    final pinnedMedia = excludePinnedMedia
        ? visiblePinnedIds().where(isVisibleMedia).toSet()
        : <String>{};
    final pinnedCloud = <String>{
      for (final id in pinnedMedia)
        if (videoOf(id)?.sourceRef?.cloudDrive?.sourceKey case final String key)
          key,
    };
    for (final item in _activityVideos()) {
      if (pinnedMedia.contains(item.id) ||
          pinnedCloud.contains(item.sourceRef?.cloudDrive?.sourceKey)) {
        continue;
      }
      if (!isContinueEligible(item, policy: policy, now: now)) continue;
      yield item;
    }
  }

  List<ContinueLearningGroup> _buildContinueLearningGroups(
    Map<String?, List<VideoItem>> groups,
  ) {
    final result = <ContinueLearningGroup>[];
    groups.forEach((parentId, items) {
      items.sort((a, b) {
        final aPlayed = store.media[a.id]?.lastPlayedAtMs ?? 0;
        final bPlayed = store.media[b.id]?.lastPlayedAtMs ?? 0;
        if (aPlayed != bPlayed) return bPlayed.compareTo(aPlayed);
        return a.id.compareTo(b.id);
      });
      if (parentId == null) {
        for (final item in items) {
          result.add(
            ContinueLearningGroup(parentId: null, mediaIds: <String>[item.id]),
          );
        }
        return;
      }
      result.add(
        ContinueLearningGroup(
          parentId: parentId,
          mediaIds: List<String>.unmodifiable(items.map((item) => item.id)),
        ),
      );
    });
    result.sort((a, b) {
      final aPlayed = store.media[a.featuredMediaId]?.lastPlayedAtMs ?? 0;
      final bPlayed = store.media[b.featuredMediaId]?.lastPlayedAtMs ?? 0;
      if (aPlayed != bPlayed) return bPlayed.compareTo(aPlayed);
      return a.rowId.compareTo(b.rowId);
    });
    return result;
  }

  ContinueLearningSections continueLearningSections({
    ContinueWatchPolicy? policy,
    DateTime? now,
  }) {
    final recent = <String?, List<VideoItem>>{};
    final unknown = <String?, List<VideoItem>>{};
    for (final item in _continueLearningItems(policy: policy, now: now)) {
      final groups = store.media[item.id]?.lastPlayedAtMs == null
          ? unknown
          : recent;
      groups.putIfAbsent(item.parentId, () => <VideoItem>[]).add(item);
    }
    return ContinueLearningSections(
      recent: _buildContinueLearningGroups(recent),
      unknown: _buildContinueLearningGroups(unknown),
    );
  }
}

class RecentAddedPartition {
  const RecentAddedPartition({
    required this.datedIds,
    required this.unknownAddedIds,
  });

  final List<String> datedIds;
  final List<String> unknownAddedIds;
}

class PlaybackHistoryDayGroup {
  const PlaybackHistoryDayGroup({
    required this.dayStartMs,
    required this.label,
    required this.mediaIds,
  });

  final int dayStartMs;
  final String label;
  final List<String> mediaIds;

  String get rowId => 'day:$dayStartMs';
}

class ContinueLearningGroup {
  const ContinueLearningGroup({required this.parentId, required this.mediaIds});

  final String? parentId;
  final List<String> mediaIds;

  String get featuredMediaId => mediaIds.first;

  String get rowId =>
      parentId == null ? 'root:$featuredMediaId' : 'folder:$parentId';
}

class ContinueLearningSections {
  const ContinueLearningSections({required this.recent, required this.unknown});

  final List<ContinueLearningGroup> recent;
  final List<ContinueLearningGroup> unknown;

  bool get isEmpty => recent.isEmpty && unknown.isEmpty;
}

enum RecentAddedKind { batch, single, unknown }

/// One root-level row in 最近添加. Batch rows are not [VideoCollection]s.
enum RecentAddedChildKind { media, folder }

class RecentAddedChild {
  const RecentAddedChild.media(this.id) : kind = RecentAddedChildKind.media;

  const RecentAddedChild.folder(this.id) : kind = RecentAddedChildKind.folder;

  final RecentAddedChildKind kind;
  final String id;
}

class RecentAddedEntry {
  const RecentAddedEntry._({
    required this.kind,
    required this.sortKeyMs,
    required this.sortId,
    this.innerIndex = 0,
    this.batchId,
    this.mediaId,
    this.title = '',
    this.visibleMediaIds = const <String>[],
    this.children = const <RecentAddedChild>[],
    this.sourceBatchId,
  });

  factory RecentAddedEntry.batch({
    required String batchId,
    required String title,
    required int sortKeyMs,
    required String sortId,
    int innerIndex = 0,
    String? sourceBatchId,
    List<String> visibleMediaIds = const <String>[],
    List<RecentAddedChild>? children,
  }) {
    final rows =
        children ??
        <RecentAddedChild>[
          for (final id in visibleMediaIds) RecentAddedChild.media(id),
        ];
    return RecentAddedEntry._(
      kind: RecentAddedKind.batch,
      batchId: batchId,
      title: title,
      sortKeyMs: sortKeyMs,
      sortId: sortId,
      innerIndex: innerIndex,
      visibleMediaIds: List<String>.unmodifiable([
        for (final child in rows)
          if (child.kind == RecentAddedChildKind.media) child.id,
      ]),
      children: List<RecentAddedChild>.unmodifiable(rows),
      sourceBatchId: sourceBatchId ?? batchId,
    );
  }

  factory RecentAddedEntry.single({
    required String mediaId,
    required int sortKeyMs,
    required String sortId,
    int innerIndex = 0,
    String? sourceBatchId,
  }) {
    return RecentAddedEntry._(
      kind: RecentAddedKind.single,
      mediaId: mediaId,
      sortKeyMs: sortKeyMs,
      sortId: sortId,
      innerIndex: innerIndex,
      visibleMediaIds: <String>[mediaId],
      children: <RecentAddedChild>[RecentAddedChild.media(mediaId)],
      sourceBatchId: sourceBatchId,
    );
  }

  factory RecentAddedEntry.unknown({required List<String> visibleMediaIds}) {
    return RecentAddedEntry._(
      kind: RecentAddedKind.unknown,
      sortKeyMs: 0,
      sortId: 'unknown',
      title: '更早添加',
      visibleMediaIds: visibleMediaIds,
      children: <RecentAddedChild>[
        for (final id in visibleMediaIds) RecentAddedChild.media(id),
      ],
    );
  }

  final RecentAddedKind kind;
  final int sortKeyMs;
  final String sortId;
  final int innerIndex;
  final String? batchId;
  final String? mediaId;
  final String title;
  final List<String> visibleMediaIds;
  final List<RecentAddedChild> children;
  final String? sourceBatchId;

  String get rowId {
    switch (kind) {
      case RecentAddedKind.batch:
        return 'batch:${batchId!}';
      case RecentAddedKind.single:
        return 'media:${mediaId!}';
      case RecentAddedKind.unknown:
        return 'unknown';
    }
  }

  int get visibleCount =>
      children.isEmpty ? visibleMediaIds.length : children.length;

  String groupHeaderLabel() => '$title·当前$visibleCount项';
}

class _DatedId {
  const _DatedId(this.id, this.atMs);

  final String id;
  final int atMs;
}
