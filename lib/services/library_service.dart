import 'community_media_input.dart';
import 'storage_migration_coordinator.dart';
import 'app_storage_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import '../debug/developer_log.dart' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:lpinyin/lpinyin.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/media_source_ref.dart';
import '../utils/supported_media_extensions.dart';
import '../models/cloud_drive_source_ref.dart';
import '../features/cloud_drive/services/cloud_drive_materialization.dart';
import '../features/media_cache/media_cache_hooks.dart';
import '../features/media_cache/media_cache_models.dart';
import '../features/cloud_drive/services/cloud_drive_thumbnails.dart';
import '../models/video_collection.dart';
import '../models/podcast_source_ref.dart';
import '../features/podcasts/podcast_playback_hooks.dart';
import '../utils/media_library_search_query.dart';
import '../utils/imported_media_title.dart';
import '../models/video_item.dart';
import '../models/import_card_placement.dart';
import '../models/library_activity.dart';
import '../models/download_import_context.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/media_chapter.dart';
import 'library_activity_projection.dart';
import 'library_snapshot_writer.dart';
import 'library_snapshot_reader.dart';
import 'media_library_navigation.dart';
import 'media_library_folder_walk.dart';
import 'thumbnail_cache_service.dart';
import 'playback_state_store.dart';
import 'audio_cover_art.dart';
import 'audio_playback_compatibility_service.dart';
import 'settings_service.dart';
import '../features/progress_sync/folder_media_committer.dart';
import 'bilibili/bilibili_cover_cache.dart';
import 'bilibili/bilibili_shared_subtitles.dart';
import 'bilibili/bilibili_stream_card.dart';
import 'temporary_storage_cleanup_models.dart';
import 'import_cache_cleanup.dart';
import '../utils/import_cache_roots.dart';
import 'media_materialization_service.dart';
import '../utils/ffmpeg_utils.dart';
import '../utils/media_duration_probe.dart';
import '../utils/thumbnail_seek.dart';
import '../utils/media_chapter_probe.dart';
import '../utils/serial_task_queue.dart';
import '../utils/ui_idle_gate.dart';
import '../utils/subtitle_file_matcher.dart';
import 'subtitle_discovery_service.dart';
import 'task_subtitle_storage_service.dart';
import 'generated_subtitle_names.dart';
import 'subtitle_word_timing_store.dart';
import 'chapter_thumbnail_service.dart';
import 'bilibili/bilibili_streaming_service.dart';
import 'bilibili/bilibili_video_shot_service.dart';

part 'library_download_import.dart';

enum StructuredImportSortField { fileName, modifiedTime }

enum StructuredImportSortDirection { ascending, descending }

/// Whether the in-memory media library is durably stored on disk.
///
/// A retry is intentionally represented as a recoverable state instead of an
/// exception: existing callers keep their current behavior while the UI can
/// truthfully tell the user that the latest changes are not durable yet.
enum LibraryPersistenceStatus { healthy, retryScheduled }

enum OnlineCacheClearStatus { cleared, deferred, failed }

class _RecycleBinItemRestored implements Exception {}

class RecycleBinDeleteResult {
  const RecycleBinDeleteResult({
    required this.deletedIds,
    required this.failedIds,
    required this.saved,
    this.restoredIds = const {},
  });
  final Set<String> restoredIds;
  final List<String> deletedIds;
  final Map<String, String> failedIds;
  final bool saved;
}

/// Outcome of rebinding one existing card to a newly chosen local file.
enum RelocateLocalMediaStatus {
  success,
  mediaNotFound,
  onlineSource,
  missingFile,
  unsupportedType,
  typeMismatch,
}

class RelocateLocalMediaResult {
  const RelocateLocalMediaResult({
    required this.status,
    this.positionClamped = false,
  });

  final RelocateLocalMediaStatus status;
  final bool positionClamped;

  bool get isSuccess => status == RelocateLocalMediaStatus.success;
}

class StructuredImportSortOptions {
  final StructuredImportSortField field;
  final StructuredImportSortDirection direction;

  const StructuredImportSortOptions({
    required this.field,
    required this.direction,
  });

  factory StructuredImportSortOptions.fromSettings(SettingsService settings) {
    return StructuredImportSortOptions(
      field: settings.structuredImportSortField == 'modifiedTime'
          ? StructuredImportSortField.modifiedTime
          : StructuredImportSortField.fileName,
      direction: settings.structuredImportSortDirection == 'descending'
          ? StructuredImportSortDirection.descending
          : StructuredImportSortDirection.ascending,
    );
  }

  String get fieldStorageValue {
    return field == StructuredImportSortField.modifiedTime
        ? 'modifiedTime'
        : 'fileName';
  }

  String get directionStorageValue {
    return direction == StructuredImportSortDirection.descending
        ? 'descending'
        : 'ascending';
  }
}

class StructuredImportSelectionSummary {
  final String sourcePath;
  final String sourceName;
  final String rootCollectionName;
  final bool isArchive;
  final int folderCount;
  final int mediaFileCount;
  final bool detailsDeferred;

  const StructuredImportSelectionSummary({
    required this.sourcePath,
    required this.sourceName,
    required this.rootCollectionName,
    required this.isArchive,
    required this.folderCount,
    required this.mediaFileCount,
    this.detailsDeferred = false,
  });
}

class StructuredImportExecutionResult {
  final String rootCollectionId;
  final int createdFolderCount;
  final int importedMediaCount;
  final int restoredMediaCount;
  final List<String> importedVideoIds;
  final String? activityBatchId;

  const StructuredImportExecutionResult({
    required this.rootCollectionId,
    required this.createdFolderCount,
    required this.importedMediaCount,
    required this.restoredMediaCount,
    this.importedVideoIds = const <String>[],
    this.activityBatchId,
  });

  int get affectedMediaCount => importedMediaCount + restoredMediaCount;
}

class MediaImportExecutionResult {
  const MediaImportExecutionResult({
    this.createdVideoIds = const <String>[],
    this.reusedVideoIds = const <String>[],
    this.failedCount = 0,
    this.activityBatchId,
    this.ignoredBecauseBusy = false,
  });

  final List<String> createdVideoIds;
  final List<String> reusedVideoIds;
  final int failedCount;
  final String? activityBatchId;
  final bool ignoredBecauseBusy;
}

class _FileSystemEntrySnapshot {
  final FileSystemEntity entity;
  final String name;
  final bool isDirectory;
  final int modifiedTimeMs;

  const _FileSystemEntrySnapshot({
    required this.entity,
    required this.name,
    required this.isDirectory,
    required this.modifiedTimeMs,
  });
}

class _StructuredImportAccumulator {
  final List<String> newVideoIds = [];
  final List<String> newCollectionIds = [];
  int createdFolderCount = 0;
  int importedMediaCount = 0;
  int restoredMediaCount = 0;
  String? activityBatchId;
}

/// Told about every playback position written through
/// [LibraryService.updateVideoProgress], watch-only cards included.
typedef LibraryProgressObserver = void Function(VideoItem item, int positionMs);

/// User-visible name changes, including source-specific presentation metadata.
typedef LibraryRenameObserver = void Function(String itemId, String name);

class LibraryService extends ChangeNotifier {
  int _browseRevision = 0;
  int get browseRevision => _browseRevision;
  final Map<String?, List<dynamic>> _browseContents = {};
  final Map<String, int> _cardRevisions = {};
  Map<(String?, int?), List<VideoItem>>? _bilibiliCacheCandidates;

  Iterable<VideoItem> bilibiliCacheCandidates(String? bvid, int? cid) {
    var index = _bilibiliCacheCandidates;
    if (index == null) {
      index = _bilibiliCacheCandidates = {};
      for (final item in _videos.values) {
        final ref = item.sourceRef;
        if (ref?.bvid != null && ref?.cid != null) {
          (index[(ref!.bvid, ref.cid)] ??= []).add(item);
        }
      }
    }
    return index[(bvid, cid)] ?? const <VideoItem>[];
  }

  (int, int) cardRevision(String id) =>
      (_browseRevision, _cardRevisions[id] ?? 0);

  @override
  void notifyListeners() {
    _browseRevision++;
    _browseContents.clear();
    _bilibiliCacheCandidates = null;
    super.notifyListeners();
  }

  /// Preserve legacy service listeners while directory membership stays stable.
  void _notifyCardChanged(String id) {
    _notifyCardsChanged([id]);
  }

  void _notifyCardsChanged(Iterable<String> ids) {
    for (final id in ids) {
      _cardRevisions[id] = (_cardRevisions[id] ?? 0) + 1;
    }
    super.notifyListeners();
  }

  List<dynamic> browseContents(String? parentId) => _browseContents.putIfAbsent(
    parentId,
    () => List<dynamic>.unmodifiable(getContents(parentId)),
  );
  Future<void> _reportDebugEvent(
    String hypothesisId,
    String location,
    String msg, {
    Map<String, Object?>? data,
  }) async {
    if (!kDebugMode) return;
    try {
      final client = HttpClient();
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:7777/event'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'sessionId': 'bilibili-export-crash',
          'runId': 'pre-fix',
          'hypothesisId': hypothesisId,
          'location': location,
          'msg': '[DEBUG] $msg',
          'data': data ?? <String, Object?>{},
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      await request.close();
      client.close(force: true);
    } catch (_) {}
  }

  static final LibraryService _instance = LibraryService._internal();
  factory LibraryService() => _instance;
  LibraryService._internal();

  BilibiliStreamingService? _bilibiliStreamingService;
  MediaMaterializationService? _mediaMaterializationService;
  CloudDriveMaterialization? cloudDriveMaterialization;
  CloudDriveThumbnails? cloudDriveThumbnails;

  /// Also repairs cards created before cloud covers were supported.
  void refreshCloudDriveThumbnails() {
    final items =
        _videos.values
            .where(
              (item) => !item.isRecycled && item.sourceRef?.cloudDrive != null,
            )
            .toList()
          ..sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
    for (final item in items.take(24)) {
      unawaited(ensureThumbnailForVideo(item.id));
    }
  }

  Future<void> rememberCloudDrivePlaybackFrame(
    VideoItem item,
    List<int> bytes,
  ) async {
    final source = item.sourceRef?.cloudDrive;
    if (source == null || cloudDriveThumbnails == null) return;
    final path = await cloudDriveThumbnails!.rememberFrame(source, bytes);
    final current = _videos[item.id];
    if (path == null ||
        current == null ||
        current.sourceRef?.cloudDrive?.sourceKey != source.sourceKey ||
        current.sourceRef?.cloudDrive?.revision != source.revision) {
      return;
    }
    current.thumbnailPath = path;
    await _saveLibrary();
    notifyListeners();
  }

  /// Connects library ownership operations to the live Bilibili gateway.
  ///
  /// The filesystem fallback in [BilibiliStreamingService] keeps recycle-bin
  /// accounting correct during startup/tests, while this live connection also
  /// closes active gateway sessions before a card's cache is deleted.
  void attachBilibiliStreamingService(BilibiliStreamingService? service) {
    if (identical(_bilibiliStreamingService, service)) return;
    _bilibiliStreamingService
      ?..onCacheChanged = null
      ..onVideoShotChanged = null;
    _bilibiliStreamingService = service;
    if (service != null) {
      service.onCacheChanged = notifyOnlineCacheChanged;
      service.onVideoShotChanged = _persistBilibiliVideoShot;
    }
  }

  Future<void> _persistBilibiliVideoShot(VideoItem item) async {
    final stored = _videos[item.id];
    if (stored == null || item.bilibiliVideoShot == null) return;
    stored.bilibiliVideoShot = item.bilibiliVideoShot;
    _invalidateVideoSizeCache(item.id);
    await _saveLibrary();
    notifyListeners();
  }

  void attachMediaMaterializationService(MediaMaterializationService? service) {
    if (identical(_mediaMaterializationService, service)) return;
    _mediaMaterializationService
      ?..onCacheChanged = null
      ..onPlaybackMaterialized = null
      ..onDeferredClearCompleted = null;
    _mediaMaterializationService = service;
    if (service != null) {
      service.onCacheChanged = notifyOnlineCacheChanged;
      service.onPlaybackMaterialized = notifyOnlineCacheChanged;
      service.onDeferredClearCompleted = _clearRemainingOnlineCache;
      unawaited(service.cleanupPendingDeletions());
    }
  }

  MediaMaterializationService? get mediaMaterializationService =>
      _mediaMaterializationService;

  /// All library cards backed by a Bilibili online stream. Watch-only cards
  /// are not library cards and are left out.
  List<VideoItem> get bilibiliStreamItems => _videos.values
      .where((item) => !item.isTransient && _isBilibiliStreamItem(item))
      .toList(growable: false);

  /// Every card that can own online cache: library cards and watch-only
  /// cards. The cache cap and the one-tap clear go through this list.
  List<VideoItem> get onlineCacheItems =>
      _videos.values.where(_isBilibiliStreamItem).toList(growable: false);

  // --- Watch-only cards ---
  //
  // A watch-only card lives next to the library cards so the playback page
  // can look it up, update its progress and subtitles by id like any card.
  // It never joins a folder, and every list, the search, the activity
  // records and library.json skip it. Its ids are written to a small side
  // file so a card left behind by a crash is cleaned on the next start.

  static const String _transientLedgerName = 'transient_cards.json';

  /// Watch-only cards rehydrated for the mini player. The janitor leaves
  /// them alone until playback restore has published the current item.
  final Set<String> _launchRetainedTransientIds = <String>{};

  Set<String> get launchRetainedTransientIds => _launchRetainedTransientIds;

  /// Playback restore finished (or there was nothing to restore). Cards that
  /// are still playing stay via the playback service; the rest can be swept.
  void releaseLaunchRetainedTransients() {
    _launchRetainedTransientIds.clear();
  }

  /// Data directory after [init]. Null before that.
  Directory? get dataRootDirOrNull => _initialized ? _dataRootDir : null;

  /// Includes recycled, nested and transient cards for physical-file accounting.
  List<VideoItem> get storageVideos => List.unmodifiable(_videos.values);
  List<VideoCollection> get storageCollections =>
      List.unmodifiable(_collections.values);

  bool isStorageItemRecycled(String id) {
    final video = _videos[id];
    final collection = _collections[id];
    if (video?.isRecycled == true || collection?.isRecycled == true) {
      return true;
    }
    var parentId = video?.parentId ?? collection?.parentId;
    final seen = <String>{};
    while (parentId != null && seen.add(parentId)) {
      final parent = _collections[parentId];
      if (parent == null) break;
      if (parent.isRecycled) return true;
      parentId = parent.parentId;
    }
    return false;
  }

  Future<void> notifyStorageFilesDeleted(List<String> paths) async {
    final removed = paths
        .map(
          (path) => Platform.isWindows
              ? p.normalize(path).toLowerCase()
              : p.normalize(path),
        )
        .toSet();
    bool wasRemoved(String path) => removed.contains(
      Platform.isWindows ? p.normalize(path).toLowerCase() : p.normalize(path),
    );
    var changed = false;
    for (final item in _videos.values) {
      if (item.bilibiliDownloadPath != null &&
          wasRemoved(item.bilibiliDownloadPath!)) {
        item.bilibiliDownloadPath = null;
        changed = true;
      }
      if (item.playbackPath != null && wasRemoved(item.playbackPath!)) {
        item.playbackPath = null;
        changed = true;
      }
      final subtitleReferences = <String?>[
        item.subtitlePath,
        item.secondarySubtitlePath,
        item.danmakuPath,
        ...?item.additionalSubtitles?.values,
        ...?item.localSubtitles?.values,
        ...?item.recycledSelectedSubtitlePaths,
        ...?item.recycledAdditionalSubtitles?.values,
        ...?item.recycledLocalSubtitles?.values,
        ...item.managedSubtitleAssets.expand((asset) => asset.allFilePaths),
      ];
      if (subtitleReferences.whereType<String>().any(wasRemoved)) {
        if (item.subtitlePath != null && wasRemoved(item.subtitlePath!)) {
          item.subtitlePath = null;
        }
        if (item.secondarySubtitlePath != null &&
            wasRemoved(item.secondarySubtitlePath!)) {
          item.secondarySubtitlePath = null;
        }
        if (item.danmakuPath != null && wasRemoved(item.danmakuPath!)) {
          item.danmakuPath = null;
        }
        if (item.additionalSubtitles != null) {
          item.additionalSubtitles = Map.fromEntries(
            item.additionalSubtitles!.entries.where(
              (entry) => !wasRemoved(entry.value),
            ),
          );
        }
        if (item.localSubtitles != null) {
          item.localSubtitles = Map.fromEntries(
            item.localSubtitles!.entries.where(
              (entry) => !wasRemoved(entry.value),
            ),
          );
        }
        if (item.recycledSelectedSubtitlePaths != null) {
          item.recycledSelectedSubtitlePaths = item
              .recycledSelectedSubtitlePaths!
              .where((path) => !wasRemoved(path))
              .toList();
        }
        if (item.recycledAdditionalSubtitles != null) {
          item.recycledAdditionalSubtitles = Map.fromEntries(
            item.recycledAdditionalSubtitles!.entries.where(
              (entry) => !wasRemoved(entry.value),
            ),
          );
        }
        if (item.recycledLocalSubtitles != null) {
          item.recycledLocalSubtitles = Map.fromEntries(
            item.recycledLocalSubtitles!.entries.where(
              (entry) => !wasRemoved(entry.value),
            ),
          );
        }
        item.managedSubtitleAssets = [
          for (final asset in item.managedSubtitleAssets)
            if (!wasRemoved(asset.path))
              if (asset.wordTimingPath != null &&
                  wasRemoved(asset.wordTimingPath!))
                asset.copyWith(clearWordTimingPath: true)
              else
                asset,
        ];
        changed = true;
      }
      if (item.thumbnailPath != null && wasRemoved(item.thumbnailPath!)) {
        ThumbnailCacheService().evictFromCache(item.id);
        item.thumbnailPath = null;
        changed = true;
      }
      if (item.bilibiliVideoShot?.spritePaths.any(wasRemoved) == true) {
        item.bilibiliVideoShot = null;
        changed = true;
      }
    }
    for (final folder in _collections.values) {
      if (folder.thumbnailPath != null && wasRemoved(folder.thumbnailPath!)) {
        ThumbnailCacheService().evictFromCache(folder.id);
        folder.thumbnailPath = null;
        changed = true;
      }
    }
    _invalidateSizeCaches();
    if (changed) await _saveLibrary();
    notifyListeners();
  }

  /// Removing an offline representation never removes its online media card.
  /// Save the logical source before unlinking a legacy downloaded main file.
  Future<void> detachOfflineMediaFile(String path) async {
    var changed = false;
    for (final item in _videos.values) {
      if (!AppStorageService.samePath(item.path, path)) continue;
      final source = item.sourceRef;
      if (source?.cloudDrive != null) {
        item.path = source!.cloudDrive!.logicalUri;
      } else if (source?.bvid?.isNotEmpty == true && (source?.cid ?? 0) > 0) {
        item.path = 'bilibili://stream/${source!.bvid}/${source.cid}';
        item.sourceRef = source.copyWith(kind: MediaSourceKind.bilibiliStream);
      } else {
        throw StateError('这份文件仍被本地媒体引用，请从媒体库管理原文件');
      }
      if (item.playbackPath != null &&
          AppStorageService.samePath(item.playbackPath!, path)) {
        item.playbackPath = null;
      }
      changed = true;
    }
    if (changed) {
      await _saveLibrary();
      notifyListeners();
    }
  }

  /// Retired compatibility API: keep completed local files local, without
  /// converting their cards back into remote playback identities.
  Future<int> promoteBilibiliDownloadCards(Iterable<String> ids) async => 0;

  /// Saved temporary Bilibili playlist. Only valid after [init].
  File get bilibiliWatchPlaylistFile =>
      File(p.join(_dataRootDir.path, 'bilibili_watch_playlist.json'));
  final List<LibraryProgressObserver> _progressObservers =
      <LibraryProgressObserver>[];
  final List<LibraryRenameObserver> _renameObservers = [];
  Future<void> _transientLedgerWrite = Future<void>.value();

  /// Watch-only cards currently alive.
  List<VideoItem> get transientVideos =>
      _videos.values.where((item) => item.isTransient).toList(growable: false);

  void addProgressObserver(LibraryProgressObserver observer) {
    if (!_progressObservers.contains(observer)) {
      _progressObservers.add(observer);
    }
  }

  void removeProgressObserver(LibraryProgressObserver observer) {
    _progressObservers.remove(observer);
  }

  void addRenameObserver(LibraryRenameObserver observer) {
    if (!_renameObservers.contains(observer)) _renameObservers.add(observer);
  }

  void removeRenameObserver(LibraryRenameObserver observer) {
    _renameObservers.remove(observer);
  }

  /// Registers a watch-only card. It has no folder and is not saved with the
  /// library.
  Future<void> addTransientVideo(VideoItem item) async {
    if (!item.isTransient) {
      throw ArgumentError.value(item.id, 'item', 'not a watch-only card');
    }
    item.parentId = null;
    _videos[item.id] = item;
    _invalidateVideoSizeCache(item.id);
    await _writeTransientLedger();
  }

  /// Registers several watch-only cards at once (one side-list write).
  Future<void> addTransientVideos(Iterable<VideoItem> items) async {
    for (final item in items) {
      if (!item.isTransient) {
        throw ArgumentError.value(item.id, 'items', 'not a watch-only card');
      }
      item.parentId = null;
      _videos[item.id] = item;
      _invalidateVideoSizeCache(item.id);
    }
    await _writeTransientLedger();
  }

  /// Call after filling in data of the card [id] in place (cover, danmaku,
  /// subtitles, ...): a watch-only card's side list is rewritten so its new
  /// files are cleaned up after a crash, a library card is saved.
  Future<void> noteCardDataChanged(String id) async {
    final item = _videos[id];
    if (item == null) return;
    _shareCloudSubtitles(id);
    _invalidateVideoSizeCache(id);
    if (item.isTransient) {
      await _writeTransientLedger();
    } else {
      await _saveLibrary();
    }
    notifyListeners();
  }

  /// Removes files produced after a card was deleted while its data loaded.
  /// Never re-register the detached card, or touch a card that is still owned.
  Future<void> discardDetachedCardData(VideoItem item) async {
    if (_videos.containsKey(item.id)) return;
    await _deleteVideoFiles(item);
  }

  /// Removes a watch-only card together with everything it wrote: online
  /// cache, cover, danmaku, subtitles and preview frames. Library cards are
  /// never touched; returns false for them.
  Future<bool> discardTransientVideo(String id) async {
    final item = _videos[id];
    if (item == null || !item.isTransient) return false;
    _videos.remove(id);
    _activity.media.remove(id);
    _invalidateVideoSizeCache(id);
    await _deleteVideoFiles(item);
    await _writeTransientLedger();
    return true;
  }

  /// Turns the watch-only card [id] into a regular library card in
  /// [parentId] (null: library root), keeping the same id, position and
  /// files, so a card that is playing goes on playing as the library card.
  /// It is saved and shows up in 最近添加 like any new import. Returns null
  /// when [id] is not a watch-only card.
  Future<VideoItem?> promoteTransientVideo(
    String id, {
    String? parentId,
    String? activityBatchId,
  }) async {
    final item = _videos[id];
    if (item == null || !item.isTransient) return null;
    final lastUpdated = item.lastUpdated;
    _videos.remove(id);
    _activity.media.remove(id);
    item.isTransient = false;
    item.parentId = parentId;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    try {
      await addSingleVideo(
        item,
        reuseExistingItem: false,
        activityBatchId: activityBatchId,
        sourceKind: LibraryImportSourceKind.bilibili,
      );
    } catch (_) {
      // Put it back as a watch-only card: it stays in the side list, so its
      // online cache is still cleaned up later instead of being left behind.
      _undoPromotion(item, lastUpdated);
      rethrow;
    } finally {
      await _writeTransientLedger();
    }
    return item;
  }

  void _undoPromotion(VideoItem item, int lastUpdated) {
    final parent = item.parentId == null ? null : _collections[item.parentId];
    parent?.childrenIds.remove(item.id);
    _rootChildrenIds.remove(item.id);
    _activity.media.remove(item.id);
    item
      ..isTransient = true
      ..parentId = null
      ..lastUpdated = lastUpdated;
    _videos[item.id] = item;
    _invalidateVideoSizeCache(item.id);
    notifyListeners();
  }

  File get _transientLedgerFile =>
      File(p.join(_dataRootDir.path, _transientLedgerName));

  @visibleForTesting
  File get transientLedgerFileForTesting => _transientLedgerFile;

  Future<void> _writeTransientLedger() {
    if (!_initialized) return _transientLedgerWrite;
    final file = _transientLedgerFile;
    final cards = <Map<String, dynamic>>[
      for (final item in _videos.values)
        if (item.isTransient) item.toJson(),
    ];
    final next = _transientLedgerWrite.then((_) async {
      try {
        if (cards.isEmpty) {
          if (await file.exists()) await file.delete();
          return;
        }
        await file.writeAsString(json.encode(cards), flush: true);
      } catch (error) {
        developer.log('Watch-only card list not saved', error: error);
      }
    });
    _transientLedgerWrite = next;
    return next;
  }

  /// Startup: removes watch-only cards left by the previous run, except the
  /// one the mini player was still showing. That card is loaded back so
  /// restore can paint the mini player from its title, cover and position
  /// without waiting on a playurl. Every other online card in the side file
  /// is cleaned. A card that is already a library card is never touched.
  Future<int> _purgeTransientLeftovers({bool deferDeletion = false}) async {
    final file = _transientLedgerFile;
    final keepId = await _playbackItemIdToRetain();
    var removed = 0;
    final kept = <VideoItem>[];
    try {
      if (await file.exists()) {
        final decoded = json.decode(await file.readAsString());
        if (decoded is List) {
          for (final raw in decoded) {
            if (raw is! Map) continue;
            final VideoItem item;
            try {
              item = VideoItem.fromJson(Map<String, dynamic>.from(raw));
            } catch (_) {
              continue;
            }
            if (_videos.containsKey(item.id) || !_isBilibiliStreamItem(item)) {
              continue;
            }
            if (keepId != null && item.id == keepId) {
              // The side file is the only copy. It must stay a watch-only
              // card: a library load would put it in a folder. lastUpdated
              // is left as saved so playback restore can still tell whether
              // the card's position is newer than the snapshot.
              item
                ..isTransient = true
                ..parentId = null;
              _videos[item.id] = item;
              _launchRetainedTransientIds.add(item.id);
              kept.add(item);
              continue;
            }
            if (deferDeletion) {
              _startupTransientCleanup.add(item);
            } else {
              await _deleteVideoFiles(item);
            }
            removed++;
          }
        }
      }
    } catch (error) {
      developer.log('Watch-only leftovers not cleaned', error: error);
    }
    if (deferDeletion && _startupTransientCleanup.isNotEmpty) {
      // Keep the durable ledger until deletion succeeds, including across a
      // process death before the first idle period.
      return removed;
    }
    if (kept.isEmpty) {
      _launchRetainedTransientIds.clear();
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    } else {
      await _writeTransientLedger();
    }
    return removed;
  }

  /// The media id in the last playback snapshot, if one was saved.
  Future<String?> _playbackItemIdToRetain() async {
    try {
      // Use the same store as ProgressTracker. Windows/Linux now write a small
      // file; the legacy preference can name an older card (or none at all).
      final snapshot = await PlaybackStateStore.shared.read();
      final id = snapshot?['currentItemId'];
      if (id is! String || id.isEmpty) return null;
      return id;
    } catch (error) {
      developer.log('Playback snapshot not read', error: error);
      return null;
    }
  }

  Future<String> downloadBilibiliAudioForTranscription(
    String videoId, {
    void Function(BilibiliAudioDownloadProgress progress)? onProgress,
    Future<void>? cancelSignal,
  }) async {
    final item = _videos[videoId];
    if (item == null) throw StateError('媒体库中找不到该视频卡片');
    if (!_isBilibiliStreamItem(item)) {
      throw StateError('该视频不是 Bilibili 在线播放卡片');
    }
    final service = _bilibiliStreamingService;
    if (service == null) throw StateError('Bilibili 在线服务尚未初始化');
    return service.downloadAudioForTranscription(
      item,
      onProgress: onProgress,
      cancelSignal: cancelSignal,
    );
  }

  Future<List<CacheQuality>> onlineVideoMaterializationQualities(
    String videoId,
  ) async {
    final item = _videos[videoId];
    if (item == null) throw StateError('媒体库中找不到该视频卡片');
    if (item.sourceRef?.podcast != null) {
      if (item.type == MediaType.audio) return const [];
      return const [CacheQuality(id: 'original', label: '播客原视频')];
    }
    final localVariants = await _discoverReusableMedia(item);
    final local = <String, CacheQuality>{
      for (final quality
          in MediaCacheHooks.qualities?.call(item) ?? <CacheQuality>[])
        quality.id: quality,
      for (final variant in localVariants)
        if (variant.available && variant.content != CacheContent.audio)
          variant.quality.id: variant.quality,
    };
    try {
      final List<CacheQuality> remote;
      if (_isCloudDriveItem(item)) {
        final cloud = cloudDriveMaterialization;
        if (cloud == null) throw StateError('网盘素材服务尚未初始化');
        remote = await cloud.videoQualities(item);
      } else {
        final service = _mediaMaterializationService;
        if (service == null) throw StateError('本地素材服务尚未初始化');
        remote = await service.videoQualities(item);
      }
      return {
        ...local,
        for (final quality in remote) quality.id: quality,
      }.values.toList();
    } catch (_) {
      // Previously sealed video remains usable while offline or logged out.
      if (local.isNotEmpty) return local.values.toList();
      rethrow;
    }
  }

  // Pin only this material request. OCR quality must never change playback's
  // preferred representation or mutate the library card.
  VideoItem _materializationItem(VideoItem item, String? qualityId) {
    if (qualityId == null) return item;
    final cloud = item.sourceRef?.cloudDrive;
    if (cloud != null) {
      final source = item.sourceRef!.copyWith(
        cloudDrive: CloudDriveSourceRef(
          version: cloud.version,
          providerId: cloud.providerId,
          remoteAccountId: cloud.remoteAccountId,
          driveId: cloud.driveId,
          fileId: cloud.fileId,
          pathHint: cloud.pathHint,
          revision: cloud.revision,
          preferredQuality: qualityId,
        ),
      );
      return VideoItem.fromJson({
        ...item.toJson(),
        'sourceRef': source.toJson(),
      });
    }
    if (item.sourceRef?.podcast != null && qualityId != 'original') {
      throw StateError('视频播客仅支持下载来源提供的原视频');
    }
    return item;
  }

  Future<MediaMaterializationEstimate> estimateOnlineMediaMaterialization(
    String videoId,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
    String? qualityId,
  }) async {
    final sourceItem = _videos[videoId];
    if (sourceItem == null) throw StateError('媒体库中找不到该视频卡片');
    requireCommunityProcessingSource(
      sourceItem.path,
      source: sourceItem.sourceRef,
    );
    if (communityMediaIsLocal(sourceItem.path)) {
      final file = File(communityLocalMediaPath(sourceItem.path));
      final exists = await file.exists();
      return MediaMaterializationEstimate(
        estimatedBytes: exists ? await file.length() : null,
        qualityId: null,
        width: null,
        height: null,
        qualityLabel: '本地文件',
        alreadyAvailable: exists,
        requiresVideoDownload: false,
        requiresAudioDownload: false,
      );
    }
    final item = _materializationItem(sourceItem, qualityId);
    if (qualityId != null) targetHeight = null;
    await _discoverReusableMedia(item);
    final cached = MediaCacheHooks.acquireMaterial == null
        ? await MediaCacheHooks.acquire?.call(item, qualityId: qualityId)
        : await MediaCacheHooks.acquireMaterial!(
            item,
            requirement,
            targetHeight: targetHeight,
            qualityId: qualityId,
          );
    if (cached != null) {
      final usable =
          item.sourceRef?.podcast != null ||
          targetHeight == null ||
          (cached.height ?? 0) >= targetHeight;
      await cached.release();
      if (usable) {
        return MediaMaterializationEstimate(
          estimatedBytes: 0,
          qualityId: cached.qualityId,
          width: cached.width,
          height: cached.height,
          qualityLabel: '使用已缓存媒体',
          alreadyAvailable: true,
          requiresVideoDownload: false,
          requiresAudioDownload: false,
        );
      }
    }
    if (_isCloudDriveItem(item)) {
      final cloud = cloudDriveMaterialization;
      if (cloud == null) throw StateError('网盘素材服务尚未初始化');
      return cloud.estimate(item, requirement);
    }
    if (item.sourceRef?.podcast != null) {
      return MediaMaterializationEstimate(
        estimatedBytes: null,
        qualityId: null,
        width: null,
        height: null,
        qualityLabel: requirement == MediaMaterializationRequirement.audioOnly
            ? '播客原音质'
            : '播客原视频',
        alreadyAvailable: false,
        requiresVideoDownload:
            requirement != MediaMaterializationRequirement.audioOnly,
        requiresAudioDownload:
            requirement == MediaMaterializationRequirement.audioOnly,
      );
    }
    final service = _mediaMaterializationService;
    if (service == null) throw StateError('本地素材服务尚未初始化');
    return service.estimate(
      item,
      requirement,
      targetHeight: targetHeight,
      qualityId: qualityId,
    );
  }

  Future<MaterializedMediaLease> acquireMaterializedMedia(
    String videoId,
    MediaMaterializationRequirement requirement, {
    int? targetHeight,
    String? qualityId,
    void Function(MediaMaterializationProgress progress)? onProgress,
    Future<void>? cancelSignal,
    VideoItem? sourceItem,
  }) async {
    final original = sourceItem ?? _videos[videoId];
    if (original == null) throw StateError('媒体库中找不到该视频卡片');
    if (original.id != videoId) throw StateError('媒体来源与任务不一致，请重新开始');
    requireCommunityProcessingSource(original.path, source: original.sourceRef);
    if (communityMediaIsLocal(original.path)) {
      final path = communityLocalMediaPath(original.path);
      if (!await File(path).exists()) throw StateError('媒体文件不存在');
      return MaterializedMediaLease(
        videoId: original.id,
        audioPath: requirement == MediaMaterializationRequirement.videoFrames
            ? null
            : path,
        videoPath: path,
        completePath: path,
        qualityId: null,
        width: null,
        height: null,
        onRelease: () async {},
      );
    }
    final item = _materializationItem(original, qualityId);
    if (qualityId != null) targetHeight = null;
    await _discoverReusableMedia(item);
    final cached = MediaCacheHooks.acquireMaterial == null
        ? await MediaCacheHooks.acquire?.call(item, qualityId: qualityId)
        : await MediaCacheHooks.acquireMaterial!(
            item,
            requirement,
            targetHeight: targetHeight,
            qualityId: qualityId,
          );
    if (cached != null) {
      if (item.sourceRef?.podcast != null ||
          targetHeight == null ||
          (cached.height ?? 0) >= targetHeight) {
        return cached;
      }
      await cached.release();
    }
    if (_isCloudDriveItem(item)) {
      final cloud = cloudDriveMaterialization;
      if (cloud == null) throw StateError('网盘素材服务尚未初始化');
      return cloud.acquire(
        item,
        requirement,
        onProgress: onProgress,
        cancelSignal: cancelSignal,
      );
    }
    if (item.sourceRef?.podcast != null) {
      final prepare = requirement == MediaMaterializationRequirement.audioOnly
          ? PodcastPlaybackHooks.materialize
          : PodcastPlaybackHooks.materializeVideo;
      if (prepare == null) throw StateError('播客素材服务尚未初始化');
      final path = await prepare(
        item,
        cancelSignal: cancelSignal,
        onProgress: (progress) => onProgress?.call(
          MediaMaterializationProgress(
            stage: requirement == MediaMaterializationRequirement.audioOnly
                ? MediaMaterializationStage.downloadingAudio
                : MediaMaterializationStage.downloadingVideo,
            progress: progress.fraction,
            message: progress.message,
            receivedBytes: progress.receivedBytes,
            totalBytes: progress.totalBytes,
            bytesPerSecond: progress.bytesPerSecond,
            remaining: progress.remaining,
          ),
        ),
      );
      return MaterializedMediaLease(
        videoId: item.id,
        audioPath: path,
        videoPath: item.type == MediaType.audio ? null : path,
        completePath: path,
        qualityId: null,
        width: null,
        height: null,
        onRelease: () async =>
            PodcastPlaybackHooks.releaseMaterialized?.call(item),
      );
    }
    final service = _mediaMaterializationService;
    if (service == null) throw StateError('本地素材服务尚未初始化');
    return service.acquire(
      item,
      requirement,
      targetHeight: targetHeight,
      qualityId: qualityId,
      onProgress: onProgress,
      cancelSignal: cancelSignal,
    );
  }

  Future<MaterializedMediaLease?> acquireExistingMaterializedPlayback(
    VideoItem item, {
    String? qualityId,
  }) async {
    requireCommunityPlaybackSource(item.path, source: item.sourceRef);
    if (communityMediaIsLocal(item.path) || item.sourceRef?.podcast != null) {
      return null;
    }
    // A sealed, indexed file is already validated by acquisition. Do not put
    // a materialization-directory scan and registry writes ahead of playback.
    final existing = await MediaCacheHooks.acquire?.call(
      item,
      qualityId: qualityId,
    );
    if (existing != null) return existing;
    await _discoverReusableMedia(item);
    final cached = await MediaCacheHooks.acquire?.call(
      item,
      qualityId: qualityId,
    );
    if (cached != null) return cached;
    if (qualityId != null) return null;
    return _mediaMaterializationService?.acquireExistingPlayback(item) ??
        Future<MaterializedMediaLease?>.value(null);
  }

  Future<List<CacheVariant>> _discoverReusableMedia(VideoItem item) async {
    final source = CacheSource.fromItem(item);
    final discover = MediaCacheHooks.discover;
    if (source == null || discover == null) return const [];
    try {
      final variants = await discover(source);
      await MediaCacheHooks.publish?.call(variants);
      return variants;
    } catch (error) {
      developer.log(
        'Reusable media cache indexing deferred',
        error: error.runtimeType,
      );
      return const [];
    }
  }

  static const Set<String> supportedVideoExtensions = kSupportedVideoExtensions;
  static const Set<String> supportedAudioExtensions = kSupportedAudioExtensions;
  static const Set<String> supportedMediaExtensions = {
    ...supportedVideoExtensions,
    ...supportedAudioExtensions,
  };
  static const List<String> _supportedArchiveSuffixes = [
    '.zip',
    '.tar',
    '.tgz',
    '.tar.gz',
    '.tbz',
    '.tbz2',
    '.tar.bz2',
    '.txz',
    '.tar.xz',
  ];
  static const String _archiveImportMarkerName = '.import_in_progress.json';
  static const String _importedArchivesDirName = 'imported_archives';
  static const String _pickedArchivesCacheDirName = 'picked_archives';

  // Unified storage: ID -> Object
  Map<String, VideoCollection> _collections = {};
  Map<String, VideoItem> _videos = {};
  LibraryActivityStore _activity = LibraryActivityStore.empty();
  final Map<String, ImportBatchRecord> _openImportBatches = {};
  final Map<String, Future<ImportReceipt>> _downloadImportInflight = {};
  final Map<String, Future<VideoCollection>> _downloadFolderInflight = {};
  bool _activityUnknownFuture = false;
  Map<String, dynamic>? _preservedActivityRaw;
  final ValueNotifier<int> activityRevision = ValueNotifier<int>(0);
  final Map<String, Future<String?>> _thumbnailRepairInFlight = {};

  // Root level structure (IDs of collections and videos at root)
  List<String> _rootChildrenIds = [];
  final Map<String, Future<String>> _importSourceFolderInflight = {};
  final Map<String, int> _itemSizeCache = {};
  final Map<String, Future<int>> _itemSizeInFlight = {};
  Map<String, Set<String>>? _storageFileOwnersIndex;
  final List<Completer<void>> _sizeCalculationWaitQueue = [];
  int _activeSizeCalculationCount = 0;

  // Legacy getters (backward compatibility) - DO NOT USE FOR NEW LOGIC if possible
  List<VideoCollection> get collections =>
      _collections.values
          .where(
            (c) =>
                c.parentId == null &&
                !c.isRecycled &&
                !c.isHiddenFromFolders &&
                _isCommunityLocalCollection(c),
          )
          .toList()
        ..sort((a, b) => b.createTime.compareTo(a.createTime)); // Default sort

  // New: Get Recycle Bin Items (Mixed)
  List<dynamic> getRecycleBinContents() {
    final recycledCols = _collections.values
        .where((c) => c.isRecycled && _isCommunityLocalCollection(c))
        .toList();
    final recycledVideos = _videos.values
        .where((v) => v.isRecycled && _isCommunityLocalVideo(v))
        .toList();

    // Logic: Only show items whose parent is NOT recycled (or has no parent).
    // If a parent is recycled, its children are implicitly recycled and hidden from top-level bin view.
    // However, if we support independent recycling, we need to check parent status.

    // Helper to check if any ancestor is recycled
    bool isAncestorRecycled(String? parentId) {
      if (parentId == null) return false;
      final parentCol = _collections[parentId];
      if (parentCol == null) return false; // Parent missing, treat as root-ish
      if (parentCol.isRecycled) return true;
      return isAncestorRecycled(parentCol.parentId);
    }

    final visibleCols = recycledCols
        .where((c) => !isAncestorRecycled(c.parentId))
        .toList();
    final visibleVideos = recycledVideos
        .where((v) => !isAncestorRecycled(v.parentId))
        .toList();

    return [...visibleCols, ...visibleVideos]..sort((a, b) {
      // Sort by recycle time if available, else updated time
      final timeA =
          (a is VideoCollection
              ? a.recycleTime
              : (a as VideoItem).recycleTime) ??
          0;
      final timeB =
          (b is VideoCollection
              ? b.recycleTime
              : (b as VideoItem).recycleTime) ??
          0;
      return timeB.compareTo(timeA);
    });
  }

  Map<String, VideoItem>? _cloudDriveCardsIndex;

  VideoItem? cloudDriveCardForSource(String sourceKey) {
    if (_cloudDriveCardsIndex == null) {
      final index = <String, VideoItem>{};
      for (final item in _videos.values) {
        final key = item.sourceRef?.cloudDrive?.sourceKey;
        if (key == null || item.isRecycled) continue;
        final previous = index[key];
        if (previous == null || previous.lastUpdated < item.lastUpdated) {
          index[key] = item;
        }
      }
      _cloudDriveCardsIndex = index;
    }
    return _cloudDriveCardsIndex![sourceKey];
  }

  VideoItem? getVideo(String id) => _videos[id];
  VideoCollection? getCollection(String id) => _collections[id];

  // Recycled children may have been detached from the visible children list.
  List<String> _collectionChildIdsIncludingRecycled(String id) => {
    ...?_collections[id]?.childrenIds,
    ..._collections.values.where((c) => c.parentId == id).map((c) => c.id),
    ..._videos.values.where((v) => v.parentId == id).map((v) => v.id),
  }.toList();

  /// Videos on one recycle-bin page, in that page's order.
  ///
  /// Null [folderId] is the bin root. A folder id is only the videos shown
  /// inside that folder, so a nested folder stays its own playback queue.
  List<VideoItem> getRecycleBinDirectoryVideos(String? folderId) {
    final contents = folderId == null
        ? getRecycleBinContents()
        : getRecycledFolderContents(folderId);
    return [
      for (final item in contents)
        if (item is VideoItem) item,
    ];
  }

  /// Includes both independently deleted and implicitly recycled children.
  /// After a partial restore this view keeps only the remaining recycled items.
  List<dynamic> getRecycledFolderContents(String folderId) => [
    for (final id in _collectionChildIdsIncludingRecycled(folderId))
      if (isStorageItemRecycled(id))
        if (_libraryCollection(id) case final VideoCollection collection)
          collection
        else if (_libraryVideo(id) case final VideoItem video)
          video,
  ];

  /// Local file cards can restore a missing path. Streams, URLs, and Bilibili
  /// identities must not enter the file-picker recovery flow.
  bool canRelocateLocalMediaSource(VideoItem item) =>
      !item.isRecycled && communityMediaIsLocal(item.path);

  bool _restoreCompletedLocalDownload(VideoItem item) {
    if (communityMediaIsLocal(item.path) ||
        !(item.path.startsWith('bilibili://stream/') ||
            item.sourceRef?.kind == MediaSourceKind.bilibiliStream)) {
      return false;
    }
    final owned = item.bilibiliDownloadPath;
    if (owned == null || !communityMediaIsLocal(owned)) return false;
    final path = communityLocalMediaPath(owned);
    if (!isSupportedMediaPath(path)) return false;
    try {
      final stat = File(path).statSync();
      if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
        return false;
      }
      item.path = path;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  bool _isCommunityLocalVideo(VideoItem item) =>
      !item.isTransient &&
      communityMediaIsPlayable(item.path, source: item.sourceRef);

  // Keep ordinary folders, including empty ones. Retired source folders remain
  // visible only when they contain local files; all persisted rows stay intact.
  bool _isCommunityLocalCollection(VideoCollection collection) {
    if (collection.podcastRef != null || collection.sourceRef == null) {
      return true;
    }
    final seen = <String>{};
    bool hasLocalDescendant(VideoCollection folder) {
      if (!seen.add(folder.id)) return false;
      for (final id in folder.childrenIds) {
        final video = _videos[id];
        if (video != null && _isCommunityLocalVideo(video)) return true;
        final child = _collections[id];
        if (child != null && hasLocalDescendant(child)) return true;
      }
      return false;
    }

    return hasLocalDescendant(collection);
  }

  VideoCollection? _libraryCollection(String id) {
    final collection = _collections[id];
    return collection != null && _isCommunityLocalCollection(collection)
        ? collection
        : null;
  }

  LibraryActivityProjection get activityProjection {
    return LibraryActivityProjection(
      store: _activity,
      videoOf: (id) {
        final item = _libraryVideo(id);
        return item == null ? null : _localActivityItem(item);
      },
      collectionOf: _libraryCollection,
      allVideos: () =>
          _videos.values.where(_isCommunityLocalVideo).map(_localActivityItem),
    );
  }

  // Activity's old provider grouping must not hide downloaded local files.
  // Project only for reads; the persisted provenance and task identity remain.
  VideoItem _localActivityItem(VideoItem item) =>
      item.sourceRef == null ||
          (!communityMediaIsLocal(item.path) && item.sourceRef?.podcast != null)
      ? item
      : VideoItem.fromJson({...item.toJson(), 'sourceRef': null});

  /// Library card [id]; null for unknown ids and watch-only cards.
  VideoItem? _libraryVideo(String id) {
    final item = _videos[id];
    return item == null || !_isCommunityLocalVideo(item) ? null : item;
  }

  MediaActivityRecord? mediaActivity(String id) => _activity.media[id];

  List<ImportBatchRecord> get importBatches =>
      List<ImportBatchRecord>.unmodifiable(_activity.batches);

  List<String> get pinnedItemIds =>
      List<String>.unmodifiable(_activity.pinnedIds);

  /// Cards removed from 最近添加. Media and folder ids share this list.
  List<String> get recentDismissedIds =>
      List<String>.unmodifiable(_activity.recentDismissedIds);

  bool get _canMutateActivity => !_activityUnknownFuture;

  void _bumpActivity({required bool notifyLibrary}) {
    activityRevision.value++;
    if (notifyLibrary) {
      super.notifyListeners();
    }
  }

  Future<void> _persistActivity({required bool notifyLibrary}) async {
    if (!_canMutateActivity) return;
    await _saveLibrary();
    _bumpActivity(notifyLibrary: notifyLibrary);
  }

  void _purgeActivityForDeletedMedia(String mediaId) {
    _activity.media.remove(mediaId);
    _activity.pinnedIds.remove(mediaId);
    for (final batch in _activity.batches) {
      batch.createdMediaIds.remove(mediaId);
      batch.downloadReceipts.removeWhere((_, id) => id == mediaId);
    }
    _activity.batches.removeWhere(
      (batch) =>
          batch.createdMediaIds.isEmpty && batch.downloadReceipts.isEmpty,
    );
    for (final batch in _openImportBatches.values) {
      batch.createdMediaIds.remove(mediaId);
    }
    _activity.recentDismissedIds.remove(mediaId);
  }

  void _purgeActivityForDeletedCollection(String collectionId) {
    _activity.pinnedIds.remove(collectionId);
    _activity.recentDismissedIds.remove(collectionId);
  }

  Future<void> registerImportedMedia(
    String mediaId, {
    int? addedAtMs,
    String? batchId,
  }) async {
    noteImportedMedia(mediaId, addedAtMs: addedAtMs, batchId: batchId);
    await _persistActivity(notifyLibrary: true);
  }

  void noteImportedMedia(String mediaId, {int? addedAtMs, String? batchId}) {
    if (!_canMutateActivity || !_videos.containsKey(mediaId)) return;
    final record = _activity.ensureMedia(mediaId);
    if (record.addedAtMs == null && addedAtMs != null) {
      record.addedAtMs = addedAtMs;
    }
    if (batchId == null) return;
    final batch = _openImportBatches[batchId];
    if (batch == null) return;
    if (!batch.createdMediaIds.contains(mediaId)) {
      batch.createdMediaIds.add(mediaId);
    }
  }

  void noteImportedCollection(String collectionId, {required String? batchId}) {
    if (batchId == null || !_canMutateActivity) return;
    if (!_collections.containsKey(collectionId)) return;
    final batch = _openImportBatches[batchId];
    if (batch == null) return;
    if (!batch.createdCollectionIds.contains(collectionId)) {
      batch.createdCollectionIds.add(collectionId);
    }
  }

  String? beginImportBatch({
    required String title,
    required LibraryImportSourceKind sourceKind,
    String? targetCollectionId,
    int? startedAtMs,
  }) {
    if (!_canMutateActivity) return null;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    final id = const Uuid().v4();
    _openImportBatches[id] = ImportBatchRecord(
      id: id,
      startedAtMs: startedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      title: trimmed,
      sourceKind: sourceKind,
      targetCollectionId: targetCollectionId,
    );
    return id;
  }

  Future<bool> completeImportBatch(
    String batchId, {
    bool persist = true,
  }) async {
    if (!_canMutateActivity) return false;
    if (_activity.batches.any((batch) => batch.id == batchId)) {
      return true;
    }
    final open = _openImportBatches.remove(batchId);
    if (open == null) return false;
    open.createdMediaIds.removeWhere((id) => !_videos.containsKey(id));
    if (open.createdMediaIds.isEmpty) return false;
    _activity.batches.insert(0, open);
    if (persist) {
      await _persistActivity(notifyLibrary: true);
    }
    return true;
  }

  void abortImportBatch(String batchId) {
    _openImportBatches.remove(batchId);
  }

  Future<void> pinLibraryItem(String id) async {
    if (!_canMutateActivity) return;
    if (!_videos.containsKey(id) && !_collections.containsKey(id)) return;
    _activity.pinnedIds.remove(id);
    _activity.pinnedIds.insert(0, id);
    await _persistActivity(notifyLibrary: true);
  }

  Future<void> unpinLibraryItem(String id) async {
    if (!_canMutateActivity) return;
    if (!_activity.pinnedIds.remove(id)) return;
    await _persistActivity(notifyLibrary: true);
  }

  /// Pin-strip drop only. Indices are [visiblePinnedIds], never folder children.
  Future<void> reorderVisiblePinnedLibraryItems(
    int fromVisibleIndex,
    int toVisibleIndex,
  ) async {
    if (!_canMutateActivity) return;
    final visible = activityProjection.visiblePinnedIds();
    final next = LibraryActivityStore.reorderVisiblePinnedIds(
      pinnedIds: _activity.pinnedIds,
      visibleIds: visible.toSet(),
      fromVisibleIndex: fromVisibleIndex,
      toVisibleIndex: toVisibleIndex,
    );
    if (listEquals(next, _activity.pinnedIds)) return;
    _activity.pinnedIds
      ..clear()
      ..addAll(next);
    await _persistActivity(notifyLibrary: true);
  }

  Future<void> hideLibraryMedia(String mediaId) async {
    if (!_canMutateActivity || !_videos.containsKey(mediaId)) return;
    _activity.ensureMedia(mediaId).hidden = true;
    _shareCloudActivity(mediaId, played: false);
    await _persistActivity(notifyLibrary: true);
  }

  Future<void> unhideLibraryMedia(String mediaId) async {
    if (!_canMutateActivity || !_videos.containsKey(mediaId)) return;
    final record = _activity.media[mediaId];
    if (record == null || !record.hidden) return;
    record.hidden = false;
    _shareCloudActivity(mediaId, played: false);
    await _persistActivity(notifyLibrary: true);
  }

  /// Hides one 最近添加 card. [id] may be a media item or a folder.
  ///
  /// Leaves the file, folder, progress, continue-learning row, and history
  /// in place. A later play does not put the card back; only
  /// [restoreRecentAdded] does.
  Future<bool> dismissFromRecentAdded(String id) async {
    if (!_canMutateActivity) return false;
    final trimmed = id.trim();
    if (trimmed.isEmpty) return false;
    if (!_videos.containsKey(trimmed) && !_collections.containsKey(trimmed)) {
      developer.log(
        'Skipped recent dismiss for unknown id $trimmed',
        name: 'LibraryActivity',
        level: 500,
      );
      return false;
    }
    if (!_activity.recentDismissedIds.add(trimmed)) return false;
    developer.log(
      'Dismissed $trimmed from recent added',
      name: 'LibraryActivity',
      level: 800,
    );
    await _persistActivity(notifyLibrary: true);
    return true;
  }

  /// Puts a previously dismissed 最近添加 card back on that page.
  Future<bool> restoreRecentAdded(String id) async {
    if (!_canMutateActivity) return false;
    final trimmed = id.trim();
    if (!_activity.recentDismissedIds.remove(trimmed)) return false;
    developer.log(
      'Restored $trimmed to recent added',
      name: 'LibraryActivity',
      level: 800,
    );
    await _persistActivity(notifyLibrary: true);
    return true;
  }

  void recordValidPlaybackProgress(
    String mediaId, {
    required int deltaWatchMs,
    int? lastPlayedAtMs,
  }) {
    if (!_canMutateActivity || deltaWatchMs <= 0) return;
    if (_libraryVideo(mediaId) == null) return;
    final record = _activity.ensureMedia(mediaId);
    record.accumulatedWatchMs += deltaWatchMs;
    if (lastPlayedAtMs != null) {
      record.lastPlayedAtMs = lastPlayedAtMs;
    }
    _shareCloudActivity(mediaId, played: true);
    _scheduleDebouncedSave();
  }

  Future<void> recordPlaybackCompleted(
    String mediaId, {
    int? completedAtMs,
  }) async {
    if (!_canMutateActivity || _libraryVideo(mediaId) == null) return;
    final record = _activity.ensureMedia(mediaId);
    record.completed = true;
    if (completedAtMs != null) {
      record.lastPlayedAtMs = completedAtMs;
    }
    _shareCloudActivity(mediaId, played: completedAtMs != null);
    await _persistActivity(notifyLibrary: true);
  }

  /// Applies a watch-meter flush. Progress stays on the existing debounce;
  /// enrollment / hide / complete stay immediate.
  Future<void> applyWatchFlush({
    required String mediaId,
    required int deltaWatchMs,
    int? lastPlayedAtMs,
    bool enrolled = false,
    bool uncomplete = false,
    bool unhide = false,
    bool completed = false,
    int? completedAtMs,
  }) async {
    final item = _libraryVideo(mediaId);
    if (!_canMutateActivity || item == null) return;
    // First history stamp and first continue-enrollment persist immediately.
    // Later lastPlayedAt ticks stay on the progress debounce.
    final existing = _activity.media[mediaId];
    final hadLastPlayedAt = existing?.lastPlayedAtMs != null;
    final hadContinueEnrolled = existing?.continueEnrolled == true;
    if (deltaWatchMs > 0) {
      recordValidPlaybackProgress(
        mediaId,
        deltaWatchMs: deltaWatchMs,
        lastPlayedAtMs: lastPlayedAtMs,
      );
    } else if (lastPlayedAtMs != null) {
      final record = _activity.ensureMedia(mediaId);
      record.lastPlayedAtMs = lastPlayedAtMs;
      _scheduleDebouncedSave();
    }
    var boundary = false;
    final record = _activity.ensureMedia(mediaId);
    if (lastPlayedAtMs != null && !hadLastPlayedAt) {
      boundary = true;
    }
    if (enrolled && !hadContinueEnrolled) {
      record.continueEnrolled = true;
      boundary = true;
    }
    // A podcast's listened flag records a completed listen. Replaying it can
    // update its bookmark without undoing that history.
    if (uncomplete && record.completed && item.sourceRef?.podcast == null) {
      record.completed = false;
      boundary = true;
    }
    if (unhide && record.hidden) {
      record.hidden = false;
      boundary = true;
    }
    if (completed) {
      record.completed = true;
      if (completedAtMs != null) {
        record.lastPlayedAtMs = completedAtMs;
      }
      boundary = true;
    }
    _shareCloudActivity(mediaId, played: lastPlayedAtMs != null);
    if (boundary) {
      await _persistActivity(notifyLibrary: true);
    }
  }

  /// Drops watch clocks only. Import times, pins and hidden flags stay.
  Future<bool> clearPlaybackHistory() async {
    if (!_canMutateActivity) return false;
    var changed = false;
    for (final record in _activity.media.values) {
      if (record.lastPlayedAtMs == null &&
          record.accumulatedWatchMs == 0 &&
          !record.continueEnrolled &&
          !record.completed) {
        continue;
      }
      record.lastPlayedAtMs = null;
      record.accumulatedWatchMs = 0;
      record.continueEnrolled = false;
      record.completed = false;
      changed = true;
    }
    if (!changed) return true;
    await _persistActivity(notifyLibrary: true);
    return true;
  }

  /// 获取指定文件夹中的所有视频（不包括回收站中的），并按照正确的顺序排列
  List<VideoItem> getVideosInFolder(String? folderId) {
    List<String> sourceIds;
    if (folderId == null) {
      sourceIds = _rootChildrenIds;
    } else {
      final collection = _collections[folderId];
      if (collection == null) return [];
      sourceIds = collection.childrenIds;
    }

    final List<VideoItem> result = [];
    for (var id in sourceIds) {
      final video = _videos[id];
      if (video != null && !video.isRecycled && _isCommunityLocalVideo(video)) {
        result.add(video);
      }
    }
    return result;
  }

  // Helper function to detect media type from file extension
  MediaType _detectMediaType(String path) {
    final ext = p.extension(path).toLowerCase();
    if (supportedAudioExtensions.contains(ext)) {
      return MediaType.audio;
    }
    return MediaType.video;
  }

  static bool isSupportedMediaPath(String path) {
    return supportedMediaExtensions.contains(p.extension(path).toLowerCase());
  }

  static bool isSupportedArchivePath(String path) {
    final lowerPath = path.toLowerCase();
    for (final suffix in _supportedArchiveSuffixes) {
      if (lowerPath.endsWith(suffix)) {
        return true;
      }
    }
    return false;
  }

  @visibleForTesting
  static Map<String, int> extractArchiveForTesting({
    required String archivePath,
    required String outputPath,
    int? maxEntryCount,
    int? maxTotalBytes,
    int? maxSingleFileBytes,
    int? maxPathDepth,
    int? maxCompressionRatio,
  }) {
    return _extractArchiveToDiskWithParentsSync(
      archivePath: archivePath,
      outputPath: outputPath,
      maxEntryCount: maxEntryCount,
      maxTotalBytes: maxTotalBytes,
      maxSingleFileBytes: maxSingleFileBytes,
      maxPathDepth: maxPathDepth,
      maxCompressionRatio: maxCompressionRatio,
    );
  }

  static String archiveDisplayName(String archivePath) {
    return p.basename(archivePath);
  }

  static String archiveRootCollectionName(String archivePath) {
    final name = p.basename(archivePath);
    final lowerName = name.toLowerCase();
    for (final suffix in _supportedArchiveSuffixes) {
      if (lowerName.endsWith(suffix)) {
        final trimmed = name.substring(0, name.length - suffix.length).trim();
        if (trimmed.isNotEmpty) {
          return trimmed;
        }
      }
    }
    final fallback = p.basenameWithoutExtension(name).trim();
    return fallback.isEmpty ? name : fallback;
  }

  Future<String?> _computeSourceFingerprint(String path) async {
    if (isCloudDriveLogicalPath(path) ||
        path.startsWith('bilibili://') ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      return null;
    }
    try {
      final file = File(path);
      if (!await file.exists()) {
        return null;
      }
      final length = await file.length();
      final raf = await file.open(mode: FileMode.read);
      try {
        const chunkSize = 64 * 1024;
        final builder = BytesBuilder(copy: false);
        builder.add(utf8.encode('$length|'));
        final headSize = min(chunkSize, length);
        if (headSize > 0) {
          builder.add(await raf.read(headSize));
        }
        if (length > chunkSize) {
          await raf.setPosition(max(0, length - chunkSize));
          builder.add(await raf.read(min(chunkSize, length)));
        }
        final digest = sha256.convert(builder.takeBytes()).toString();
        return 'v1:$length:$digest';
      } finally {
        await raf.close();
      }
    } catch (e) {
      developer.log('Compute fingerprint failed: $path', error: e);
      return null;
    }
  }

  Future<String?> _findExistingVideoIdByPathOrFingerprint(
    String path, {
    String? sourceFingerprint,
    String? originalTitle,
    bool requireInternalMatchForFingerprint = false,
  }) async {
    final normalizedPath = p.normalize(path);
    final normalizedName = resolveImportedMediaTitle(
      sourcePath: path,
      originalTitle: originalTitle,
    ).toLowerCase();
    int? candidateSize;
    try {
      candidateSize = await File(path).length();
    } catch (_) {}

    bool fingerprintBackfilled = false;

    for (final entry in _videos.entries) {
      final existing = entry.value;
      if (_samePath(existing.path, normalizedPath)) {
        return entry.key;
      }
      if (sourceFingerprint != null &&
          existing.sourceFingerprint != null &&
          (!requireInternalMatchForFingerprint ||
              _isInternalPath(existing.path)) &&
          existing.sourceFingerprint == sourceFingerprint) {
        return entry.key;
      }
      if (sourceFingerprint == null || existing.sourceFingerprint != null) {
        continue;
      }

      final existingName = resolveImportedMediaTitle(
        sourcePath: existing.path,
        originalTitle: existing.title,
      ).toLowerCase();
      if (existingName != normalizedName) {
        continue;
      }
      if (requireInternalMatchForFingerprint &&
          !_isInternalPath(existing.path)) {
        continue;
      }

      int? existingSize;
      try {
        existingSize = await File(existing.path).length();
      } catch (_) {}
      if (candidateSize == null ||
          existingSize == null ||
          candidateSize != existingSize) {
        continue;
      }

      final existingFingerprint = await _computeSourceFingerprint(
        existing.path,
      );
      if (existingFingerprint == null) {
        continue;
      }
      existing.sourceFingerprint = existingFingerprint;
      fingerprintBackfilled = true;
      if (existingFingerprint == sourceFingerprint) {
        if (fingerprintBackfilled) {
          await _saveLibrary();
        }
        return entry.key;
      }
    }

    if (fingerprintBackfilled) {
      await _saveLibrary();
    }
    return null;
  }

  Future<bool> _restoreExistingVideoToTarget(
    String existingId,
    String? parentId, {
    bool persist = true,
    bool notify = true,
    bool preserveOrder = false,
  }) async {
    final existingVideo = _videos[existingId];
    if (existingVideo == null) {
      return false;
    }

    final wasRecycled = existingVideo.isRecycled;
    final siblings = parentId == null
        ? _rootChildrenIds
        : _collections[parentId]?.childrenIds;
    if (preserveOrder &&
        !wasRecycled &&
        existingVideo.parentId == parentId &&
        siblings?.contains(existingId) == true) {
      return true;
    }
    if (wasRecycled) {
      existingVideo.isRecycled = false;
      existingVideo.recycleTime = null;
    }

    if (existingVideo.parentId != null &&
        _collections.containsKey(existingVideo.parentId)) {
      _collections[existingVideo.parentId]!.childrenIds.remove(existingId);
    } else if (existingVideo.parentId == null) {
      _rootChildrenIds.remove(existingId);
    }

    existingVideo.parentId = parentId;
    if (parentId != null && _collections.containsKey(parentId)) {
      if (!_collections[parentId]!.childrenIds.contains(existingId)) {
        _collections[parentId]!.childrenIds.add(existingId);
      }
    } else {
      if (!_rootChildrenIds.contains(existingId)) {
        _rootChildrenIds.add(existingId);
      }
    }

    if (persist && wasRecycled) {
      await _saveLibrary();
    }
    if (notify) {
      notifyListeners();
    }
    return true;
  }

  // Import Progress
  final ValueNotifier<bool> isImporting = ValueNotifier(false);
  final ValueNotifier<double> importProgress = ValueNotifier(0.0);
  final ValueNotifier<String> importStatus = ValueNotifier("");
  bool _importOperationActive = false;
  bool get hasActiveImport => _importOperationActive;

  @visibleForTesting
  set importOperationActiveForTesting(bool value) {
    _importOperationActive = value;
  }

  /// Overlay-only progress (e.g. clipboard Bilibili cards) that must not
  /// toggle [isImporting], which would grow the collection title.
  bool _transientImportProgressActive = false;

  bool _initialized = false;
  Future<void>? _libraryInitialization;
  bool _deferredMaintenancePending = false;
  final List<VideoItem> _startupTransientCleanup = [];
  UiIdleGate? _maintenanceIdle;

  bool get isInitialized => _initialized;

  /// Durable evidence of an existing library. Recycled items still count so
  /// first-open warmup or a late JSON read is never treated as a new install.
  bool get hasExistingLibraryContent =>
      _videos.values.any((item) => !item.isTransient) ||
      _collections.isNotEmpty;

  /// Nearest living (not recycled) ancestor, or null for the root grid.
  String? resolveLivingFolderId(String? folderId) {
    return MediaLibraryNavigation.resolveLivingFolderId(
      requestedId: folderId,
      isActiveFolder: (id) {
        final collection = _collections[id];
        return collection != null && !collection.isRecycled;
      },
      parentIdOf: (id) => _collections[id]?.parentId,
    );
  }

  late Directory _dataRootDir;
  bool _isDurationBackfillRunning = false;
  bool _hasScheduledDurationBackfill = false;
  bool _isChapterBackfillRunning = false;
  bool _hasScheduledChapterBackfill = false;
  bool _isAudioCoverBackfillRunning = false;
  bool _hasScheduledAudioCoverBackfill = false;

  /// Original path of an audio file that was copied during import, so cover.jpg
  /// can still be found beside the source after the library copy is made.
  final Map<String, String> _audioSidecarHints = <String, String>{};

  /// 当前 library.json 的 schema 版本。
  /// 版本 0 = 旧版（无 schemaVersion 字段），需要执行比例迁移。
  /// 版本 1 = 已执行竖屏比例 1:1 修复迁移。
  /// 版本 2 = 应用管理的字幕按 VideoItem.id 隔离到任务目录。
  static const int _currentLibrarySchemaVersion = 2;
  bool _needsPostLoadSave = false;

  static const List<Duration> _saveRetryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 10),
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 5),
  ];
  LibraryPersistenceStatus _persistenceStatus =
      LibraryPersistenceStatus.healthy;
  Object? _lastPersistenceError;
  DateTime? _lastPersistenceFailureAt;
  int _consecutivePersistenceFailures = 0;
  int _persistenceFailureEpisode = 0;
  Timer? _saveRetryTimer;

  @visibleForTesting
  Future<void> Function()? writeLibrarySnapshotOverrideForTesting;
  @visibleForTesting
  List<Duration>? saveRetryDelaysForTesting;
  @visibleForTesting
  int Function(String path)? probeMediaDurationOverrideForTesting;
  @visibleForTesting
  bool skipImportSidecarWorkForTesting = false;
  @visibleForTesting
  int? structuredImportFailAfterCountForTesting;

  /// Makes [addSingleVideo] fail right after the card was put into the
  /// library maps, before anything is saved.
  @visibleForTesting
  bool failAddSingleVideoAfterInsertForTesting = false;

  LibraryPersistenceStatus get persistenceStatus => _persistenceStatus;
  bool get hasPersistenceFailure =>
      _persistenceStatus != LibraryPersistenceStatus.healthy;
  Object? get lastPersistenceError => _lastPersistenceError;
  DateTime? get lastPersistenceFailureAt => _lastPersistenceFailureAt;
  int get consecutivePersistenceFailures => _consecutivePersistenceFailures;

  /// Increases only when a new failure period begins. The UI uses this to
  /// present at most one dismissible notice per period, even if retries fail.
  int get persistenceFailureEpisode => _persistenceFailureEpisode;

  bool _storageMaintenance = false;
  bool _storageSealed = false;
  Future<void> prepareStorageMigration() async {
    if (hasActiveImport) throw StateError('请等待导入完成后再迁移目录');
    _storageMaintenance = true;
    while (_isDurationBackfillRunning ||
        _isChapterBackfillRunning ||
        _isAudioCoverBackfillRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await saveProgress();
    await _transientLedgerWrite;
    _storageSealed = true;
  }

  // Initialize and load data
  Future<void> init({bool deferMaintenance = false}) => _initialized
      ? Future.value()
      : _libraryInitialization ??=
            _initializeLibrary(deferMaintenance: deferMaintenance).catchError((
              Object error,
              StackTrace stack,
            ) {
              _libraryInitialization = null;
              Error.throwWithStackTrace(error, stack);
            });

  Future<void> _initializeLibrary({required bool deferMaintenance}) async {
    if (_initialized) return;
    _dataRootDir = await SettingsService().resolveLargeDataRootDir();
    await _loadLibrary();
    if (!deferMaintenance) {
      await _cleanupIncompleteArchiveImports();
      unawaited(_cleanupOrphanedArchiveSelectionCaches());
    }

    // 如果数据迁移修改了数据，立即保存
    if (_needsPostLoadSave) {
      _needsPostLoadSave = false;
      await _saveLibrary();
    }

    _initialized = true;
    // File clean-up only touches paths inside the data root once the service
    // counts as initialized, so leftovers are purged after the flag is set.
    await _purgeTransientLeftovers(deferDeletion: deferMaintenance);
    notifyListeners();
    _deferredMaintenancePending = deferMaintenance;
    if (!deferMaintenance) _startMetadataBackfill();
  }

  void _startMetadataBackfill() {
    _scheduleDurationBackfill();
    _scheduleChapterBackfill();
    _scheduleAudioCoverBackfill();
  }

  /// Called after the real home frame; task/queue recovery is independent.
  void startDeferredMaintenance() {
    if (!_deferredMaintenancePending || !_initialized) return;
    _deferredMaintenancePending = false;
    final idle = _maintenanceIdle ??= UiIdleGate();
    unawaited(() async {
      try {
        if (!await idle.waitUntilIdle() || _storageMaintenance) return;
        final hadTransientCleanup = _startupTransientCleanup.isNotEmpty;
        for (final item in _startupTransientCleanup.toList()) {
          if (!await idle.waitUntilIdle() || _storageMaintenance) return;
          if (!_videos.containsKey(item.id)) await _deleteVideoFiles(item);
          _startupTransientCleanup.remove(item);
        }
        if (hadTransientCleanup) await _writeTransientLedger();
        if (!hasActiveImport) await _cleanupIncompleteArchiveImports();
        if (!await idle.waitUntilIdle() || _storageMaintenance) return;
        if (!hasActiveImport) await _cleanupOrphanedArchiveSelectionCaches();
        _startMetadataBackfill();
      } catch (error) {
        developer.log('Deferred library maintenance postponed', error: error);
      }
    }());
  }

  /// Clears generated card thumbnails in the library thumbnail folder.
  ///
  /// Unified artwork blobs and user-selected covers are left in place; those
  /// are cleaned from the storage page after their owners are known.
  Future<void> clearThumbnailDiskCache() async {
    if (!_initialized) return;
    try {
      final thumbnailDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (await thumbnailDir.exists()) {
        await thumbnailDir.delete(recursive: true);
      }
    } catch (e) {
      debugPrint('清理缩略图磁盘缓存失败: $e');
    }
  }

  Future<String?> ensureThumbnailForVideo(String videoId) async {
    final item = _videos[videoId];
    if (item == null) return null;
    if (!communityMediaIsLocal(item.path)) return null;
    if (item.type == MediaType.audio) {
      return _resolveImportedAudioCover(item, persist: true);
    }
    if (item.type != MediaType.video) {
      return null;
    }

    final inFlight = _thumbnailRepairInFlight[videoId];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _ensureThumbnailForVideoInternal(item);
    _thumbnailRepairInFlight[videoId] = future;
    try {
      return await future;
    } finally {
      if (identical(_thumbnailRepairInFlight[videoId], future)) {
        _thumbnailRepairInFlight.remove(videoId);
      }
    }
  }

  Future<String?> _ensureThumbnailForVideoInternal(VideoItem item) async {
    final existingPath = item.thumbnailPath;
    if (existingPath != null && existingPath.isNotEmpty) {
      final existingFile = File(existingPath);
      final requiresRepair = _requiresWindowsThumbnailRepair(existingPath);
      if (await existingFile.exists() &&
          await existingFile.length() > 0 &&
          !requiresRepair) {
        return existingPath;
      }
    }

    final localPath = communityLocalMediaPath(item.path);
    final generatedPath = await _generateThumbnail(localPath, videoId: item.id);
    if (generatedPath == null || generatedPath.isEmpty) {
      return null;
    }

    if (!identical(_videos[item.id], item) ||
        !communityMediaIsLocal(item.path) ||
        communityLocalMediaPath(item.path) != localPath) {
      return null;
    }
    if (item.thumbnailPath != generatedPath) {
      if (_requiresWindowsThumbnailRepair(item.thumbnailPath)) {
        try {
          final previousFile = File(item.thumbnailPath!);
          if (await previousFile.exists()) {
            await previousFile.delete();
          }
        } catch (_) {}
      }
      item.thumbnailPath = generatedPath;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      await _saveLibrary();
      _notifyCardChanged(item.id);
    }

    return generatedPath;
  }

  /// Ensures an imported audio item has a persistent, portable playback file.
  /// The original path is retained for source identity and user-facing details.
  Future<String> ensureCompatiblePlaybackFile(VideoItem item) async {
    return _prepareCompatiblePlaybackFile(item, saveLibrary: true);
  }

  Future<String> _prepareCompatiblePlaybackFile(
    VideoItem item, {
    required bool saveLibrary,
  }) async {
    requireCommunityLocalMedia(item.path);
    if (item.type != MediaType.audio) return item.path;
    final playbackFile = await AudioPlaybackCompatibilityService.resolve(
      File(item.path),
      isAudio: true,
      existingPlaybackPath: item.playbackPath,
      persistentDirectory: Directory(
        p.join(_dataRootDir.path, 'compatible_audio'),
      ),
    );
    final resolvedPath = playbackFile.path;
    final newPlaybackPath = _samePath(resolvedPath, item.path)
        ? null
        : resolvedPath;
    if (item.playbackPath != newPlaybackPath) {
      item.playbackPath = newPlaybackPath;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      if (saveLibrary) {
        await _saveLibrary();
        notifyListeners();
      }
    }
    return resolvedPath;
  }

  void _scheduleDurationBackfill() {
    if (skipImportSidecarWorkForTesting) return;
    if (_hasScheduledDurationBackfill) return;
    _hasScheduledDurationBackfill = true;
    Future<void>(() async {
      await _backfillMissingDurations();
    });
  }

  Future<void> _backfillMissingDurations() async {
    if (_isDurationBackfillRunning || _storageMaintenance) return;
    _isDurationBackfillRunning = true;
    try {
      final pendingItems = _videos.values
          .where(
            (item) => item.durationMs <= 0 && communityMediaIsLocal(item.path),
          )
          .toList();
      if (pendingItems.isEmpty) {
        return;
      }

      bool changed = false;
      int notifyCounter = 0;
      final changedIds = <String>[];
      for (final item in pendingItems) {
        if (_storageMaintenance) break;
        if (_maintenanceIdle != null &&
            !await _maintenanceIdle!.waitUntilIdle()) {
          break;
        }
        final durationMs = await _probeMediaDurationMs(item.path);
        if (durationMs <= 0 || item.durationMs == durationMs) {
          continue;
        }
        item.durationMs = durationMs;
        item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
        changed = true;
        changedIds.add(item.id);
        notifyCounter++;
        if (notifyCounter >= 10) {
          notifyCounter = 0;
          _notifyCardsChanged(changedIds);
          changedIds.clear();
        }
      }

      if (changed) {
        await _saveLibrary();
        _notifyCardsChanged(changedIds);
        changedIds.clear();
      }
    } finally {
      _isDurationBackfillRunning = false;
    }
  }

  void _scheduleChapterBackfill() {
    if (_hasScheduledChapterBackfill) return;
    _hasScheduledChapterBackfill = true;
    Future<void>(() async {
      // Give startup rendering priority and avoid running a second ffprobe in
      // parallel with the legacy duration migration.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      while (_isDurationBackfillRunning) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _backfillUnprobedChapters();
    });
  }

  Future<void> _backfillUnprobedChapters() async {
    if (_isChapterBackfillRunning || _storageMaintenance) return;
    _isChapterBackfillRunning = true;
    try {
      final pendingItems = _videos.values
          .where((item) => !item.hasProbedChapters)
          .toList();
      if (pendingItems.isEmpty) return;

      var changed = false;
      var notifyCounter = 0;
      final changedIds = <String>[];
      for (final item in pendingItems) {
        if (_storageMaintenance) break;
        if (_maintenanceIdle != null &&
            !await _maintenanceIdle!.waitUntilIdle()) {
          break;
        }
        if (!await File(item.path).exists()) continue;
        item.chapters = await MediaChapterProbe.probe(
          item.path,
          durationMs: item.durationMs,
        );
        item.hasProbedChapters = true;
        item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
        changed = true;
        changedIds.add(item.id);
        notifyCounter++;
        if (notifyCounter >= 4) {
          notifyCounter = 0;
          await _saveLibrary();
          _notifyCardsChanged(changedIds);
          changedIds.clear();
        }
        // Chapter migration is deliberately progressive so a large library
        // cannot monopolize ffprobe or the UI isolate at startup.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      if (changed) {
        await _saveLibrary();
        _notifyCardsChanged(changedIds);
        changedIds.clear();
      }
    } finally {
      _isChapterBackfillRunning = false;
    }
  }

  /// Fills covers for audio imported before cover extraction included album art.
  void _scheduleAudioCoverBackfill() {
    if (skipImportSidecarWorkForTesting) return;
    if (_hasScheduledAudioCoverBackfill) return;
    _hasScheduledAudioCoverBackfill = true;
    Future<void>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _backfillAudioCovers();
    });
  }

  Future<void> _backfillAudioCovers() async {
    if (_isAudioCoverBackfillRunning || _storageMaintenance) return;
    _isAudioCoverBackfillRunning = true;
    try {
      final pendingItems = _videos.values
          .where(
            (item) =>
                item.type == MediaType.audio &&
                !item.isTransient &&
                !item.isRecycled &&
                !item.hasProbedAudioCover &&
                (item.thumbnailPath == null || item.thumbnailPath!.isEmpty),
          )
          .toList();
      if (pendingItems.isEmpty) return;

      var changed = false;
      var notifyCounter = 0;
      final changedIds = <String>[];
      for (final item in pendingItems) {
        if (_storageMaintenance) break;
        if (_maintenanceIdle != null &&
            !await _maintenanceIdle!.waitUntilIdle()) {
          break;
        }
        await _resolveImportedAudioCover(item, persist: false);
        changed = true;
        changedIds.add(item.id);
        notifyCounter++;
        if (notifyCounter >= 4) {
          notifyCounter = 0;
          await _saveLibrary();
          _notifyCardsChanged(changedIds);
          changedIds.clear();
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (changed) {
        await _saveLibrary();
        _notifyCardsChanged(changedIds);
      }
    } finally {
      _isAudioCoverBackfillRunning = false;
    }
  }

  /// Reads an audio item's cover and remembers that the attempt happened.
  Future<String?> _resolveImportedAudioCover(
    VideoItem item, {
    String? sidecarHintPath,
    bool persist = false,
    bool allowFfmpegFallback = true,
  }) async {
    if (!communityMediaIsLocal(item.path)) return null;
    if (item.type != MediaType.audio) return item.thumbnailPath;
    final inFlight = _thumbnailRepairInFlight[item.id];
    if (inFlight != null) return inFlight;

    final future = _resolveImportedAudioCoverBody(
      item,
      sidecarHintPath: sidecarHintPath,
      persist: persist,
      allowFfmpegFallback: allowFfmpegFallback,
    );
    _thumbnailRepairInFlight[item.id] = future;
    try {
      return await future;
    } finally {
      if (identical(_thumbnailRepairInFlight[item.id], future)) {
        _thumbnailRepairInFlight.remove(item.id);
      }
    }
  }

  Future<String?> _resolveImportedAudioCoverBody(
    VideoItem item, {
    String? sidecarHintPath,
    required bool persist,
    required bool allowFfmpegFallback,
  }) async {
    final current = _videos[item.id] ?? item;
    if (await _isDisplayableImageFile(current.thumbnailPath)) {
      current.hasProbedAudioCover = true;
      return current.thumbnailPath;
    }
    if (current.hasProbedAudioCover &&
        (current.thumbnailPath == null || current.thumbnailPath!.isEmpty)) {
      return null;
    }

    final cover = await _extractAudioCoverArt(
      current.path,
      videoId: current.id,
      sidecarHintPath: sidecarHintPath,
      allowFfmpegFallback: allowFfmpegFallback,
    );
    final latest = _videos[item.id] ?? item;
    if (!_samePath(latest.path, current.path)) return latest.thumbnailPath;
    latest.thumbnailPath = cover;
    latest.hasProbedAudioCover = true;
    if (cover != null) {
      latest.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    }
    if (persist) {
      await _saveLibrary();
      _notifyCardChanged(item.id);
    }
    return cover;
  }

  Future<bool> _isDisplayableImageFile(String? path) async {
    if (path == null || path.isEmpty) return false;
    final file = File(path);
    if (!await file.exists()) return false;
    try {
      final length = await file.length();
      if (length < 4 || length > AudioCoverArt.maxImageBytes) return false;
      final raf = await file.open();
      try {
        final header = await raf.read(16);
        return AudioCoverArt.looksLikeImage(header);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> migrateLargeDataRoot(String newPath) async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      return false;
    }
    await saveProgress();
    final old = _dataRootDir;
    await StorageMigrationCoordinator(
      AppStorageService.instance,
    ).migrate(Directory(newPath));
    _updatePathsAfterRootChange(old.path, newPath);
    _dataRootDir = Directory(newPath);
    await SettingsService().setLargeDataRootPath(newPath);
    return true;
  }

  void _updatePathsAfterRootChange(String oldRoot, String newRoot) {
    for (final col in _collections.values) {
      if (col.thumbnailPath != null) {
        col.thumbnailPath = _replaceRootPath(
          col.thumbnailPath!,
          oldRoot,
          newRoot,
        );
      }
    }

    for (final vid in _videos.values) {
      vid.path = _replaceRootPath(vid.path, oldRoot, newRoot);
      if (vid.bilibiliDownloadPath != null) {
        vid.bilibiliDownloadPath = _replaceRootPath(
          vid.bilibiliDownloadPath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.playbackPath != null) {
        vid.playbackPath = _replaceRootPath(
          vid.playbackPath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.thumbnailPath != null) {
        vid.thumbnailPath = _replaceRootPath(
          vid.thumbnailPath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.subtitlePath != null) {
        vid.subtitlePath = _replaceRootPath(
          vid.subtitlePath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.secondarySubtitlePath != null) {
        vid.secondarySubtitlePath = _replaceRootPath(
          vid.secondarySubtitlePath!,
          oldRoot,
          newRoot,
        );
      }
      if (vid.danmakuPath != null) {
        vid.danmakuPath = _replaceRootPath(vid.danmakuPath!, oldRoot, newRoot);
      }
      if (vid.bilibiliVideoShot != null) {
        vid.bilibiliVideoShot = vid.bilibiliVideoShot!.replaceRoot(
          oldRoot,
          newRoot,
        );
      }
      if (vid.additionalSubtitles != null) {
        vid.additionalSubtitles = vid.additionalSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
      if (vid.localSubtitles != null) {
        vid.localSubtitles = vid.localSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
      vid.managedSubtitleAssets = vid.managedSubtitleAssets
          .map(
            (asset) => asset.copyWith(
              path: _replaceRootPath(asset.path, oldRoot, newRoot),
              wordTimingPath: asset.wordTimingPath == null
                  ? null
                  : _replaceRootPath(asset.wordTimingPath!, oldRoot, newRoot),
            ),
          )
          .toList(growable: false);
      if (vid.recycledSelectedSubtitlePaths != null) {
        vid.recycledSelectedSubtitlePaths = vid.recycledSelectedSubtitlePaths!
            .map((e) => _replaceRootPath(e, oldRoot, newRoot))
            .toList();
      }
      if (vid.recycledAdditionalSubtitles != null) {
        vid.recycledAdditionalSubtitles = vid.recycledAdditionalSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
      if (vid.recycledLocalSubtitles != null) {
        vid.recycledLocalSubtitles = vid.recycledLocalSubtitles!.map(
          (key, value) =>
              MapEntry(key, _replaceRootPath(value, oldRoot, newRoot)),
        );
      }
    }
  }

  String _replaceRootPath(String path, String oldRoot, String newRoot) {
    final normOld = p.normalize(oldRoot);
    final normPath = p.normalize(path);
    if (p.equals(normOld, normPath) || p.isWithin(normOld, normPath)) {
      final rel = p.relative(normPath, from: normOld);
      return p.join(newRoot, rel);
    }
    return path;
  }

  Future<void> _loadLibrary() async {
    final file = File(p.join(_dataRootDir.path, 'library.json'));
    final backupFile = File(p.join(_dataRootDir.path, 'library.json.bak'));

    if (!await file.exists()) {
      // Try backup if main file missing
      if (await backupFile.exists()) {
        try {
          await _parseLibraryFile(backupFile);
          // Restore main file from backup
          await backupFile.copy(file.path);
        } catch (e) {
          developer.log('Error loading backup library', error: e);
          throw const StorageUnavailableException('媒体库和备份无法读取，已保留原记录');
        }
      }
      return;
    }

    try {
      await _parseLibraryFile(file);
    } catch (e) {
      developer.log('Error loading library', error: e);
      if (e is StorageUnavailableException) rethrow;
      // Try backup
      if (!await backupFile.exists()) {
        throw const StorageUnavailableException('媒体库无法读取，已保留原记录');
      }
      if (await backupFile.exists()) {
        developer.log('Attempting to load from backup...');
        try {
          await _parseLibraryFile(backupFile);
          // We don't overwrite the corrupt main file immediately to allow manual inspection if needed,
          // but the next save will overwrite it.
        } catch (e2) {
          developer.log('Error loading backup library', error: e2);
          throw const StorageUnavailableException('媒体库和备份无法读取，已暂停写入');
        }
      }
    }
  }

  Future<void> _parseLibraryFile(File file) async {
    final snapshot = await readLibrarySnapshot(
      file.path,
      pathEncoding: AppStorageService.instance.capturePathEncoding(),
      maximumSchemaVersion: _currentLibrarySchemaVersion,
    );

    // Load Collections
    if (snapshot.collections != null) {
      _collections = snapshot.collections!;
    }

    // Load Videos
    if (snapshot.videos != null) {
      _videos = snapshot.videos!;
      for (final item in _videos.values) {
        if (_restoreCompletedLocalDownload(item)) _needsPostLoadSave = true;
      }
      _cloudDriveCardsIndex = null;
    }

    // Load Root Children IDs
    if (snapshot.rootChildrenIds != null) {
      _rootChildrenIds = snapshot.rootChildrenIds!;
    } else {
      // Migration: Populate rootChildrenIds if missing
      final rootCols = _collections.values
          .where((c) => c.parentId == null)
          .map((c) => c.id);
      final rootVids = _videos.values
          .where((v) => v.parentId == null)
          .map((v) => v.id);
      _rootChildrenIds = [...rootCols, ...rootVids];

      // Sort by createTime/lastUpdated as a default
      _rootChildrenIds.sort((a, b) {
        int timeA = _collections.containsKey(a)
            ? _collections[a]!.createTime
            : (_videos[a]?.lastUpdated ?? 0);
        int timeB = _collections.containsKey(b)
            ? _collections[b]!.createTime
            : (_videos[b]?.lastUpdated ?? 0);
        return timeB.compareTo(timeA);
      });
    }

    final activityResult = snapshot.activity;
    _activityUnknownFuture = activityResult.unsupportedFutureVersion;
    _preservedActivityRaw = activityResult.preservedRaw;
    _activity = activityResult.store;
    _openImportBatches.clear();

    // Default Folder Creation: If library is completely empty
    if (_collections.isEmpty && _videos.isEmpty) {
      await createCollection("默认收藏夹", null);
    }

    // Migration: Handle Legacy Recycle Bin
    if (snapshot.recycleBin != null) {
      for (var c in snapshot.recycleBin!) {
        c.isRecycled = true;
        c.recycleTime = DateTime.now().millisecondsSinceEpoch;
        _collections[c.id] = c;
      }
    }

    // Migration: Fix parentId for children
    for (var col in _collections.values) {
      for (var childId in col.childrenIds) {
        if (_collections.containsKey(childId)) {
          _collections[childId]!.parentId = col.id;
        } else if (_videos.containsKey(childId)) {
          _videos[childId]!.parentId = col.id;
        }
      }
    }

    // Schema migration
    final savedSchemaVersion = snapshot.schemaVersion;
    if (savedSchemaVersion < _currentLibrarySchemaVersion) {
      await _migratePortraitAspectRatioIfNeeded(savedSchemaVersion);
      await _migrateTaskSubtitleAssetsIfNeeded(savedSchemaVersion);
    }
  }

  /// 数据迁移：修复旧版代码为竖屏视频错误设置的 1:1 比例。
  ///
  /// 旧版 `_applyInitialPortraitDefaultAspectRatioIfNeeded` 对竖屏视频设置了
  /// portraitDisplayAspectRatio = 1.0，并标记 hasPortraitAspectPreferenceInitialized = true。
  /// 当前版本已改为设置 4/3，但旧数据中的 1.0 值因 initialized 标志无法被纠正。
  ///
  /// 此迁移将受影响视频的比例重置为 null、initialized 标志重置为 false，
  /// 使下次打开视频时由当前代码重新评估。
  Future<void> _migratePortraitAspectRatioIfNeeded(int savedVersion) async {
    if (savedVersion >= 1) return;

    bool changed = false;
    for (final item in _videos.values) {
      if (item.type != MediaType.video) continue;

      final ratio = item.portraitDisplayAspectRatio;
      if (ratio == null) continue;
      if ((ratio - 1.0).abs() >= 0.01) continue;
      // 跳过用户通过自定义宽高设置的 1:1（保留用户意图）
      if (item.portraitCustomAspectWidth != null ||
          item.portraitCustomAspectHeight != null) {
        continue;
      }

      item.portraitDisplayAspectRatio = null;
      item.hasPortraitAspectPreferenceInitialized = false;
      changed = true;
    }

    if (changed) {
      _needsPostLoadSave = true;
    }
  }

  // Debounce non-critical saves, while serializing every actual disk write.
  // Each caller receives the Future for its own queued write, so awaiting a
  // save never returns merely because another save is already in progress.
  bool _hasPendingSave = false;
  Timer? _saveDebounceTimer;
  final SerialTaskQueue _saveQueue = SerialTaskQueue();
  final SerialTaskQueue _postImportQueue = SerialTaskQueue();
  static const Duration _saveDebounceDelay = Duration(seconds: 20);

  /// Schedule a debounced save for non-critical updates (e.g. progress).
  /// Multiple calls within the debounce window are coalesced into one save.
  void _scheduleDebouncedSave() {
    _hasPendingSave = true;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = Timer(_saveDebounceDelay, () {
      _saveDebounceTimer = null;
      if (_hasPendingSave) {
        unawaited(
          _saveLibrary().catchError((Object error, StackTrace stackTrace) {
            developer.log(
              'Error saving debounced library update',
              error: error,
              stackTrace: stackTrace,
            );
          }),
        );
      }
    });
  }

  Future<void> _saveLibrary() {
    if (_storageSealed) return Future<void>.value();
    _cloudDriveCardsIndex = null;
    _storageFileOwnersIndex = null;
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _hasPendingSave = false;
    _saveRetryTimer?.cancel();
    _saveRetryTimer = null;

    return _saveQueue.enqueue(_writeLibrarySnapshot);
  }

  /// Lets the user request an immediate retry without exposing storage errors
  /// to every existing library mutation call site.
  Future<void> retryLibraryPersistence() {
    if (!hasPersistenceFailure) return Future<void>.value();
    return _saveLibrary();
  }

  @visibleForTesting
  Future<void> saveLibraryForTesting() => _saveLibrary();

  @visibleForTesting
  void resetPersistenceForTesting() {
    _saveDebounceTimer?.cancel();
    _saveDebounceTimer = null;
    _saveRetryTimer?.cancel();
    _saveRetryTimer = null;
    _hasPendingSave = false;
    _persistenceStatus = LibraryPersistenceStatus.healthy;
    _lastPersistenceError = null;
    _lastPersistenceFailureAt = null;
    _consecutivePersistenceFailures = 0;
    _persistenceFailureEpisode = 0;
    writeLibrarySnapshotOverrideForTesting = null;
    deleteVideoFilesOverrideForTesting = null;
    beforeOwnedFileDeletionForTesting = null;
    saveRetryDelaysForTesting = null;
    probeMediaDurationOverrideForTesting = null;
    skipImportSidecarWorkForTesting = false;
    structuredImportFailAfterCountForTesting = null;
    failAddSingleVideoAfterInsertForTesting = false;
  }

  @visibleForTesting
  void resetLibraryForTesting() {
    _downloadImportInflight.clear();
    _downloadFolderInflight.clear();
    _maintenanceIdle?.dispose();
    _maintenanceIdle = null;
    _libraryInitialization = null;
    _deferredMaintenancePending = false;
    _startupTransientCleanup.clear();
    _browseContents.clear();
    _cardRevisions.clear();
    _bilibiliCacheCandidates = null;
    _browseRevision++;
    _cloudDriveCardsIndex = null;
    resetPersistenceForTesting();
    _storageMaintenance = false;
    _storageSealed = false;
    _initialized = false;
    _needsPostLoadSave = false;
    _collections = {};
    _videos = {};
    _rootChildrenIds = [];
    _launchRetainedTransientIds.clear();
    _progressObservers.clear();
    _renameObservers.clear();
    _transientLedgerWrite = Future<void>.value();
    _activity = LibraryActivityStore.empty();
    _openImportBatches.clear();
    _activityUnknownFuture = false;
    _preservedActivityRaw = null;
    activityRevision.value = 0;
    _audioSidecarHints.clear();
    _hasScheduledAudioCoverBackfill = false;
    _isAudioCoverBackfillRunning = false;
  }

  @visibleForTesting
  void seedVideoForTesting(VideoItem item) {
    _restoreCompletedLocalDownload(item);
    _bilibiliCacheCandidates = null;
    _cloudDriveCardsIndex = null;
    _videos[item.id] = item;
  }

  @visibleForTesting
  void seedCollectionForTesting(VideoCollection collection) {
    _collections[collection.id] = collection;
  }

  @visibleForTesting
  void seedMediaActivityForTesting(MediaActivityRecord record) {
    _activity.media[record.mediaId] = record;
  }

  @visibleForTesting
  void seedPinnedIdsForTesting(List<String> ids) {
    _activity.pinnedIds
      ..clear()
      ..addAll(ids);
  }

  Future<void> _writeLibrarySnapshot() async {
    try {
      final override = writeLibrarySnapshotOverrideForTesting;
      if (override != null) {
        await override();
      } else {
        await _performLibrarySnapshotWrite();
      }
      _recordPersistenceSuccess();
    } catch (error, stackTrace) {
      developer.log(
        'Error saving library',
        error: error,
        stackTrace: stackTrace,
      );
      _recordPersistenceFailure(error);
    }
  }

  Future<void> _performLibrarySnapshotWrite() async {
    await writeLibrarySnapshot(
      LibrarySnapshot(
        directory: _dataRootDir.path,
        schemaVersion: _currentLibrarySchemaVersion,
        collections: _collections.values.toList(growable: false),
        videos: _videos.values.toList(growable: false),
        rootChildrenIds: _rootChildrenIds,
        activity: _activity,
        preservedActivity: _activityUnknownFuture
            ? _preservedActivityRaw
            : null,
        pathEncoding: AppStorageService.instance.capturePathEncoding(),
      ),
    );
    await AppStorageService.instance.noteLibraryPersisted();
  }

  void _recordPersistenceFailure(Object error) {
    final startsNewEpisode = !hasPersistenceFailure;
    _persistenceStatus = LibraryPersistenceStatus.retryScheduled;
    _lastPersistenceError = error;
    _lastPersistenceFailureAt = DateTime.now();
    _consecutivePersistenceFailures++;
    if (startsNewEpisode) {
      _persistenceFailureEpisode++;
    }
    _schedulePersistenceRetry();
    notifyListeners();
  }

  void _recordPersistenceSuccess() {
    if (!hasPersistenceFailure) return;
    _saveRetryTimer?.cancel();
    _saveRetryTimer = null;
    _persistenceStatus = LibraryPersistenceStatus.healthy;
    _lastPersistenceError = null;
    _lastPersistenceFailureAt = null;
    _consecutivePersistenceFailures = 0;
    notifyListeners();
  }

  void _schedulePersistenceRetry() {
    _saveRetryTimer?.cancel();
    final delays = saveRetryDelaysForTesting ?? _saveRetryDelays;
    if (delays.isEmpty) return;
    final delayIndex = min(
      _consecutivePersistenceFailures - 1,
      delays.length - 1,
    );
    _saveRetryTimer = Timer(delays[delayIndex], () {
      _saveRetryTimer = null;
      unawaited(_saveLibrary());
    });
  }

  // Get contents for a specific folder (null for root)
  List<dynamic> getContents(String? parentId) {
    List<dynamic> results = [];

    List<String> sourceIds;
    if (parentId == null) {
      sourceIds = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return [];
      sourceIds = parent.childrenIds;
    }

    for (var id in sourceIds) {
      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        if (!col.isRecycled &&
            !col.isHiddenFromFolders &&
            _isCommunityLocalCollection(col)) {
          results.add(col);
        }
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        if (!vid.isRecycled && _isCommunityLocalVideo(vid)) results.add(vid);
      }
    }

    return results;
  }

  /// Read-only DFS of descendant media. Does not change childrenIds.
  List<VideoItem> mediaInFolderTree(String folderId) {
    return MediaLibraryFolderWalk.collectMedia(
      rootId: folderId,
      folderOf: getCollection,
      videoOf: _libraryVideo,
    );
  }

  String relativeFolderPath(String rootFolderId, String? mediaParentId) {
    return MediaLibraryFolderWalk.relativePath(
      rootId: rootFolderId,
      parentId: mediaParentId,
      folderOf: getCollection,
    );
  }

  /// Returns a virtual, read-only view of every active folder and media item
  /// whose display text matches [query]. The returned objects are the original
  /// library objects, so actions performed from a search result still mutate
  /// the real item instead of a copy.
  List<dynamic> searchContents(String query) {
    final searchQuery = MediaLibrarySearchQuery(query);
    if (searchQuery.isEmpty) return const <dynamic>[];

    bool hasRecycledAncestor(String? parentId) {
      final visited = <String>{};
      var currentId = parentId;
      while (currentId != null && visited.add(currentId)) {
        final parent = _collections[currentId];
        if (parent == null) return false;
        if (parent.isRecycled) return true;
        currentId = parent.parentId;
      }
      return false;
    }

    String displayText(dynamic item) =>
        item is VideoCollection ? item.name : (item as VideoItem).title;

    // Match every card independently. A matching folder contributes only its
    // own card; its children must match their own rendered titles to appear.
    final results = <dynamic>[
      ..._collections.values.where(
        (collection) =>
            !collection.isRecycled &&
            !collection.isHiddenFromFolders &&
            _isCommunityLocalCollection(collection) &&
            !hasRecycledAncestor(collection.parentId) &&
            searchQuery.matchesTitle(collection.name),
      ),
      ..._videos.values.where((video) {
        if (!_isCommunityLocalVideo(video) ||
            video.isRecycled ||
            hasRecycledAncestor(video.parentId)) {
          return false;
        }
        return searchQuery.matchesTitle(video.title);
      }),
    ];

    // Keep folders together, then prefer exact/prefix matches and newer items.
    // This ordering exists only in the virtual result view and is never saved.
    results.sort((left, right) {
      final leftIsFolder = left is VideoCollection;
      final rightIsFolder = right is VideoCollection;
      if (leftIsFolder != rightIsFolder) return leftIsFolder ? -1 : 1;

      final rankComparison = searchQuery
          .rankTitle(displayText(left))
          .compareTo(searchQuery.rankTitle(displayText(right)));
      if (rankComparison != 0) return rankComparison;

      final leftTime = left is VideoCollection
          ? left.createTime
          : (left as VideoItem).lastUpdated;
      final rightTime = right is VideoCollection
          ? right.createTime
          : (right as VideoItem).lastUpdated;
      final timeComparison = rightTime.compareTo(leftTime);
      if (timeComparison != 0) return timeComparison;
      return displayText(left).compareTo(displayText(right));
    });

    return results;
  }

  /// Resolves the library folder that should receive a new import.
  ///
  /// [openedFromFolderId] is the folder that was open when the import started.
  /// Null means the media library root. Source-folder mode reuses one stable
  /// folder per feature and does not record that folder as part of the import.
  Future<String?> resolveImportCardParentId({
    required ImportCardFeature feature,
    required String? openedFromFolderId,
    ImportPlacementRequest? request,
    bool explicitPlacement = false,
  }) async {
    final target =
        request ??
        (explicitPlacement
            ? ImportPlacementRequest.explicit(feature, openedFromFolderId)
            : SettingsService().captureImportPlacement(
                feature,
                openedFromFolderId: openedFromFolderId,
              ));
    final inFlight = _importPlacementInflight[target];
    if (inFlight != null) return inFlight;
    final future = _resolveImportCardTarget(target, openedFromFolderId);
    _importPlacementInflight[target] = future;
    try {
      return await future;
    } finally {
      _importPlacementInflight.remove(target);
    }
  }

  final Map<ImportPlacementRequest, Future<String?>> _importPlacementInflight =
      {};

  Future<String?> _resolveImportCardTarget(
    ImportPlacementRequest target,
    String? openedFromFolderId,
  ) async {
    if (target.isResolved) {
      try {
        _validateImportFolder(target.folderId);
      } on ImportPlacementException {
        if (importPlacementPicker == null) rethrow;
        target.folderId = await _pickImportFolder(
          target.feature,
          target.folderId,
        );
        _validateImportFolder(target.folderId);
      }
      return target.folderId;
    }
    String? folderId;
    switch (target.placement) {
      case ImportCardPlacement.libraryRoot:
        break;
      case ImportCardPlacement.currentFolder:
      case ImportCardPlacement.fixedFolder:
        folderId = target.folderId;
        break;
      case ImportCardPlacement.sourceFolder:
        folderId = await _ensureImportSourceFolder(
          target.feature,
          storedId: target.folderId,
          folderName: target.sourceFolderName,
        );
        break;
      case ImportCardPlacement.askEveryTime:
        folderId = await _pickImportFolder(target.feature, openedFromFolderId);
        break;
    }
    _validateImportFolder(folderId);
    target.folderId = folderId;
    target.isResolved = true;
    return folderId;
  }

  Future<ImportPlacementRequest?> Function(ImportCardFeature, String?)?
  importPlacementPicker;
  Future<void> _importPlacementPromptTail = Future.value();

  Future<String?> _pickImportFolder(
    ImportCardFeature feature,
    String? initial,
  ) async {
    final previous = _importPlacementPromptTail;
    final done = Completer<void>();
    _importPlacementPromptTail = done.future;
    try {
      await previous;
      final picker = importPlacementPicker;
      if (picker == null) {
        throw const ImportPlacementException('请在应用中选择导入位置后重试');
      }
      final picked = await picker(feature, initial);
      if (picked == null) {
        throw const ImportPlacementException('已取消选择导入位置，媒体文件仍保留');
      }
      return picked.folderId;
    } finally {
      done.complete();
    }
  }

  void _validateImportFolder(String? id) {
    if (id == null) return;
    final folder = _collections[id];
    if (folder == null || isStorageItemRecycled(id) || folder.isPodcast) {
      throw const ImportPlacementException('导入目标文件夹已不可用，请重新选择导入位置；已下载的文件仍保留');
    }
  }

  Future<String> _ensureImportSourceFolder(
    ImportCardFeature feature, {
    String? storedId,
    String? folderName,
  }) async {
    final settings = SettingsService();
    final name = folderName ?? settings.importSourceFolderName(feature);
    final key = '${feature.group.name}:${storedId ?? ''}:$name';
    final inFlight = _importSourceFolderInflight[key];
    if (inFlight != null) {
      final id = await inFlight;
      await _rememberImportSourceFolderId(feature, id);
      return id;
    }
    final future = _ensureImportSourceFolderBody(
      feature,
      storedId: storedId,
      folderName: name,
    );
    _importSourceFolderInflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_importSourceFolderInflight[key], future)) {
        _importSourceFolderInflight.remove(key);
      }
    }
  }

  Future<String> _ensureImportSourceFolderBody(
    ImportCardFeature feature, {
    String? storedId,
    required String folderName,
  }) async {
    final id = storedId;
    if (id != null &&
        _collections.containsKey(id) &&
        !isStorageItemRecycled(id) &&
        !_collections[id]!.isPodcast) {
      return id;
    }
    final name = folderName;
    for (final id in _rootChildrenIds) {
      final collection = _collections[id];
      if (collection != null &&
          collection.name == name &&
          !collection.isRecycled &&
          !collection.isPodcast) {
        await _rememberImportSourceFolderId(feature, collection.id);
        return collection.id;
      }
    }
    final created = await createCollection(name, null);
    await _rememberImportSourceFolderId(feature, created.id);
    return created.id;
  }

  Future<void> _rememberImportSourceFolderId(
    ImportCardFeature feature,
    String id,
  ) async {
    final settings = SettingsService();
    if (settings.importSourceFolderId(feature) == id) return;
    final ids = Map<String, String>.from(settings.importSourceFolderIds);
    ids[feature.storageValue] = id;
    await settings.updateSetting(ImportSourceFolders.idsKey, jsonEncode(ids));
  }

  Future<VideoCollection> createCollection(
    String name,
    String? parentId, {
    String? id,
    String? thumbnailPath,
    String? coverLabel,
    String? bilibiliPendingCoverUrl,
    MediaSourceRef? sourceRef,
    PodcastChannelRef? podcastRef,
  }) async {
    if (parentId != null && _collections[parentId]?.isPodcast == true) {
      throw const FormatException('播客频道不能包含普通文件夹');
    }
    final collectionId = id ?? const Uuid().v4();
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(collectionId) ||
        _collections.containsKey(collectionId) ||
        _videos.containsKey(collectionId)) {
      throw const FormatException('文件夹标识已存在或无效');
    }
    final collection = VideoCollection(
      id: collectionId,
      name: name,
      createTime: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
      thumbnailPath: thumbnailPath,
      bilibiliPendingCoverUrl: bilibiliPendingCoverUrl,
      coverLabel: coverLabel,
      sourceRef: sourceRef,
      podcastRef: podcastRef,
    );

    _collections[collection.id] = collection;

    if (parentId != null && _collections.containsKey(parentId)) {
      _collections[parentId]!.childrenIds.add(collection.id);
    } else if (parentId == null) {
      _rootChildrenIds.add(collection.id);
    }

    await _saveLibrary();
    notifyListeners();
    return collection;
  }

  /// Podcast catalog lives in its own database. Only interacted episodes need
  /// a stable adapter in the library for playback, learning and progress.
  Future<VideoItem> upsertPodcastEpisode(
    VideoItem item, {
    bool persist = true,
  }) async {
    if (item.sourceRef?.kind != MediaSourceKind.podcastEpisode) {
      throw ArgumentError('不是播客节目');
    }
    final existing = _videos[item.id];
    if (existing != null) {
      existing.sourceRef = item.sourceRef;
      existing.type = item.type;
      existing.durationMs = item.durationMs > 0
          ? item.durationMs
          : existing.durationMs;
      existing.thumbnailPath = item.thumbnailPath ?? existing.thumbnailPath;
      existing.lastPositionMs = item.lastPositionMs;
      return existing;
    }
    _videos[item.id] = item;
    final parent = _collections[item.parentId];
    if (parent != null && !parent.childrenIds.contains(item.id)) {
      parent.childrenIds.add(item.id);
    }
    if (item.parentId == null && !_rootChildrenIds.contains(item.id)) {
      _rootChildrenIds.add(item.id);
    }
    if (persist) {
      await _saveLibrary();
      notifyListeners();
    }
    return item;
  }

  Future<void> persistPodcastAdapters() async {
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> setPodcastChannelRef(
    String collectionId,
    PodcastChannelRef ref,
  ) async {
    final collection = _collections[collectionId];
    if (collection == null) return;
    collection.podcastRef = ref;
    await _saveLibrary();
    notifyListeners();
  }

  /// Keeps the subscription, folder position and episode data intact.
  Future<void> setPodcastVisibleInFolders(
    String collectionId, {
    required bool visible,
  }) async {
    final collection = _collections[collectionId];
    if (collection == null ||
        !collection.isPodcast ||
        collection.isHiddenFromFolders == !visible) {
      return;
    }
    collection.isHiddenFromFolders = !visible;
    await _saveLibrary();
    notifyListeners();
  }

  /// Registers or refreshes a cloud card without copying a media file.
  ///
  /// An existing card keeps its folder and watch position. A failed playback
  /// can still leave the card so the same file can be retried.
  Future<VideoItem> upsertCloudDriveCard({
    required MediaSourceRef source,
    required String title,
    String? openedFromFolderId,
    String? libraryItemId,
    VideoItem? playbackItem,
    bool explicitPlacement = false,
    bool save = true,
    int durationMs = 0,
    bool persist = true,
    MediaType? mediaType,
    String? thumbnailRef,
  }) async {
    final cloud = source.cloudDrive;
    if (cloud == null) throw ArgumentError('不是网盘来源');
    if (explicitPlacement &&
        openedFromFolderId != null &&
        (_collections[openedFromFolderId] == null ||
            _collections[openedFromFolderId]!.isRecycled ||
            _collections[openedFromFolderId]!.isPodcast)) {
      throw StateError('导入目标文件夹不可用');
    }
    cloudDriveThumbnails?.remember(cloud, thumbnailRef);
    if (!persist && !explicitPlacement && libraryItemId == null) {
      final known = cloudDriveCardForSource(cloud.sourceKey);
      if (known != null) return known;
      return VideoItem(
        id: cloud.itemId,
        path: cloud.logicalUri,
        sourceRef: source,
        title: title.trim().isEmpty ? '未命名' : title.trim(),
        durationMs: durationMs < 0 ? 0 : durationMs,
        lastUpdated: 0,
        type: mediaType ?? _detectMediaType(title),
      );
    }

    final peers =
        _videos.values
            .where(
              (v) =>
                  !v.isRecycled &&
                  v.sourceRef?.cloudDrive?.sourceKey == cloud.sourceKey,
            )
            .toList()
          ..sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
    final existing = libraryItemId != null
        ? _videos[libraryItemId]
        : explicitPlacement
        ? peers.where((v) => v.parentId == openedFromFolderId).firstOrNull
        : _videos[cloud.itemId] ?? peers.firstOrNull;
    if (existing != null) {
      if (existing.sourceRef?.cloudDrive?.sourceKey != cloud.sourceKey) {
        throw StateError('网盘卡片与文件身份不一致');
      }
      if (existing.sourceRef?.cloudDrive?.revision != cloud.revision) {
        existing.thumbnailPath = null;
      }
      existing.sourceRef = source;
      existing.path = cloud.logicalUri;
      if (mediaType != null) existing.type = mediaType;
      if (durationMs > 0) existing.durationMs = durationMs;
      if (save && persist && !existing.isTransient) {
        await _saveLibrary();
        notifyListeners();
      }
      return existing;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id =
        libraryItemId ?? (explicitPlacement ? const Uuid().v4() : cloud.itemId);
    final item =
        playbackItem ??
        VideoItem(
          id: id,
          path: cloud.logicalUri,
          title: title.trim().isEmpty ? '未命名' : title.trim(),
          durationMs: durationMs < 0 ? 0 : durationMs,
          lastUpdated: now,
          sourceRef: source,
          type: mediaType ?? _detectMediaType(title),
        );
    if (item.id != id ||
        item.sourceRef?.cloudDrive?.sourceKey != cloud.sourceKey) {
      throw ArgumentError('网盘播放卡片身份不一致');
    }
    final previous = peers.firstOrNull;
    if (previous != null) {
      item.lastPositionMs = previous.lastPositionMs;
      if (item.durationMs == 0) item.durationMs = previous.durationMs;
      if (previous.sourceRef?.cloudDrive?.revision == cloud.revision) {
        _copyCloudSubtitleState(previous, item);
        item.thumbnailPath = previous.thumbnailPath;
      }
    }
    if (!persist) return item;
    final parentId = await resolveImportCardParentId(
      feature: ImportCardFeature.cloudDrive,
      openedFromFolderId: openedFromFolderId,
      explicitPlacement: explicitPlacement,
    );
    item.parentId = parentId;
    _videos[item.id] = item;
    _cloudDriveCardsIndex = null;
    if (parentId == null) {
      _rootChildrenIds.add(item.id);
    } else {
      _collections[parentId]!.childrenIds.add(item.id);
    }
    noteImportedMedia(item.id, addedAtMs: now);
    if (previous != null) _copyCloudActivity(previous.id, item.id);
    if (save) {
      await _saveLibrary();
      notifyListeners();
      unawaited(ensureThumbnailForVideo(item.id));
    }
    return item;
  }

  /// Different folder placements share playback state, never names or parents.
  List<VideoItem> _cloudPlaybackPeers(String id) {
    final key = _videos[id]?.sourceRef?.cloudDrive?.sourceKey;
    if (key == null) return const [];
    return _videos.values
        .where((v) => v.sourceRef?.cloudDrive?.sourceKey == key)
        .toList();
  }

  void _copyCloudActivity(String from, String to) {
    final source = _activity.media[from];
    if (source == null) return;
    final target = _activity.ensureMedia(to);
    target.lastPlayedAtMs = source.lastPlayedAtMs;
    target.accumulatedWatchMs = source.accumulatedWatchMs;
    target.continueEnrolled = source.continueEnrolled;
    target.completed = source.completed;
    target.hidden = source.hidden;
    target.sharedLastPlayedCardId =
        source.sharedLastPlayedCardId ??
        (source.lastPlayedAtMs != null || source.accumulatedWatchMs > 0
            ? from
            : null);
  }

  void _shareCloudActivity(String id, {bool played = false}) {
    final peers = _cloudPlaybackPeers(id);
    if (peers.isEmpty) return;
    if (played) _activity.ensureMedia(id).sharedLastPlayedCardId = id;
    for (final peer in peers) {
      if (peer.id != id) _copyCloudActivity(id, peer.id);
    }
  }

  void _copyCloudSubtitleState(VideoItem source, VideoItem target) {
    target.subtitlePath = source.subtitlePath;
    target.secondarySubtitlePath = source.secondarySubtitlePath;
    target.isSubtitleCached = source.isSubtitleCached;
    target.isSecondarySubtitleCached = source.isSecondarySubtitleCached;
    target.additionalSubtitles = source.additionalSubtitles == null
        ? null
        : Map.of(source.additionalSubtitles!);
    target.localSubtitles = source.localSubtitles == null
        ? null
        : Map.of(source.localSubtitles!);
    target.managedSubtitleAssets = List.of(source.managedSubtitleAssets);
    target.blockAutoAssociatedSubtitleSelection =
        source.blockAutoAssociatedSubtitleSelection;
    target.hasAttemptedAutoEmbeddedSubtitleLoad =
        source.hasAttemptedAutoEmbeddedSubtitleLoad;
  }

  void _shareCloudSubtitles(String id) {
    final source = _videos[id];
    if (source?.sourceRef?.cloudDrive == null) return;
    for (final peer in cardsOfSameCloudFile(id)) {
      if (peer.id == id) continue;
      _copyCloudSubtitleState(source!, peer);
      _invalidateVideoSizeCache(peer.id);
    }
  }

  Future<void> commitCloudDriveReferences() async {
    await _saveLibrary();
    notifyListeners();
    if (hasPersistenceFailure) throw StateError('网盘引用尚未保存，请重试');
  }

  Future<void> updateCollectionSourceRefIfMissing(
    String collectionId,
    MediaSourceRef? sourceRef,
  ) async {
    if (sourceRef == null || sourceRef.value.trim().isEmpty) {
      return;
    }
    final col = _collections[collectionId];
    if (col == null || col.sourceRef != null) {
      return;
    }
    col.sourceRef = sourceRef;
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> updateCollectionThumbnail(
    String collectionId,
    String? thumbnailPath,
  ) async {
    final col = _collections[collectionId];
    if (col == null) return;

    final previousPath = col.thumbnailPath;
    if (previousPath != null &&
        previousPath.isNotEmpty &&
        thumbnailPath != previousPath &&
        p.isWithin(_dataRootDir.path, previousPath)) {
      try {
        final file = File(previousPath);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting previous collection thumbnail', error: e);
      }
    }

    col.thumbnailPath = thumbnailPath;
    col.bilibiliPendingCoverUrl = null;
    ThumbnailCacheService().evictFromCache(collectionId);
    await _saveLibrary();
    notifyListeners();
  }

  Future<StructuredImportSelectionSummary> analyzeFolderSelection(
    String folderPath,
  ) async {
    final rootDir = Directory(folderPath);
    if (!await rootDir.exists()) {
      throw FileSystemException('目录不存在', folderPath);
    }

    // 将递归遍历移入独立 Isolate，避免大文件夹扫描阻塞 UI 线程。
    // 这是 Windows 端"导入文件夹时点击即闪退"的核心根因：
    // UI isolate 被阻塞后 Windows 判定应用无响应并强杀进程。
    final result =
        await compute(_analyzeFolderSelectionIsolate, (
          folderPath,
          SettingsService().localImportFilterMediaExtensions,
        )).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            throw TimeoutException('文件夹扫描超时（30秒），请检查目录是否过大或包含软链接环路');
          },
        );

    final name = p.basename(p.normalize(rootDir.path));
    return StructuredImportSelectionSummary(
      sourcePath: rootDir.path,
      sourceName: name,
      rootCollectionName: name,
      isArchive: false,
      folderCount: result['folderCount'] as int,
      mediaFileCount: result['mediaFileCount'] as int,
    );
  }

  StructuredImportSelectionSummary analyzeArchiveSelection(String archivePath) {
    if (!isSupportedArchivePath(archivePath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }
    return StructuredImportSelectionSummary(
      sourcePath: archivePath,
      sourceName: archiveDisplayName(archivePath),
      rootCollectionName: archiveRootCollectionName(archivePath),
      isArchive: true,
      folderCount: 0,
      mediaFileCount: 0,
      detailsDeferred: true,
    );
  }

  Future<StructuredImportExecutionResult> importFolderSelection(
    String folderPath,
    String? parentId, {
    required StructuredImportSortOptions sortOptions,
    ImportPlacementRequest? importPlacement,
    bool explicitPlacement = false,
  }) {
    final placement =
        importPlacement ??
        (explicitPlacement
            ? ImportPlacementRequest.explicit(
                ImportCardFeature.folder,
                parentId,
              )
            : SettingsService().captureImportPlacement(
                ImportCardFeature.folder,
                openedFromFolderId: parentId,
              ));
    // Snapshot once: changing the global switch affects the next import
    // immediately, while this folder import remains internally consistent.
    final copyImportedFilesToLibrary =
        SettingsService().copyImportedMediaToPrivateStorage;
    final filterMediaExtensions =
        SettingsService().localImportFilterMediaExtensions;
    return _runExclusiveImport(() async {
      final rootDir = Directory(folderPath);
      if (!await rootDir.exists()) {
        throw FileSystemException('目录不存在', folderPath);
      }
      final destinationParentId = await resolveImportCardParentId(
        feature: ImportCardFeature.folder,
        openedFromFolderId: parentId,
        request: placement,
      );
      final rootName = p.basename(p.normalize(rootDir.path));
      return _importDirectoryTreeIntoLibrary(
        sourceDir: rootDir,
        rootCollectionName: rootName,
        parentId: destinationParentId,
        sortOptions: sortOptions,
        importLabel: '文件夹',
        copyImportedFilesToLibrary: copyImportedFilesToLibrary,
        filterMediaExtensions: filterMediaExtensions,
        totalMediaEntriesHint: null,
        activitySourceKind: LibraryImportSourceKind.folder,
      );
    });
  }

  /// Imports a trusted, already validated portable-package directory.
  ///
  /// Unlike a normal folder import, package media is always moved into the
  /// app-managed library before the temporary extraction directory is removed.
  Future<StructuredImportExecutionResult> importPortablePackageDirectory(
    String folderPath, {
    required String rootCollectionName,
    required int mediaEntriesHint,
    required StructuredImportSortOptions sortOptions,
    String? openedFromFolderId,
    ImportPlacementRequest? importPlacement,
  }) {
    final placement =
        importPlacement ??
        SettingsService().captureImportPlacement(
          ImportCardFeature.fluentPack,
          openedFromFolderId: openedFromFolderId,
        );
    return _runExclusiveImport(() async {
      final rootDir = Directory(folderPath);
      if (!await rootDir.exists()) {
        throw FileSystemException('导入包临时目录不存在', folderPath);
      }
      final destinationParentId = await resolveImportCardParentId(
        feature: ImportCardFeature.fluentPack,
        openedFromFolderId: openedFromFolderId,
        request: placement,
      );
      isImporting.value = true;
      await _setImportProgress(progress: 0.34, status: '正在写入媒体库…');
      try {
        return await _importDirectoryTreeIntoLibrary(
          sourceDir: rootDir,
          rootCollectionName: rootCollectionName,
          parentId: destinationParentId,
          sortOptions: sortOptions,
          importLabel: '导出包',
          moveImportedFilesToLibrary: true,
          totalMediaEntriesHint: mediaEntriesHint > 0 ? mediaEntriesHint : null,
          deferPostProcessing: true,
          activitySourceKind: LibraryImportSourceKind.fluentPack,
        );
      } finally {
        isImporting.value = false;
        importProgress.value = 0.0;
        importStatus.value = '';
      }
    });
  }

  /// Restores portable, path-independent media metadata after package files
  /// have been moved into this device's private storage.
  Future<void> applyPortableMediaMetadata(
    Iterable<String> importedVideoIds,
    Iterable<Map<String, dynamic>> records,
  ) async {
    final byStem = <String, List<Map<String, dynamic>>>{};
    for (final record in records) {
      final stem = record['fileStem']?.toString().trim().toLowerCase() ?? '';
      if (stem.isNotEmpty) {
        byStem.putIfAbsent(stem, () => <Map<String, dynamic>>[]).add(record);
      }
    }

    var changed = false;
    for (final id in importedVideoIds) {
      final item = _videos[id];
      if (item == null) continue;
      final candidates = byStem[item.title.trim().toLowerCase()];
      if (candidates == null || candidates.isEmpty) continue;
      final record = candidates.removeAt(0);
      // Source-device activity (addedAt/pins/hidden/lastPlayed) must not land
      // here; only identity-independent playback fields are restored.
      item.title = record['title']?.toString() ?? item.title;
      item.lastPositionMs = (record['lastPositionMs'] as num?)?.toInt() ?? 0;
      item.showFloatingSubtitles =
          record['showFloatingSubtitles'] as bool? ??
          item.showFloatingSubtitles;
      item.portraitDisplayAspectRatio =
          (record['portraitDisplayAspectRatio'] as num?)?.toDouble();
      item.portraitCustomAspectWidth =
          (record['portraitCustomAspectWidth'] as num?)?.toDouble();
      item.portraitCustomAspectHeight =
          (record['portraitCustomAspectHeight'] as num?)?.toDouble();
      item.hasPortraitAspectPreferenceInitialized =
          record['hasPortraitAspectPreferenceInitialized'] as bool? ?? false;
      item.isVideoMirroredH = record['isVideoMirroredH'] as bool? ?? false;
      item.isVideoMirroredV = record['isVideoMirroredV'] as bool? ?? false;
      item.sourceRef = MediaSourceRef.fromJsonOrNull(record['sourceRef']);
      final rawChapters = record['chapters'];
      if (rawChapters is List) {
        item.chapters = MediaChapter.normalize(
          rawChapters.whereType<Map>().map(
            (chapter) =>
                MediaChapter.fromJson(Map<String, dynamic>.from(chapter)),
          ),
          durationMs: item.durationMs,
        );
        item.hasProbedChapters =
            record['hasProbedChapters'] as bool? ?? item.chapters.isNotEmpty;
      }
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      changed = true;
    }
    if (changed) {
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<T> _runExclusiveImport<T>(Future<T> Function() operation) async {
    if (_importOperationActive) {
      throw StateError('已有导入任务正在运行，请等待完成后再试');
    }
    _importOperationActive = true;
    _transientImportProgressActive = false;
    try {
      return await operation();
    } finally {
      _importOperationActive = false;
    }
  }

  Future<StructuredImportExecutionResult> importArchiveSelection(
    String archivePath,
    String? parentId, {
    required StructuredImportSortOptions sortOptions,
    ImportPlacementRequest? importPlacement,
    bool explicitPlacement = false,
  }) {
    final placement =
        importPlacement ??
        (explicitPlacement
            ? ImportPlacementRequest.explicit(
                ImportCardFeature.archive,
                parentId,
              )
            : SettingsService().captureImportPlacement(
                ImportCardFeature.archive,
                openedFromFolderId: parentId,
              ));
    return _runExclusiveImport(
      () => _importArchiveSelectionInternal(
        archivePath,
        parentId,
        sortOptions: sortOptions,
        importPlacement: placement,
      ),
    );
  }

  Future<StructuredImportExecutionResult> _importArchiveSelectionInternal(
    String archivePath,
    String? parentId, {
    required StructuredImportSortOptions sortOptions,
    required ImportPlacementRequest importPlacement,
  }) async {
    final destinationParentId = await resolveImportCardParentId(
      feature: ImportCardFeature.archive,
      openedFromFolderId: parentId,
      request: importPlacement,
    );
    if (!isSupportedArchivePath(archivePath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }

    final filterMediaExtensions =
        SettingsService().localImportFilterMediaExtensions;
    final shouldDeleteSourceArchive = await _isAppOwnedArchiveCachePath(
      archivePath,
    );
    final importRootDir = await _createArchiveImportDirectory(archivePath);
    try {
      isImporting.value = true;
      await _setImportProgress(progress: 0.0, status: '正在准备解压压缩包...');
      await _setImportProgress(progress: 0.0, status: '正在后台解压压缩包...');
      final extractionSummary =
          await compute(_extractArchiveToDiskWorker, <String, Object?>{
            'archivePath': archivePath,
            'destDir': importRootDir.path,
            'filterMediaExtensions': filterMediaExtensions,
            'maxEntryCount': _defaultMaxArchiveEntryCount,
            'maxTotalBytes': _defaultMaxArchiveTotalBytes,
            'maxSingleFileBytes': _defaultMaxArchiveSingleFileBytes,
            'maxPathDepth': _defaultMaxArchivePathDepth,
            'maxCompressionRatio': _defaultMaxArchiveCompressionRatio,
          });
      final extractedMediaEntries =
          extractionSummary['extractedMediaEntries'] ?? 0;
      if (extractedMediaEntries <= 0) {
        throw StateError('压缩包中未解析到可导入的媒体文件');
      }
      await _setImportProgress(
        progress: 0.34,
        status: '解压完成，检测到 $extractedMediaEntries 个媒体，正在导入...',
      );
      return await _importDirectoryTreeIntoLibrary(
        sourceDir: importRootDir,
        rootCollectionName: archiveRootCollectionName(archivePath),
        parentId: destinationParentId,
        sortOptions: sortOptions,
        importLabel: '压缩包',
        filterMediaExtensions: filterMediaExtensions,
        moveImportedFilesToLibrary: true,
        totalMediaEntriesHint: extractedMediaEntries,
        deferPostProcessing: true,
        activitySourceKind: LibraryImportSourceKind.archive,
      );
    } catch (_) {
      await _deleteDirectoryIfExists(importRootDir);
      rethrow;
    } finally {
      if (await importRootDir.exists()) {
        if (_isImportDirectoryReferenced(importRootDir.path)) {
          await _clearArchiveImportMarker(importRootDir);
        } else {
          await _deleteDirectoryIfExists(importRootDir);
        }
      }
      if (shouldDeleteSourceArchive) {
        await _deleteFileIfExists(archivePath);
      }
      isImporting.value = false;
      importProgress.value = 0.0;
      importStatus.value = '';
    }
  }

  Future<StructuredImportExecutionResult> _importDirectoryTreeIntoLibrary({
    required Directory sourceDir,
    required String rootCollectionName,
    required String? parentId,
    required StructuredImportSortOptions sortOptions,
    required String importLabel,
    bool moveImportedFilesToLibrary = false,
    bool copyImportedFilesToLibrary = false,
    required int? totalMediaEntriesHint,
    bool deferPostProcessing = false,
    bool filterMediaExtensions = true,
    LibraryImportSourceKind? activitySourceKind,
  }) async {
    if (!skipImportSidecarWorkForTesting) {
      await Future.delayed(const Duration(milliseconds: 120));
    }
    if (parentId != null && !_collections.containsKey(parentId)) {
      throw StateError('目标文件夹不存在');
    }

    final accumulator = _StructuredImportAccumulator();
    DateTime lastNotifyTime = DateTime.now();
    late VideoCollection rootCollection;
    if (activitySourceKind != null) {
      accumulator.activityBatchId = beginImportBatch(
        title: rootCollectionName,
        sourceKind: activitySourceKind,
        targetCollectionId: parentId,
      );
    }

    try {
      _invalidateSizeCaches();
      isImporting.value = true;
      importProgress.value = 0.0;
      importStatus.value = '正在创建文件夹结构...';

      rootCollection = _createCollectionInMemory(
        rootCollectionName,
        parentId,
        accumulator,
      );
      accumulator.createdFolderCount++;

      await _importDirectoryContentsRecursive(
        sourceDir: sourceDir,
        parentCollectionId: rootCollection.id,
        sortOptions: sortOptions,
        accumulator: accumulator,
        lastNotifyTime: () => lastNotifyTime,
        updateLastNotifyTime: (value) => lastNotifyTime = value,
        moveImportedFilesToLibrary: moveImportedFilesToLibrary,
        copyImportedFilesToLibrary: copyImportedFilesToLibrary,
        totalMediaEntriesHint: totalMediaEntriesHint,
        importLabel: importLabel,
        probeDurationDuringImport: !deferPostProcessing,
        filterMediaExtensions: filterMediaExtensions,
      );

      final activityBatchId = accumulator.activityBatchId;
      if (activityBatchId != null) {
        final published = await completeImportBatch(
          activityBatchId,
          persist: false,
        );
        if (!published) {
          abortImportBatch(activityBatchId);
        }
      }

      await _saveLibrary();
      notifyListeners();

      if (deferPostProcessing) {
        final postProcessIds = List<String>.from(accumulator.newVideoIds);
        unawaited(
          _postImportQueue
              .enqueue(() => _postProcessImportedIds(postProcessIds))
              .catchError((Object error, StackTrace stackTrace) {
                developer.log(
                  '导入后媒体处理失败',
                  error: error,
                  stackTrace: stackTrace,
                  name: 'library.post_import',
                );
              }),
        );
      } else {
        await _generateThumbnailsForImportedIds(
          accumulator.newVideoIds,
          statusPrefix: importLabel,
        );
        await _saveLibrary();
        notifyListeners();
      }

      return StructuredImportExecutionResult(
        rootCollectionId: rootCollection.id,
        createdFolderCount: accumulator.createdFolderCount,
        importedMediaCount: accumulator.importedMediaCount,
        restoredMediaCount: accumulator.restoredMediaCount,
        importedVideoIds: List<String>.unmodifiable(accumulator.newVideoIds),
        activityBatchId: accumulator.activityBatchId,
      );
    } catch (e) {
      final activityBatchId = accumulator.activityBatchId;
      if (activityBatchId != null) {
        abortImportBatch(activityBatchId);
      }
      await _cleanupStructuredImportArtifacts(accumulator.newVideoIds);
      _rollbackStructuredImportState(accumulator);
      await _saveLibrary();
      notifyListeners();
      rethrow;
    } finally {
      isImporting.value = false;
      importProgress.value = 0.0;
      importStatus.value = '';
    }
  }

  Future<void> _importDirectoryContentsRecursive({
    required Directory sourceDir,
    required String parentCollectionId,
    required StructuredImportSortOptions sortOptions,
    required _StructuredImportAccumulator accumulator,
    required DateTime Function() lastNotifyTime,
    required void Function(DateTime value) updateLastNotifyTime,
    required bool moveImportedFilesToLibrary,
    required bool copyImportedFilesToLibrary,
    required int? totalMediaEntriesHint,
    required String importLabel,
    required bool probeDurationDuringImport,
    required bool filterMediaExtensions,
  }) async {
    final entries = await _collectImportEntries(
      sourceDir,
      sortOptions,
      filterMediaExtensions: filterMediaExtensions,
    );
    for (final entry in entries) {
      if (entry.isDirectory) {
        final childCollection = _createCollectionInMemory(
          entry.name,
          parentCollectionId,
          accumulator,
        );
        accumulator.createdFolderCount++;
        await _importDirectoryContentsRecursive(
          sourceDir: Directory(entry.entity.path),
          parentCollectionId: childCollection.id,
          sortOptions: sortOptions,
          accumulator: accumulator,
          lastNotifyTime: lastNotifyTime,
          updateLastNotifyTime: updateLastNotifyTime,
          moveImportedFilesToLibrary: moveImportedFilesToLibrary,
          copyImportedFilesToLibrary: copyImportedFilesToLibrary,
          totalMediaEntriesHint: totalMediaEntriesHint,
          importLabel: importLabel,
          probeDurationDuringImport: probeDurationDuringImport,
          filterMediaExtensions: filterMediaExtensions,
        );
      } else {
        await _addStructuredMediaFile(
          filePath: entry.entity.path,
          parentId: parentCollectionId,
          accumulator: accumulator,
          moveImportedFilesToLibrary: moveImportedFilesToLibrary,
          copyImportedFilesToLibrary: copyImportedFilesToLibrary,
          probeDuration: probeDurationDuringImport,
        );
        await _updateStructuredImportProgressIfNeeded(
          accumulator: accumulator,
          totalMediaEntriesHint: totalMediaEntriesHint,
          importLabel: importLabel,
          lastNotifyTime: lastNotifyTime,
          updateLastNotifyTime: updateLastNotifyTime,
        );
      }

      if (DateTime.now().difference(lastNotifyTime()).inMilliseconds > 600) {
        notifyListeners();
        updateLastNotifyTime(DateTime.now());
      }
    }
  }

  Future<void> _updateStructuredImportProgressIfNeeded({
    required _StructuredImportAccumulator accumulator,
    required int? totalMediaEntriesHint,
    required String importLabel,
    required DateTime Function() lastNotifyTime,
    required void Function(DateTime value) updateLastNotifyTime,
  }) async {
    if (totalMediaEntriesHint == null || totalMediaEntriesHint <= 0) {
      return;
    }

    final importedCount = accumulator.importedMediaCount;
    if (importedCount <= 0) {
      return;
    }

    final now = DateTime.now();
    final shouldForceUpdate = importedCount >= totalMediaEntriesHint;
    if (!shouldForceUpdate &&
        now.difference(lastNotifyTime()).inMilliseconds <= 160) {
      return;
    }

    final normalizedProgress = (importedCount / totalMediaEntriesHint)
        .clamp(0.0, 1.0)
        .toDouble();
    final progress = 0.34 + (normalizedProgress * 0.36);
    await _setImportProgress(
      progress: shouldForceUpdate
          ? 0.70
          : progress.clamp(0.34, 0.70).toDouble(),
      status: '正在导入$importLabel媒体...($importedCount/$totalMediaEntriesHint)',
    );
    updateLastNotifyTime(now);
  }

  Future<List<_FileSystemEntrySnapshot>> _collectImportEntries(
    Directory sourceDir,
    StructuredImportSortOptions sortOptions, {
    required bool filterMediaExtensions,
  }) async {
    final entries = <_FileSystemEntrySnapshot>[];
    await for (final entity in sourceDir.list(followLinks: false)) {
      if (entity is Directory) {
        entries.add(await _snapshotImportEntry(entity, true));
      } else if (entity is File &&
          // The archive recovery journal is app metadata, never imported media.
          !(p.basename(entity.path) == _archiveImportMarkerName &&
              p.isWithin(
                p.join(_dataRootDir.path, _importedArchivesDirName),
                entity.path,
              )) &&
          (!filterMediaExtensions || isSupportedMediaPath(entity.path))) {
        entries.add(await _snapshotImportEntry(entity, false));
      }
    }

    entries.sort((left, right) {
      int comparison;
      if (sortOptions.field == StructuredImportSortField.modifiedTime) {
        comparison = left.modifiedTimeMs.compareTo(right.modifiedTimeMs);
        if (comparison == 0) {
          comparison = compareStructuredImportNames(left.name, right.name);
        }
      } else {
        comparison = compareStructuredImportNames(left.name, right.name);
      }
      if (comparison == 0 && left.isDirectory != right.isDirectory) {
        comparison = left.isDirectory ? -1 : 1;
      }
      if (sortOptions.direction == StructuredImportSortDirection.descending) {
        comparison *= -1;
      }
      return comparison;
    });
    return entries;
  }

  static int compareStructuredImportNames(String left, String right) {
    final leftParts = _splitNaturalSortParts(left);
    final rightParts = _splitNaturalSortParts(right);
    final minLength = leftParts.length < rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var i = 0; i < minLength; i++) {
      final leftPart = leftParts[i];
      final rightPart = rightParts[i];
      final leftIsNumber = RegExp(r'^\d+$').hasMatch(leftPart);
      final rightIsNumber = RegExp(r'^\d+$').hasMatch(rightPart);

      int comparison;
      if (leftIsNumber && rightIsNumber) {
        comparison = int.parse(leftPart).compareTo(int.parse(rightPart));
      } else {
        comparison = _normalizeSortSegment(
          leftPart,
        ).compareTo(_normalizeSortSegment(rightPart));
      }
      if (comparison != 0) {
        return comparison;
      }
    }

    final lengthComparison = leftParts.length.compareTo(rightParts.length);
    if (lengthComparison != 0) {
      return lengthComparison;
    }

    return left.toLowerCase().compareTo(right.toLowerCase());
  }

  static List<String> _splitNaturalSortParts(String value) {
    return RegExp(
      r'\d+|\D+',
    ).allMatches(value).map((m) => m.group(0)!).toList();
  }

  static String _normalizeSortSegment(String value) {
    if (!_containsChineseCharacters(value)) {
      return value.toLowerCase();
    }

    final pinyin = PinyinHelper.getPinyinE(
      value,
      separator: '',
      defPinyin: '',
      format: PinyinFormat.WITHOUT_TONE,
    );
    return pinyin.toLowerCase();
  }

  static bool _containsChineseCharacters(String value) {
    return RegExp(r'[\u3400-\u9FFF]').hasMatch(value);
  }

  Future<_FileSystemEntrySnapshot> _snapshotImportEntry(
    FileSystemEntity entity,
    bool isDirectory,
  ) async {
    var modifiedTimeMs = 0;
    try {
      modifiedTimeMs = (await entity.stat()).modified.millisecondsSinceEpoch;
    } catch (_) {}
    return _FileSystemEntrySnapshot(
      entity: entity,
      name: p.basename(entity.path),
      isDirectory: isDirectory,
      modifiedTimeMs: modifiedTimeMs,
    );
  }

  Future<void> _addStructuredMediaFile({
    required String filePath,
    required String? parentId,
    required _StructuredImportAccumulator accumulator,
    required bool moveImportedFilesToLibrary,
    required bool copyImportedFilesToLibrary,
    required bool probeDuration,
  }) async {
    final id = const Uuid().v4();

    final shouldManageSidecarSubtitles =
        moveImportedFilesToLibrary || copyImportedFilesToLibrary;
    // 结构化导入：同一智能匹配算法。时长因子在此阶段不可用（视频尚未
    // 进入库内完成时长探测），故仅以文件名证据决定是否绑定。
    final discoveredSubtitles = shouldManageSidecarSubtitles
        ? await const SubtitleDiscoveryService().scanVideoDirectory(
            videoPath: filePath,
          )
        : const <DiscoveredSubtitleFile>[];

    var effectivePath = filePath;
    if (moveImportedFilesToLibrary) {
      effectivePath = await _moveStructuredImportFileToLibrary(
        filePath,
        fileNamePrefix: id,
      );
      if (_samePath(effectivePath, filePath)) {
        throw FileSystemException('压缩包媒体移入应用存储失败', filePath);
      }
    } else if (copyImportedFilesToLibrary) {
      effectivePath = await _copyImportedMediaToPrivateStorage(
        filePath,
        fileNamePrefix: id,
      );
    }

    final originalTitle = resolveImportedMediaTitle(sourcePath: filePath);
    final sourceFingerprint = await _computeSourceFingerprint(effectivePath);
    final durationMs = probeDuration
        ? await _probeMediaDurationMs(effectivePath)
        : 0;
    final item = VideoItem(
      id: id,
      path: effectivePath,
      title: originalTitle,
      thumbnailPath: null,
      durationMs: durationMs,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
      type: _detectMediaType(effectivePath),
      sourceFingerprint: sourceFingerprint,
    );
    try {
      await _adoptStructuredImportSubtitles(item, discoveredSubtitles);
      if (probeDuration && !skipImportSidecarWorkForTesting) {
        item.chapters = await MediaChapterProbe.probe(
          effectivePath,
          durationMs: durationMs,
        );
        item.hasProbedChapters = true;
      } else if (skipImportSidecarWorkForTesting) {
        item.hasProbedChapters = true;
      }
      await _prepareCompatiblePlaybackFile(item, saveLibrary: false);
      if (!skipImportSidecarWorkForTesting && item.type == MediaType.audio) {
        // Read covr / APIC / cover.jpg before an archive import deletes the
        // source directory. ffmpeg stays in the later thumbnail pass.
        final cover = await _extractAudioCoverArt(
          item.path,
          videoId: item.id,
          sidecarHintPath: filePath,
          allowFfmpegFallback: false,
        );
        if (cover != null) {
          item.thumbnailPath = cover;
          item.hasProbedAudioCover = true;
        }
      }
    } catch (_) {
      await TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      ).deleteTaskDirectory(id);
      if ((moveImportedFilesToLibrary || copyImportedFilesToLibrary) &&
          _isInternalPath(effectivePath)) {
        await _deleteFileIfExists(effectivePath);
      }
      rethrow;
    }
    _videos[id] = item;
    if (parentId != null && _collections.containsKey(parentId)) {
      _collections[parentId]!.childrenIds.add(id);
    } else {
      _rootChildrenIds.add(id);
    }
    accumulator.newVideoIds.add(id);
    accumulator.importedMediaCount++;
    final batchId = accumulator.activityBatchId;
    if (batchId != null) {
      noteImportedMedia(
        id,
        addedAtMs: DateTime.now().millisecondsSinceEpoch,
        batchId: batchId,
      );
    }
    final failAfter = structuredImportFailAfterCountForTesting;
    if (failAfter != null && accumulator.importedMediaCount >= failAfter) {
      throw StateError('test structured import fault');
    }
  }

  Future<void> _adoptStructuredImportSubtitles(
    VideoItem item,
    List<DiscoveredSubtitleFile> subtitles,
  ) async {
    // 只收录"命名证据充分、可自动匹配"（A 类）的字幕；评分不足的字幕
    // 不强行绑定到本视频（B 站轨道等被引擎判为 rejected 的也不收录）。
    final eligible = subtitles.where((entry) => entry.analysis.isAuto).toList();
    if (eligible.isEmpty) return;

    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    final labeled = <({String label, String path})>[];
    for (final subtitle in eligible) {
      final copiedPath = await storage.copyIntoTask(
        item.id,
        subtitle.path,
        preferredFileName: p.basename(subtitle.path),
      );
      // The on-screen name is the original stem, without ".srt" and without
      // a "（2）" suffix. Two files both named 中文.srt both display as 中文.
      final stem = p.basenameWithoutExtension(subtitle.path).trim();
      labeled.add((label: stem.isEmpty ? '字幕' : stem, path: copiedPath));
    }
    final bound = bindSubtitleLabels(labeled);
    final createdAt = DateTime.now().millisecondsSinceEpoch;
    final localSubtitles = <String, String>{
      for (final entry in bound) entry.storageKey: entry.path,
    };
    final managedAssets = <ManagedSubtitleAsset>[
      for (final entry in bound)
        ManagedSubtitleAsset(
          assetId: const Uuid().v4(),
          path: p.normalize(entry.path),
          wordTimingPath:
              File(SubtitleWordTimingStore.pathFor(entry.path)).existsSync()
              ? SubtitleWordTimingStore.pathFor(entry.path)
              : null,
          kind: ManagedSubtitleAssetKind.imported,
          displayName: entry.displayName,
          createdAt: createdAt,
        ),
    ];

    item.localSubtitles = localSubtitles;
    item.managedSubtitleAssets = managedAssets;
    // 服务端已把最优候选排在最前；导入绑定默认字幕取排序第一的合格候选。
    item.subtitlePath = managedAssets.first.path;
    item.isSubtitleCached = true;
  }

  VideoCollection _createCollectionInMemory(
    String name,
    String? parentId,
    _StructuredImportAccumulator accumulator,
  ) {
    final collection = VideoCollection(
      id: const Uuid().v4(),
      name: name,
      createTime: DateTime.now().millisecondsSinceEpoch,
      parentId: parentId,
    );
    _collections[collection.id] = collection;
    accumulator.newCollectionIds.add(collection.id);
    noteImportedCollection(collection.id, batchId: accumulator.activityBatchId);
    if (parentId != null && _collections.containsKey(parentId)) {
      _collections[parentId]!.childrenIds.add(collection.id);
    } else {
      _rootChildrenIds.add(collection.id);
    }
    return collection;
  }

  void _rollbackStructuredImportState(
    _StructuredImportAccumulator accumulator,
  ) {
    for (final videoId in accumulator.newVideoIds) {
      final item = _videos.remove(videoId);
      if (item?.parentId != null) {
        _collections[item!.parentId]?.childrenIds.remove(videoId);
      } else {
        _rootChildrenIds.remove(videoId);
      }
      _purgeActivityForDeletedMedia(videoId);
    }
    for (final collectionId in accumulator.newCollectionIds.reversed) {
      final collection = _collections.remove(collectionId);
      if (collection?.parentId != null) {
        _collections[collection!.parentId]?.childrenIds.remove(collectionId);
      } else {
        _rootChildrenIds.remove(collectionId);
      }
    }
    _invalidateSizeCaches();
  }

  Future<void> _generateThumbnailsForImportedIds(
    List<String> newIds, {
    required String statusPrefix,
    bool reportProgress = true,
  }) async {
    if (skipImportSidecarWorkForTesting) {
      return;
    }
    if (newIds.isEmpty) {
      if (reportProgress) {
        await _setImportProgress(progress: 1.0, status: '$statusPrefix导入完成');
      }
      return;
    }

    if (reportProgress) {
      await _setImportProgress(progress: 0.7, status: '正在生成缩略图...');
    }
    var current = 0;
    // Windows 端每个 _generateThumbnailWindows 最多启动 2 个 ffmpeg 进程，
    // batchSize=4 时峰值可达 8+ 个 ffmpeg.exe 并发，易耗尽内存导致闪退。
    // 降为 2 后峰值约 4 个，内存占用更可控。
    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    final batchSize = isDesktop ? 2 : 1;
    for (int i = 0; i < newIds.length; i += batchSize) {
      final batch = newIds.sublist(
        i,
        i + batchSize > newIds.length ? newIds.length : i + batchSize,
      );
      await Future.wait(
        batch.map((id) async {
          final item = _videos[id];
          if (item == null) return;
          if (item.type == MediaType.audio) {
            try {
              await _resolveImportedAudioCover(
                item,
                sidecarHintPath: _audioSidecarHints.remove(id),
                persist: false,
              );
            } catch (e) {
              developer.log(
                '音频封面提取失败: ${item.path}',
                error: e,
                name: 'library.thumbnail',
              );
            }
            return;
          }
          if (item.type != MediaType.video) {
            return;
          }
          // 独立 try-catch：单个缩略图失败不应中断整批导入
          try {
            item.thumbnailPath = await _generateThumbnail(
              item.path,
              videoId: item.id,
            );
          } catch (e) {
            developer.log(
              '缩略图生成失败: ${item.path}',
              error: e,
              name: 'library.thumbnail',
            );
          }
        }),
      );
      current += batch.length;
      if (reportProgress) {
        final progress = 0.7 + (current / newIds.length) * 0.3;
        await _setImportProgress(
          progress: progress.clamp(0.0, 1.0).toDouble(),
          status: '正在生成缩略图...($current/${newIds.length})',
        );
      }
    }
  }

  Future<void> _postProcessImportedIds(List<String> importedIds) async {
    var changed = false;
    for (final id in importedIds) {
      final item = _videos[id];
      if (item == null) continue;
      if (item.durationMs <= 0) {
        final durationMs = await _probeMediaDurationMs(item.path);
        if (durationMs > 0 && _videos[id] != null) {
          item.durationMs = durationMs;
          item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
          changed = true;
        }
      }
      if (!item.hasProbedChapters && _videos[id] != null) {
        item.chapters = await MediaChapterProbe.probe(
          item.path,
          durationMs: item.durationMs,
        );
        item.hasProbedChapters = true;
        item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
        changed = true;
      }
    }

    await _generateThumbnailsForImportedIds(
      importedIds,
      statusPrefix: '后台',
      reportProgress: false,
    );
    if (changed || importedIds.isNotEmpty) {
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> _setImportProgress({
    required double progress,
    required String status,
  }) async {
    importProgress.value = progress;
    importStatus.value = status;
  }

  /// Drives the top-bar overlay without expanding titles via [isImporting].
  /// Returns false when an exclusive/local import currently owns the bar.
  bool reportTransientImportProgress({
    required double progress,
    required String status,
  }) {
    if (_importOperationActive && !_transientImportProgressActive) {
      return false;
    }
    _transientImportProgressActive = true;
    importProgress.value = progress.clamp(0.02, 0.99);
    importStatus.value = status;
    return true;
  }

  /// Hides the overlay after a transient import. No-op if local import took over.
  void clearTransientImportProgress() {
    if (!_transientImportProgressActive) {
      return;
    }
    _transientImportProgressActive = false;
    if (_importOperationActive) {
      return;
    }
    importProgress.value = 0.0;
    importStatus.value = '';
  }

  Future<void> _cleanupStructuredImportArtifacts(
    Iterable<String> importedVideoIds,
  ) async {
    for (final videoId in importedVideoIds) {
      final item = _videos[videoId];
      if (item == null) {
        continue;
      }
      final candidatePaths = <String>[
        item.path,
        if (item.thumbnailPath != null && item.thumbnailPath!.isNotEmpty)
          item.thumbnailPath!,
      ];

      for (final path in candidatePaths) {
        if (!_isInternalPath(path)) {
          continue;
        }
        try {
          final file = File(path);
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
      }
      try {
        await TaskSubtitleStorageService(
          dataRootOverride: _dataRootDir,
        ).deleteTaskDirectory(videoId);
      } catch (_) {}
    }
  }

  Future<Directory> _createArchiveImportDirectory(String archivePath) async {
    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (!await importedArchivesDir.exists()) {
      await importedArchivesDir.create(recursive: true);
    }

    final safeName = archiveRootCollectionName(
      archivePath,
    ).replaceAll(RegExp(r'[<>:"/\\|?*]+'), '_').trim();
    final baseName = _sanitizeArchivePathSegment(
      safeName.isEmpty ? 'archive' : safeName,
      preserveExtension: false,
      fallbackName: 'archive',
    );
    final importDir = Directory(
      p.join(
        importedArchivesDir.path,
        '${DateTime.now().millisecondsSinceEpoch}_$baseName',
      ),
    );
    await importDir.create(recursive: true);
    await _writeArchiveImportMarker(importDir, archivePath);
    return importDir;
  }

  Future<void> _writeArchiveImportMarker(
    Directory importDir,
    String archivePath,
  ) async {
    final markerFile = File(p.join(importDir.path, _archiveImportMarkerName));
    await markerFile.writeAsString(
      json.encode({
        'archivePath': archivePath,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      }),
      flush: true,
    );
  }

  Future<void> _clearArchiveImportMarker(Directory importDir) async {
    final markerFile = File(p.join(importDir.path, _archiveImportMarkerName));
    if (await markerFile.exists()) {
      await markerFile.delete();
    }
  }

  Future<void> _cleanupIncompleteArchiveImports() async {
    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (!await importedArchivesDir.exists()) {
      return;
    }

    final referenced = <String>{};
    for (final item in _videos.values) {
      if (p.isWithin(importedArchivesDir.path, item.path)) {
        final first = p
            .split(p.relative(item.path, from: importedArchivesDir.path))
            .first;
        final directory = p.join(importedArchivesDir.path, first);
        referenced.add(
          Platform.isWindows ? directory.toLowerCase() : directory,
        );
      }
    }

    await for (final entity in importedArchivesDir.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final markerFile = File(p.join(entity.path, _archiveImportMarkerName));
      final hasMarker = await markerFile.exists();
      final archivePath = hasMarker
          ? await _readArchivePathFromMarker(markerFile)
          : null;

      if (referenced.contains(
        Platform.isWindows ? entity.path.toLowerCase() : entity.path,
      )) {
        if (hasMarker) {
          await _clearArchiveImportMarker(entity);
        }
      } else {
        if (hasActiveImport || _isImportDirectoryReferenced(entity.path)) {
          continue;
        }
        await _deleteDirectoryIfExists(entity);
      }

      if (archivePath != null &&
          await _isAppOwnedArchiveCachePath(archivePath)) {
        await _deleteFileIfExists(archivePath);
      }
    }
  }

  Future<void> _cleanupOrphanedArchiveSelectionCaches() async {
    final cacheDirs = <Directory>[];
    try {
      final tempDir = await getTemporaryDirectory();
      cacheDirs.add(
        Directory(p.join(tempDir.path, _pickedArchivesCacheDirName)),
      );
    } catch (_) {}

    if (Platform.isAndroid) {
      try {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            cacheDirs.add(
              Directory(p.join(dir.path, _pickedArchivesCacheDirName)),
            );
          }
        }
      } catch (_) {}
    }

    final seen = <String>{};
    for (final dir in cacheDirs) {
      final normalizedPath = p.normalize(dir.path);
      if (!seen.add(
        Platform.isWindows ? normalizedPath.toLowerCase() : normalizedPath,
      )) {
        continue;
      }
      await _deleteDirectoryIfExists(dir);
    }
  }

  Future<TemporaryStorageCategoryReport>
  buildArchiveTemporaryStorageReport() async {
    final stats = await _collectArchiveTemporaryStorageStats();
    return TemporaryStorageCategoryReport(
      id: 'archive_import_temp',
      title: '压缩包导入临时文件',
      description: '压缩包选择缓存与未被媒体库引用的中间导入目录',
      fileCount: stats.fileCount,
      totalBytes: stats.totalBytes,
      canClean: stats.fileCount > 0,
      note: stats.fileCount == 0 ? '未发现可安全清理的压缩包临时文件。' : null,
    );
  }

  Future<void> clearArchiveTemporaryStorageArtifacts() async {
    final stats = await _collectArchiveTemporaryStorageStats(
      includeDirectories: true,
    );
    for (final file in stats.files) {
      await _deleteFileIfExists(file.path);
    }
    for (final dir in stats.directories) {
      await _deleteDirectoryIfExists(dir);
    }
  }

  bool _isImportDirectoryReferenced(String importDirPath) {
    final normalizedImportPath = p.normalize(importDirPath);
    for (final item in _videos.values) {
      final normalizedVideoPath = p.normalize(item.path);
      if (p.equals(normalizedImportPath, normalizedVideoPath) ||
          p.isWithin(normalizedImportPath, normalizedVideoPath)) {
        return true;
      }
    }
    return false;
  }

  Future<_ArchiveTemporaryStorageStats> _collectArchiveTemporaryStorageStats({
    bool includeDirectories = false,
  }) async {
    final files = <File>{};
    final directories = <Directory>{};
    final protectedArchivePaths =
        await _collectProtectedArchiveSelectionPaths();

    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (await importedArchivesDir.exists()) {
      await for (final entity in importedArchivesDir.list(followLinks: false)) {
        if (entity is! Directory || _isImportDirectoryReferenced(entity.path)) {
          continue;
        }
        if (includeDirectories) {
          directories.add(entity);
        } else {
          await _collectFilesRecursively(entity, files);
        }
      }
    }

    final cacheDirs = await _collectArchiveSelectionCacheDirs();
    for (final cacheDir in cacheDirs) {
      if (!await cacheDir.exists()) {
        continue;
      }
      await for (final entity in cacheDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          final normalizedPath = _normalizeTemporaryStoragePath(entity.path);
          if (protectedArchivePaths.contains(normalizedPath)) {
            continue;
          }
          files.add(entity);
        } else if (includeDirectories && entity is Directory) {
          directories.add(entity);
        }
      }
      if (includeDirectories) {
        directories.add(cacheDir);
      }
    }

    var totalBytes = 0;
    for (final file in files) {
      totalBytes += await _safeTemporaryStorageFileSize(file);
    }

    return _ArchiveTemporaryStorageStats(
      files: files.toList(),
      directories: directories.toList()
        ..sort((a, b) => b.path.length.compareTo(a.path.length)),
      fileCount: files.length,
      totalBytes: totalBytes,
    );
  }

  Future<List<Directory>> _collectArchiveSelectionCacheDirs() async {
    final cacheDirs = <Directory>[];
    try {
      final tempDir = await getTemporaryDirectory();
      cacheDirs.add(
        Directory(p.join(tempDir.path, _pickedArchivesCacheDirName)),
      );
    } catch (_) {}

    if (Platform.isAndroid) {
      try {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            cacheDirs.add(
              Directory(p.join(dir.path, _pickedArchivesCacheDirName)),
            );
          }
        }
      } catch (_) {}
    }

    final seen = <String>{};
    return cacheDirs.where((dir) {
      return seen.add(_normalizeTemporaryStoragePath(dir.path));
    }).toList();
  }

  Future<Set<String>> _collectProtectedArchiveSelectionPaths() async {
    final protected = <String>{};
    final importedArchivesDir = Directory(
      p.join(_dataRootDir.path, _importedArchivesDirName),
    );
    if (!await importedArchivesDir.exists()) {
      return protected;
    }

    await for (final entity in importedArchivesDir.list(followLinks: false)) {
      if (entity is! Directory || !_isImportDirectoryReferenced(entity.path)) {
        continue;
      }
      final markerFile = File(p.join(entity.path, _archiveImportMarkerName));
      final archivePath = await _readArchivePathFromMarker(markerFile);
      if (archivePath == null || archivePath.isEmpty) {
        continue;
      }
      if (await _isAppOwnedArchiveCachePath(archivePath)) {
        protected.add(_normalizeTemporaryStoragePath(archivePath));
      }
    }
    return protected;
  }

  Future<void> _collectFilesRecursively(
    Directory root,
    Set<File> output,
  ) async {
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        output.add(entity);
      }
    }
  }

  String _normalizeTemporaryStoragePath(String path) {
    final normalized = p.normalize(path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<int> _safeTemporaryStorageFileSize(File file) async {
    try {
      if (!await file.exists()) {
        return 0;
      }
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteDirectoryIfExists(Directory dir) async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<String?> _readArchivePathFromMarker(File markerFile) async {
    try {
      final raw = await markerFile.readAsString();
      final decoded = json.decode(raw);
      if (decoded is Map<String, dynamic>) {
        final archivePath = decoded['archivePath'];
        if (archivePath is String && archivePath.isNotEmpty) {
          return archivePath;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _deleteFileIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<bool> _isAppOwnedArchiveCachePath(String filePath) async {
    try {
      final normalizedPath = p.normalize(filePath);
      final tempDir = await getTemporaryDirectory();
      final archiveCache = p.normalize(
        p.join(tempDir.path, _pickedArchivesCacheDirName),
      );
      if (p.isWithin(archiveCache, normalizedPath)) {
        return true;
      }

      if (Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            final externalArchiveCache = p.normalize(
              p.join(dir.path, _pickedArchivesCacheDirName),
            );
            if (p.isWithin(externalArchiveCache, normalizedPath)) {
              return true;
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  String _sanitizeImportedFileName(String fileName) {
    return _sanitizeArchivePathSegment(
      fileName,
      preserveExtension: true,
      fallbackName: 'file',
    );
  }

  /// Creates a verified app-managed copy without ever exposing a partially
  /// copied file as a playable media source.
  Future<String> _copyImportedMediaToPrivateStorage(
    String sourcePath, {
    required String fileNamePrefix,
  }) async {
    final normalizedSourcePath = p.normalize(sourcePath);
    final importedDir = await AppStorageService.instance.importedMediaDirectory(
      dataRoot: _dataRootDir,
    );
    final sourceFile = File(normalizedSourcePath);
    if (!await sourceFile.exists()) {
      throw FileSystemException('导入源文件不存在', normalizedSourcePath);
    }

    // Already managed downloads/imports must not acquire a second full copy.
    if (_isInternalPath(normalizedSourcePath)) return normalizedSourcePath;

    await importedDir.create(recursive: true);
    final safeName = _sanitizeImportedFileName(p.basename(sourcePath));
    final targetPath = p.join(importedDir.path, '${fileNamePrefix}_$safeName');
    final partialPath = '$targetPath.partial';
    final partialFile = File(partialPath);
    final targetFile = File(targetPath);

    try {
      await _deleteFileIfExists(partialPath);
      final sourceBefore = await sourceFile.stat();
      await sourceFile.copy(partialPath);
      final sourceAfter = await sourceFile.stat();
      final sourceLength = await sourceFile.length();
      final copiedLength = await partialFile.length();
      if (sourceLength != copiedLength ||
          sourceBefore.size != sourceAfter.size ||
          sourceBefore.modified != sourceAfter.modified ||
          sourceBefore.changed != sourceAfter.changed) {
        throw FileSystemException('媒体副本校验失败（文件大小不一致）', normalizedSourcePath);
      }
      if (await targetFile.exists()) {
        throw FileSystemException('媒体副本目标已存在', targetPath);
      }
      await partialFile.rename(targetPath);
      return targetPath;
    } catch (_) {
      await _deleteFileIfExists(partialPath);
      rethrow;
    }
  }

  Future<void> _releaseCommittedImportCacheCopies(
    Map<String, String> copies,
  ) async {
    if (copies.isEmpty || hasPersistenceFailure) return;
    final caches = await resolveImportCacheRoots();
    bool referenced(String path) => _videos.values.any(
      (item) =>
          _samePath(item.path, path) ||
          (item.playbackPath != null && _samePath(item.playbackPath!, path)) ||
          (item.thumbnailPath != null &&
              _samePath(item.thumbnailPath!, path)) ||
          _subtitleReferencesContainPath(item, path),
    );
    for (final copy in copies.entries) {
      await releaseVerifiedImportCacheCopy(
        sourcePath: copy.key,
        persistedPath: copy.value,
        cacheRoots: caches,
        scopedRoots:
            defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS,
        isReferenced: referenced,
      );
    }
  }

  Future<String> _moveStructuredImportFileToLibrary(
    String sourcePath, {
    required String fileNamePrefix,
  }) async {
    try {
      final sourceFile = File(sourcePath);
      if (!await sourceFile.exists()) {
        return sourcePath;
      }

      final importedDir = await AppStorageService.instance
          .importedMediaDirectory(dataRoot: _dataRootDir);
      if (!await importedDir.exists()) {
        await importedDir.create(recursive: true);
      }

      final targetPath = p.join(
        importedDir.path,
        '${fileNamePrefix}_${_sanitizeImportedFileName(p.basename(sourcePath))}',
      );

      try {
        return (await sourceFile.rename(targetPath)).path;
      } catch (_) {
        await sourceFile.copy(targetPath);
        await _deleteFileIfExists(sourcePath);
        return targetPath;
      }
    } catch (_) {
      return sourcePath;
    }
  }

  // A picker hint is read-only context, never a media path or file owner.
  // Only a cache-backed Android selection may carry the native host's trusted
  // local-document source. URI-only providers simply have no sibling context.
  Future<String?> _readablePickerSourceHint(
    String sourcePath,
    String? hint,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.android ||
        hint == null ||
        hint.contains('://') ||
        hint.split(RegExp(r'[/\\]')).contains('..') ||
        !p.isAbsolute(hint) ||
        !isSupportedMediaPath(hint) ||
        !await _isDisposableMediaCachePath(sourcePath)) {
      return null;
    }
    try {
      if (await FileSystemEntity.type(hint, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final source = File(hint);
      if (!_samePath(await source.resolveSymbolicLinks(), hint)) return null;
      final reader = await source.open();
      await reader.close();
      return p.normalize(hint);
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _adoptPickerSourceSubtitles(
    VideoItem item,
    String? sourceHint,
  ) async {
    if (sourceHint == null) return;
    try {
      final subtitles = await const SubtitleDiscoveryService()
          .scanVideoDirectory(
            videoPath: sourceHint,
            videoDurationMs: item.durationMs > 0 ? item.durationMs : null,
          );
      await _adoptStructuredImportSubtitles(item, subtitles);
    } catch (error) {
      // An optional sibling subtitle must not discard the selected media.
      // This card is new; partial subtitle copies are owned only by its id.
      try {
        await TaskSubtitleStorageService(
          dataRootOverride: _dataRootDir,
        ).deleteTaskDirectory(item.id);
      } on FileSystemException {
        // Best-effort removal must not turn an optional subtitle into a failed
        // media import when the task-subtitle directory is unavailable.
      }
      developer.log('Picker subtitle import skipped', error: error);
    }
  }

  // Batch import videos
  // filePaths: 视频文件的内部存储路径列表
  // parentId: 目标文件夹ID
  // shouldCopy: 是否复制文件到内部存储（仅用于外部文件）
  // useOriginalPath: 是否直接使用原始文件路径而不复制到应用内部存储
  // originalTitles: 可选参数，原始文件名列表，用于设置视频标题
  // reuseExistingItem: 是否复用已存在的媒体卡片；默认 false，导入同源文件时也创建新卡片
  Future<MediaImportExecutionResult> importVideosBackground(
    List<String> filePaths,
    String? parentId, {
    bool shouldCopy = false,
    bool allowCacheRescue = true,
    bool useOriginalPath = false,
    bool reuseExistingItem = false,
    List<String>? originalTitles,
    Map<String, String> sidecarSourcePaths = const {},
    LibraryImportSourceKind sourceKind = LibraryImportSourceKind.localFile,
    ImportCardFeature? importFeature,
    ImportPlacementRequest? importPlacement,
    bool explicitPlacement = false,
    bool Function()? shouldContinue,
    DownloadImportContext? downloadContext,
  }) async {
    final feature =
        importFeature ?? ImportCardFeatureX.fromSourceKind(sourceKind);
    final placement =
        importPlacement ??
        (explicitPlacement
            ? ImportPlacementRequest.explicit(feature, parentId)
            : SettingsService().captureImportPlacement(
                feature,
                openedFromFolderId: parentId,
              ));
    final total = filePaths.length;
    if (downloadContext != null && total != 1) {
      throw ArgumentError('下载入库上下文必须对应单个媒体文件');
    }
    if (total == 0) {
      return const MediaImportExecutionResult();
    }
    final copyImportedMediaToPrivateStorage =
        SettingsService().copyImportedMediaToPrivateStorage;

    if (_importOperationActive) {
      debugPrint(
        'Ignored overlapping media import while another import is active',
      );
      return const MediaImportExecutionResult(ignoredBecauseBusy: true);
    }
    _importOperationActive = true;
    _transientImportProgressActive = false;
    if (!skipImportSidecarWorkForTesting) {
      await Future.delayed(const Duration(milliseconds: 200));
    }

    String? activityBatchId;
    final reusedIds = <String>[];
    var failedCount = 0;
    try {
      parentId = await resolveImportCardParentId(
        feature: feature,
        openedFromFolderId: parentId,
        request: placement,
      );
      if (parentId != null && !_collections.containsKey(parentId)) {
        return const MediaImportExecutionResult();
      }
      final priorDownload = downloadContext == null
          ? null
          : importedDownloadMedia(downloadContext);
      if (priorDownload != null) {
        final receipt = await commitDownloadImport(
          priorDownload,
          context: downloadContext!,
          sourceKind: sourceKind,
          useOriginalPath: true,
        );
        return MediaImportExecutionResult(
          reusedVideoIds: [receipt.mediaId],
          activityBatchId: downloadContext.batchId,
        );
      }
      isImporting.value = true;
      importProgress.value = 0.0;
      importStatus.value = reuseExistingItem ? "正在检查现有媒体..." : "正在准备导入文件...";
      final newIds = <String>[];
      final committedCacheCopies = <String, String>{};
      DateTime lastNotifyTime = DateTime.now();
      activityBatchId =
          downloadContext?.batchId ??
          beginImportBatch(
            title: total == 1 ? p.basename(filePaths.first) : '导入 $total 个文件',
            sourceKind: sourceKind,
            targetCollectionId: parentId,
          );
      importStatus.value = "正在添加文件...";

      final importCacheRoots = await resolveImportCacheRoots();

      for (int i = 0; i < filePaths.length; i++) {
        if (shouldContinue?.call() == false) break;
        final sourcePath = filePaths[i];
        var path = sourcePath;
        var createdPrivateCopy = false;
        final id = downloadContext?.mediaId ?? const Uuid().v4();
        final originalTitle = resolveImportedMediaTitle(
          sourcePath: path,
          originalTitle: originalTitles != null && i < originalTitles.length
              ? originalTitles[i]
              : null,
        );
        final sourceFingerprint = await _computeSourceFingerprint(path);

        if (reuseExistingItem) {
          final existingId = await _findExistingVideoIdByPathOrFingerprint(
            path,
            sourceFingerprint: sourceFingerprint,
            originalTitle: originalTitle,
          );
          if (existingId != null) {
            if (shouldContinue?.call() == false) throw StateError('入库已取消');
            await _restoreExistingVideoToTarget(
              existingId,
              parentId,
              preserveOrder: downloadContext != null,
            );
            if (downloadContext != null) {
              _recordDownloadImport(
                existingId,
                downloadContext,
                sourceKind,
                const [],
                reusedExisting: true,
              );
              await _saveLibrary();
              _requireDurableDownloadImport();
            }
            reusedIds.add(existingId);
            continue;
          }
        }

        if (!useOriginalPath || copyImportedMediaToPrivateStorage) {
          bool isCached = false;
          if (allowCacheRescue) {
            isCached = importCacheRoots.any(
              (dir) => p.isWithin(dir.path, path),
            );
          }

          if ((allowCacheRescue && isCached) ||
              shouldCopy ||
              copyImportedMediaToPrivateStorage) {
            try {
              path = await _copyImportedMediaToPrivateStorage(
                path,
                fileNamePrefix: id,
              );
              createdPrivateCopy = !_samePath(sourcePath, path);
            } catch (e) {
              developer.log(
                '复制导入媒体到应用私有目录失败',
                error: e,
                name: 'library.import',
              );
              importStatus.value = '复制媒体失败，已跳过：$originalTitle';
              failedCount++;
              continue;
            }
          }
        }

        final durationMs = await _probeMediaDurationMs(path);
        final item = VideoItem(
          id: id,
          path: path,
          title: originalTitle,
          thumbnailPath: null,
          durationMs: durationMs,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          parentId: parentId,
          type: _detectMediaType(path),
          sourceFingerprint: sourceFingerprint,
        );
        final sidecarHint = await _readablePickerSourceHint(
          sourcePath,
          sidecarSourcePaths[sourcePath],
        );
        await _adoptPickerSourceSubtitles(item, sidecarHint);
        if (!skipImportSidecarWorkForTesting) {
          item.chapters = await MediaChapterProbe.probe(
            path,
            durationMs: durationMs,
          );
          await _prepareCompatiblePlaybackFile(item, saveLibrary: false);
        }
        item.hasProbedChapters = true;
        // The browser queue may remove a task while metadata is being probed.
        // The final synchronous commit must still belong to a live task.
        if (shouldContinue?.call() == false) {
          if (createdPrivateCopy) await _deleteFileIfExists(path);
          if (item.managedSubtitleAssets.isNotEmpty) {
            try {
              await TaskSubtitleStorageService(
                dataRootOverride: _dataRootDir,
              ).deleteTaskDirectory(id);
            } on FileSystemException {
              // The new card was never published; do not touch its source.
            }
          }
          break;
        }
        _videos[id] = item;
        if (item.type == MediaType.audio) {
          _audioSidecarHints[id] = sidecarHint ?? sourcePath;
        }
        if (parentId != null) {
          _collections[parentId]!.childrenIds.add(id);
        } else {
          _rootChildrenIds.add(id);
        }
        if (downloadContext != null) {
          _recordDownloadImport(id, downloadContext, sourceKind, const []);
        }
        newIds.add(id);
        if (!_samePath(filePaths[i], path)) {
          committedCacheCopies[filePaths[i]] = path;
        }
        if (activityBatchId != null) {
          noteImportedMedia(
            id,
            addedAtMs: DateTime.now().millisecondsSinceEpoch,
            batchId: activityBatchId,
          );
        }
        if (DateTime.now().difference(lastNotifyTime).inMilliseconds > 300) {
          notifyListeners();
          lastNotifyTime = DateTime.now();
        }
      }

      if (newIds.isEmpty) {
        if (activityBatchId != null) {
          abortImportBatch(activityBatchId);
          activityBatchId = null;
        }
        importStatus.value = "没有新文件需要导入";
        if (!skipImportSidecarWorkForTesting) {
          await Future.delayed(const Duration(seconds: 1));
        }
        return MediaImportExecutionResult(
          reusedVideoIds: List<String>.unmodifiable(reusedIds),
          failedCount: failedCount,
        );
      }

      if (activityBatchId != null) {
        final published = await completeImportBatch(
          activityBatchId,
          persist: false,
        );
        if (!published) {
          abortImportBatch(activityBatchId);
          activityBatchId = null;
        }
      }
      await _saveLibrary();
      if (downloadContext != null) _requireDurableDownloadImport();
      await _releaseCommittedImportCacheCopies(committedCacheCopies);
      notifyListeners();

      if (!skipImportSidecarWorkForTesting) {
        importStatus.value = "正在生成缩略图...";
        var current = 0;
        const int batchSize = 4;
        for (int i = 0; i < newIds.length; i += batchSize) {
          if (!isImporting.value) break;
          final end = (i + batchSize < newIds.length)
              ? i + batchSize
              : newIds.length;
          final batch = newIds.sublist(i, end);
          await Future.wait(
            batch.map((id) async {
              if (!isImporting.value) return;
              try {
                final item = _videos[id];
                if (item == null) return;
                if (item.type == MediaType.audio) {
                  await _resolveImportedAudioCover(
                    item,
                    sidecarHintPath: _audioSidecarHints.remove(id),
                    persist: false,
                  );
                  return;
                }
                item.thumbnailPath = await _generateThumbnail(
                  item.path,
                  videoId: item.id,
                );
              } catch (e) {
                debugPrint("Error processing metadata for $id: $e");
              }
            }),
          );
          current += batch.length;
          final progress = current / newIds.length;
          importProgress.value = progress;
          importStatus.value = "处理中: ${(progress * 100).toInt()}%";
        }
        await _saveLibrary();
        notifyListeners();
      }

      return MediaImportExecutionResult(
        createdVideoIds: List<String>.unmodifiable(newIds),
        reusedVideoIds: List<String>.unmodifiable(reusedIds),
        failedCount: failedCount,
        activityBatchId: activityBatchId,
      );
    } catch (e) {
      debugPrint("Import error: $e");
      importStatus.value = "导入出错: $e";
      if (activityBatchId != null) {
        abortImportBatch(activityBatchId);
      }
      if (downloadContext != null || e is ImportPlacementException) rethrow;
      return MediaImportExecutionResult(failedCount: failedCount + 1);
    } finally {
      _audioSidecarHints.clear();
      isImporting.value = false;
      importProgress.value = 0.0;
      importStatus.value = "";
      _importOperationActive = false;
    }
  }

  // Unified Recycle Bin Methods
  Future<void> moveToRecycleBin(List<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    _invalidateSizeCaches();
    final exportCandidates = <VideoItem>[];
    final detachedChildren = <String?, Set<String>>{};

    for (final id in ids.toSet()) {
      String? parentId;
      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        if (col.isRecycled) continue;
        col.isRecycled = true;
        col.recycleTime = now;
        parentId = col.parentId;
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        if (vid.isRecycled) continue;
        final selectedPaths = <String>[];
        if (vid.subtitlePath != null) {
          selectedPaths.add(vid.subtitlePath!);
        }
        if (vid.secondarySubtitlePath != null) {
          selectedPaths.add(vid.secondarySubtitlePath!);
        }
        vid.recycledSelectedSubtitlePaths = selectedPaths.isEmpty
            ? null
            : selectedPaths;
        // Preserve origin maps independently. Reconstructing this map from all
        // referenced subtitle paths would wrongly turn selected/local files
        // into download-associated subtitles after recycle-bin restore.
        vid.recycledAdditionalSubtitles = vid.additionalSubtitles == null
            ? null
            : Map<String, String>.from(vid.additionalSubtitles!);
        vid.recycledLocalSubtitles = vid.localSubtitles == null
            ? null
            : Map<String, String>.from(vid.localSubtitles!);
        if (Platform.isWindows &&
            !vid.isBilibiliExported &&
            _looksLikeBilibiliExportedFile(vid.path)) {
          exportCandidates.add(vid);
        }
        vid.isRecycled = true;
        vid.recycleTime = now;
        parentId = vid.parentId;
      } else {
        continue;
      }
      detachedChildren.putIfAbsent(parentId, () => <String>{}).add(id);
    }
    if (detachedChildren.isEmpty) return;
    // Scan each affected folder once, including large multi-card selections.
    for (final entry in detachedChildren.entries) {
      final children = entry.key == null
          ? _rootChildrenIds
          : _collections[entry.key]?.childrenIds;
      children?.removeWhere(entry.value.contains);
    }

    // Publish the whole batch before any preferences or storage work. Every
    // entry point can remove cards immediately even while a save is pending.
    notifyListeners();
    if (exportCandidates.isNotEmpty) {
      final customPath = await _getBilibiliCustomDownloadPath();
      if (customPath != null) {
        for (final item in exportCandidates) {
          if (p.isWithin(customPath, item.path)) item.isBilibiliExported = true;
        }
      }
    }
    await _saveLibrary();
  }

  Future<void> restoreFromRecycleBin(List<String> ids) async {
    // A running physical deletion cannot be undone. Queued deletions are not
    // locked and will re-check recycle state when they actually start.
    for (final pendingId in _permanentDeletionIds) {
      String? cursor = pendingId;
      final seen = <String>{};
      while (cursor != null && seen.add(cursor)) {
        if (ids.contains(cursor)) {
          throw const StorageUnavailableException('正在永久删除，请等待完成后再还原');
        }
        cursor = _videos[cursor]?.parentId ?? _collections[cursor]?.parentId;
      }
    }
    _invalidateSizeCaches();
    final selectedIds = ids.toSet();
    final restoredAncestors = <String>{};

    void attachToParent(String id, String? parentId) {
      final parent = _collections[parentId];
      if (parentId != null && parent == null) {
        _collections[id]?.parentId = null;
        _videos[id]?.parentId = null;
      }
      final children = parent?.childrenIds ?? _rootChildrenIds;
      if (!children.contains(id)) children.add(id);
    }

    void restoreAncestors(String? parentId) {
      if (parentId == null || !restoredAncestors.add(parentId)) return;
      final parent = _collections[parentId];
      if (parent == null) return;
      restoreAncestors(parent.parentId);
      if (!parent.isRecycled) return;

      // Restore only the directory structure needed by the selection. Freeze
      // its other contents in the bin before lifting implicit recycling.
      // An explicitly selected folder still restores its whole active subtree.
      if (!selectedIds.contains(parentId)) {
        for (final childId in _collectionChildIdsIncludingRecycled(parentId)) {
          final collection = _collections[childId];
          final video = _videos[childId];
          if (collection != null && !collection.isRecycled) {
            collection.isRecycled = true;
            collection.recycleTime = parent.recycleTime;
          } else if (video != null && !video.isRecycled) {
            video.isRecycled = true;
            video.recycleTime = parent.recycleTime;
          }
          parent.childrenIds.remove(childId);
        }
      }
      parent.isRecycled = false;
      parent.recycleTime = null;
      attachToParent(parent.id, parent.parentId);
    }

    for (var id in selectedIds) {
      String? parentId;

      restoreAncestors(_collections[id]?.parentId ?? _videos[id]?.parentId);

      if (_collections.containsKey(id)) {
        final col = _collections[id]!;
        col.isRecycled = false;
        col.recycleTime = null;
        parentId = col.parentId;
      } else if (_videos.containsKey(id)) {
        final vid = _videos[id]!;
        vid.isRecycled = false;
        vid.recycleTime = null;
        if (vid.recycledSelectedSubtitlePaths != null) {
          final paths = vid.recycledSelectedSubtitlePaths!;
          vid.subtitlePath = paths.isNotEmpty ? paths[0] : null;
          vid.secondarySubtitlePath = paths.length > 1 ? paths[1] : null;
          vid.recycledSelectedSubtitlePaths = null;
        }
        if (vid.recycledAdditionalSubtitles != null &&
            vid.recycledAdditionalSubtitles!.isNotEmpty) {
          vid.additionalSubtitles = Map<String, String>.from(
            vid.recycledAdditionalSubtitles!,
          );
          vid.recycledAdditionalSubtitles = null;
        }
        if (vid.recycledLocalSubtitles != null) {
          vid.localSubtitles = Map<String, String>.from(
            vid.recycledLocalSubtitles!,
          );
          vid.recycledLocalSubtitles = null;
        }
        parentId = vid.parentId;
      } else {
        continue;
      }

      attachToParent(id, parentId);
    }
    await _saveLibrary();
    notifyListeners();
  }

  final _recycleDeleteQueue = SerialTaskQueue();
  final Set<String> _permanentDeletionIds = {};

  @visibleForTesting
  Future<void> Function(VideoItem)? deleteVideoFilesOverrideForTesting;

  @visibleForTesting
  Future<void> Function(File)? beforeOwnedFileDeletionForTesting;

  Future<void> _deleteOwnedFile(File file) async {
    await beforeOwnedFileDeletionForTesting?.call(file);
    await file.delete();
  }

  Future<RecycleBinDeleteResult> deleteFromRecycleBin(
    List<String> ids, {
    void Function(int processed, int total)? onProgress,
  }) => _recycleDeleteQueue.enqueue(() async {
    _invalidateSizeCaches();
    final uniqueIds = ids.toSet().toList(growable: false);
    final deleted = <String>[];
    final failed = <String, String>{};
    final restored = <String>{};
    for (var i = 0; i < uniqueIds.length; i++) {
      final id = uniqueIds[i];
      final locked = <String>{};
      void collect(String candidate) {
        if (!locked.add(candidate)) return;
        if (_collections.containsKey(candidate)) {
          for (final child in _collectionChildIdsIncludingRecycled(candidate)) {
            collect(child);
          }
        }
      }

      collect(id);
      _permanentDeletionIds.addAll(locked);
      try {
        await _deleteRecycledEntry(id);
        deleted.add(id);
      } catch (error, stackTrace) {
        developer.log(
          'Permanent deletion incomplete',
          error: error,
          stackTrace: stackTrace,
        );
        if (error is _RecycleBinItemRestored) restored.add(id);
        failed[id] = error is _RecycleBinItemRestored
            ? '项目已恢复，未执行删除。'
            : '部分文件未能删除，请检查存储位置并停止使用相关文件后重试。';
      } finally {
        _permanentDeletionIds.removeAll(locked);
      }
      try {
        onProgress?.call(i + 1, uniqueIds.length);
      } catch (error) {
        developer.log(
          'Permanent deletion progress observer failed',
          error: error,
        );
      }
    }
    await _saveLibrary();
    notifyListeners();
    return RecycleBinDeleteResult(
      deletedIds: List.unmodifiable(deleted),
      failedIds: Map.unmodifiable(failed),
      saved: !hasPersistenceFailure,
      restoredIds: Set.unmodifiable(restored),
    );
  });

  Future<void> _deleteRecycledEntry(String id) async {
    if ((_collections.containsKey(id) || _videos.containsKey(id)) &&
        !isStorageItemRecycled(id)) {
      throw _RecycleBinItemRestored();
    }
    final collection = _collections[id];
    if (collection != null) {
      var incomplete = false;
      // Remove only successful descendants. A failed child's parent remains
      // addressable in the recycle bin, including independently recycled items.
      for (final childId in _collectionChildIdsIncludingRecycled(id).toList()) {
        try {
          await _deleteRecycledEntry(childId);
        } catch (_) {
          incomplete = true;
        }
      }
      if (incomplete) {
        throw const FileSystemException('Folder deletion incomplete');
      }
      final thumbnail = collection.thumbnailPath;
      if (thumbnail != null &&
          thumbnail.isNotEmpty &&
          _isInternalPath(thumbnail)) {
        final file = File(thumbnail);
        if (await file.exists() &&
            await _isSafeAppDataPath(thumbnail) &&
            !_isStoragePathReferencedByOtherItem(thumbnail, id)) {
          await _deleteOwnedFile(file);
        }
      }
      ThumbnailCacheService().evictFromCache(id);
      _deleteCollectionRecursive(id);
      return;
    }
    final video = _videos[id];
    if (video == null) return; // Idempotent retry after an earlier success.
    await deleteVideoFilesOverrideForTesting?.call(video);
    await _deleteVideoFiles(video, strict: true);
    _deleteVideo(id);
  }

  Future<void> _rememberBilibiliCover(VideoItem item) async {
    final bvid = bilibiliStreamCardBvid(item);
    final source = item.thumbnailPath;
    if (bvid == null || bvid.isEmpty || source == null || source.isEmpty) {
      return;
    }
    if (BilibiliCoverCache.isSharedCoverPath(source)) return;
    try {
      await BilibiliCoverCache(_dataRootDir).remember(bvid, source);
    } catch (error) {
      developer.log('Watch cover not kept', error: error);
    }
  }

  Future<void> _deleteVideoFiles(VideoItem vid, {bool strict = false}) async {
    var failed = false;
    // Copy the cover before anything else. Cache cleanup notifies listeners,
    // and the playlist rebuilds the row in that turn; the shared file has to
    // exist already or the new row is created without a picture.
    if (vid.thumbnailPath != null && _isBilibiliStreamItem(vid)) {
      await _rememberBilibiliCover(vid);
    }

    // Online playback has no media file at [vid.path]. Its complete cache is
    // owned by the card id and must be removed with the card itself.
    if (_isBilibiliStreamItem(vid)) {
      if (strict) {
        final outcome = await clearOnlineCacheForItem(vid.id);
        if (outcome != OnlineCacheClearStatus.cleared) {
          throw const FileSystemException(
            'Online cache is still in use or could not be deleted',
          );
        }
      } else {
        try {
          final materialization = _mediaMaterializationService;
          final cleared = materialization == null
              ? true
              : await materialization.clearCard(vid.id);
          if (cleared) await _clearRemainingOnlineCache(vid.id);
        } catch (e) {
          developer.log('Error deleting Bilibili stream cache', error: e);
        }
      }
    }

    // 清理缩略图缓存
    ThumbnailCacheService().evictFromCache(vid.id);

    // Managed compatibility copies live with the library until permanent
    // deletion (moving to the recycle bin intentionally keeps them).
    if (vid.playbackPath != null &&
        _isInternalPath(vid.playbackPath!) &&
        (vid.bilibiliDownloadPath == null ||
            !AppStorageService.samePath(
              vid.playbackPath!,
              vid.bilibiliDownloadPath!,
            ))) {
      try {
        final referencedElsewhere = _isStoragePathReferencedByOtherItem(
          vid.playbackPath!,
          vid.id,
        );
        final file = File(vid.playbackPath!);
        if (!referencedElsewhere &&
            await file.exists() &&
            await _isSafeAppDataPath(file.path)) {
          await _deleteOwnedFile(file);
        }
      } catch (e) {
        failed = true;
        developer.log('Error deleting compatible playback file', error: e);
      }
    }

    // 1. Delete Thumbnail. The shared copy was taken at the start of this
    // method, before listeners could rebuild the playlist row.
    if (vid.thumbnailPath != null) {
      try {
        final thumbnailPath = vid.thumbnailPath!;
        if (_isInternalPath(thumbnailPath) &&
            !BilibiliCoverCache.isSharedCoverPath(thumbnailPath)) {
          final file = File(thumbnailPath);
          if (await file.exists() &&
              await _isSafeAppDataPath(thumbnailPath) &&
              !_isThumbnailPathReferencedByOtherVideo(thumbnailPath, vid.id)) {
            await _deleteOwnedFile(file);
          }
        }
      } catch (e) {
        failed = true;
        developer.log('Error deleting thumbnail', error: e);
      }
    }

    // Include old in-app subtitle locations as well as this card's directory.
    // A shared legacy subtitle survives until its final card is removed.
    try {
      final storage = TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      );
      final paths = <String>{
        ...<String?>[
          vid.subtitlePath,
          vid.secondarySubtitlePath,
          vid.danmakuPath,
          ...?vid.additionalSubtitles?.values,
          ...?vid.localSubtitles?.values,
          ...?vid.recycledSelectedSubtitlePaths,
          ...?vid.recycledAdditionalSubtitles?.values,
          ...?vid.recycledLocalSubtitles?.values,
          ...vid.managedSubtitleAssets.expand((asset) => asset.allFilePaths),
        ].whereType<String>(),
      };
      final directory = await storage.taskDirectory(vid.id);
      if (await FileSystemEntity.type(directory.path, followLinks: false) ==
              FileSystemEntityType.directory &&
          await _isSafeAppDataPath(directory.path)) {
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) paths.add(entity.path);
        }
      }
      for (final path in paths) {
        // Shared by every card of this Bilibili part. Removing one card must
        // not take the subtitle away from the others, or from the next watch.
        if (await _isSharedBilibiliSubtitlePath(path)) continue;
        if (_isInternalPath(path) &&
            !_isStoragePathReferencedByOtherItem(path, vid.id)) {
          final file = File(path);
          if (await FileSystemEntity.type(path, followLinks: false) ==
                  FileSystemEntityType.file &&
              await _isSafeAppDataPath(path) &&
              await file.exists()) {
            await _deleteOwnedFile(file);
          }
        }
      }
      if (await directory.exists() &&
          await _isSafeAppDataPath(directory.path) &&
          await directory.list(followLinks: false).isEmpty) {
        await directory.delete();
      }
    } catch (e) {
      failed = true;
      developer.log('Error deleting subtitles', error: e);
    }

    try {
      await ChapterThumbnailService.instance.deleteForVideo(vid.id);
    } catch (e) {
      failed = true;
      developer.log('Error deleting chapter thumbnails', error: e);
    }

    try {
      final spritesRoot = p.join(
        _dataRootDir.path,
        BilibiliVideoShotService.directoryName,
        vid.id,
      );
      final shared = _storageFileOwners.entries.any(
        (entry) =>
            p.isWithin(spritesRoot, entry.key) &&
            entry.value.any((id) => id != vid.id),
      );
      if (!shared) {
        await BilibiliVideoShotService.instance.deleteForVideo(
          vid.id,
          dataRootOverride: _dataRootDir,
        );
      }
    } catch (e) {
      failed = true;
      developer.log('Error deleting Bilibili video-shot sprites', error: e);
    }

    // OCR frames are disposable working data and never participate in task
    // recovery. Permanently deleting a video card must also remove any frames
    // left by an interrupted or crashed OCR job for that video.
    try {
      final safeVideoId = vid.id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final ocrTemp = Directory(
        p.join(_dataRootDir.path, 'ocr_temp', safeVideoId),
      );
      if (await ocrTemp.exists()) await ocrTemp.delete(recursive: true);
    } catch (e) {
      failed = true;
      developer.log('Error deleting OCR temporary frames', error: e);
    }

    if (strict && failed) {
      throw const FileSystemException(
        'Owned supporting files could not all be deleted',
      );
    }

    // 3. Delete Video File (Only if it's inside app storage). Online cards use
    // a URI marker, so their card-owned cache was handled above and must never
    // be passed through local-file cleanup.
    if (!_isBilibiliStreamItem(vid) && !_isCloudDriveItem(vid)) {
      try {
        bool shouldDelete = await _isBilibiliExportedCandidate(vid);

        // Check 1: Internal Doc Dir (App Data)
        if (_isInternalPath(vid.path)) {
          shouldDelete = true;
        }

        // Check 2: Internal Temp Dir (Cache)
        if (!shouldDelete) {
          shouldDelete = await _isDisposableMediaCachePath(vid.path);
        }

        // Check 3: Android External Storage (Android/data/pkg/files & cache)
        if (!shouldDelete && Platform.isAndroid) {
          // External Files
          final extDir = await getExternalStorageDirectory();
          if (extDir != null && p.isWithin(extDir.path, vid.path)) {
            shouldDelete = true;
          }

          // External Caches
          if (!shouldDelete) {
            final extCacheDirs = await getExternalCacheDirectories();
            if (extCacheDirs != null) {
              for (var dir in extCacheDirs) {
                if (p.isWithin(dir.path, vid.path)) {
                  shouldDelete = true;
                  break;
                }
              }
            }
          }

          // Files inside another app's Bilibili download folder are external
          // originals. Only explicit app-export ownership permits deletion.
        }

        if (shouldDelete) {
          final file = File(vid.path);
          if (await file.exists() &&
              await FileSystemEntity.type(vid.path, followLinks: false) ==
                  FileSystemEntityType.file &&
              (!_isInternalPath(vid.path) ||
                  await _isSafeAppDataPath(vid.path)) &&
              !_isMediaFilePathReferencedByOtherVideo(vid.path, vid.id)) {
            await _deleteOwnedFile(file);
            debugPrint("Deleted internal video file: ${vid.path}");
          }
        }
      } catch (e) {
        failed = true;
        debugPrint("Error deleting internal video: $e");
      }
    }
    if (strict && failed) {
      throw const FileSystemException('Owned files could not all be deleted');
    }
  }

  Future<void> _clearRemainingOnlineCache(String itemId) async {
    final streaming = _bilibiliStreamingService;
    if (streaming != null) {
      await streaming.clearCacheForItem(itemId);
    } else {
      await BilibiliStreamingService.clearCacheForItemOnDisk(itemId);
    }
    final report = streaming != null
        ? await streaming.inspectItemCache(itemId)
        : await BilibiliStreamingService.inspectCacheForItem(itemId);
    if (report.fileCount > 0) {
      await _mediaMaterializationService?.markCardForDeletion(itemId);
    }
    notifyOnlineCacheChanged(itemId);
  }

  /// 按卡片统一清除在线视频缓存：素材缓存（合成/OCR/转写下载的轨道与可
  /// 播放文件）+ 播放网关缓存。正在使用的素材会转为延迟删除。
  bool get hasOnlineCacheStorageUse =>
      _mediaMaterializationService?.hasActiveStorageUse ?? false;

  Future<OnlineCacheClearStatus> clearOnlineCacheForItem(String videoId) async {
    final item = _videos[videoId];
    if (item == null || !_isBilibiliStreamItem(item)) {
      return OnlineCacheClearStatus.cleared;
    }
    try {
      final materialization = _mediaMaterializationService;
      final cleared = await materialization?.clearCard(videoId) ?? true;
      if (!cleared) {
        // The gateway directory also contains materialized tracks. Never
        // bypass their active lease by recursively deleting that directory.
        return materialization!.isCardInUse(videoId)
            ? OnlineCacheClearStatus.deferred
            : OnlineCacheClearStatus.failed;
      }
      await _clearRemainingOnlineCache(videoId);
      _invalidateVideoSizeCache(videoId);
      final remaining = _bilibiliStreamingService != null
          ? await _bilibiliStreamingService!.inspectItemCache(
              videoId,
              strict: true,
            )
          : await BilibiliStreamingService.inspectCacheForItem(
              videoId,
              strict: true,
            );
      return remaining.fileCount == 0
          ? OnlineCacheClearStatus.cleared
          : OnlineCacheClearStatus.failed;
    } catch (error, stackTrace) {
      developer.log(
        'Online cache clear failed',
        error: error,
        stackTrace: stackTrace,
      );
      return OnlineCacheClearStatus.failed;
    }
  }

  /// 按卡片分类统计在线视频缓存（素材文件 vs 播放网关缓存）。
  Future<BilibiliItemCacheBreakdown?> inspectOnlineCacheBreakdown(
    String videoId, {
    bool throwOnError = false,
  }) async {
    final item = _videos[videoId];
    if (item == null || !_isBilibiliStreamItem(item)) return null;
    try {
      return await BilibiliStreamingService.inspectItemCacheBreakdown(
        videoId,
        cacheDirectory: await _bilibiliStreamingService
            ?.resolveCacheDirectory(),
        strict: throwOnError,
      );
    } catch (_) {
      if (throwOnError) rethrow;
      return null;
    }
  }

  void _deleteCollectionRecursive(String id) {
    final col = _collections[id];
    if (col == null) return;

    // Delete children
    for (var childId in _collectionChildIdsIncludingRecycled(id)) {
      if (_collections.containsKey(childId)) {
        _deleteCollectionRecursive(childId);
      } else {
        _deleteVideo(childId);
      }
    }

    // Remove from parent
    if (col.parentId != null && _collections.containsKey(col.parentId)) {
      _collections[col.parentId]!.childrenIds.remove(id);
    } else if (col.parentId == null) {
      _rootChildrenIds.remove(id);
    }

    _collections.remove(id);
    _storageFileOwnersIndex = null;
    _purgeActivityForDeletedCollection(id);
  }

  void _deleteVideo(String id) {
    final vid = _videos[id];
    if (vid == null) return;

    if (vid.parentId != null && _collections.containsKey(vid.parentId)) {
      _collections[vid.parentId]!.childrenIds.remove(id);
    } else if (vid.parentId == null) {
      _rootChildrenIds.remove(id);
    }
    _videos.remove(id);
    _storageFileOwnersIndex = null;
    _purgeActivityForDeletedMedia(id);
  }

  // Move item to another collection (or root if targetCollectionId is null)
  Future<void> moveItemToCollection(
    String itemId,
    String? targetCollectionId,
  ) async {
    if (_collections[targetCollectionId]?.isPodcast == true) return;
    if (itemId == targetCollectionId) return;

    // 1. Identify Item
    VideoCollection? col;
    VideoItem? vid;
    String? currentParentId;

    if (_collections.containsKey(itemId)) {
      col = _collections[itemId];
      currentParentId = col!.parentId;

      // Cycle Check: Cannot move a folder into itself or its descendants
      if (targetCollectionId != null &&
          _isDescendant(targetCollectionId, itemId)) {
        return; // Invalid move
      }
    } else if (_videos.containsKey(itemId)) {
      vid = _videos[itemId];
      currentParentId = vid!.parentId;
    } else {
      return; // Item not found
    }

    // Check if already in target
    if (currentParentId == targetCollectionId) return;

    // 2. Remove from old location
    if (currentParentId != null && _collections.containsKey(currentParentId)) {
      _collections[currentParentId]!.childrenIds.remove(itemId);
    } else if (currentParentId == null) {
      _rootChildrenIds.remove(itemId);
    }

    // 3. Add to new location
    if (targetCollectionId != null &&
        _collections.containsKey(targetCollectionId)) {
      final target = _collections[targetCollectionId]!;
      if (!target.childrenIds.contains(itemId)) {
        target.childrenIds.add(itemId);
      }
      // Update item parent pointer
      if (col != null) col.parentId = targetCollectionId;
      if (vid != null) vid.parentId = targetCollectionId;
    } else if (targetCollectionId == null) {
      // Move to Root
      if (!_rootChildrenIds.contains(itemId)) {
        _rootChildrenIds.add(itemId);
      }
      // Update item parent pointer
      if (col != null) col.parentId = null;
      if (vid != null) vid.parentId = null;
    }

    await _saveLibrary();
    notifyListeners();
  }

  // Batch Move
  Future<void> moveItemsToCollection(
    List<String> itemIds,
    String? targetCollectionId,
  ) async {
    if (_collections[targetCollectionId]?.isPodcast == true) return;
    bool changed = false;
    for (var itemId in itemIds) {
      if (itemId == targetCollectionId) continue;

      // 1. Identify Item
      VideoCollection? col;
      VideoItem? vid;
      String? currentParentId;

      if (_collections.containsKey(itemId)) {
        col = _collections[itemId];
        currentParentId = col!.parentId;
        // Cycle Check
        if (targetCollectionId != null &&
            _isDescendant(targetCollectionId, itemId)) {
          continue;
        }
      } else if (_videos.containsKey(itemId)) {
        vid = _videos[itemId];
        currentParentId = vid!.parentId;
      } else {
        continue;
      }

      if (currentParentId == targetCollectionId) continue;

      // 2. Remove
      if (currentParentId != null &&
          _collections.containsKey(currentParentId)) {
        _collections[currentParentId]!.childrenIds.remove(itemId);
      } else if (currentParentId == null) {
        _rootChildrenIds.remove(itemId);
      }

      // 3. Add
      if (targetCollectionId != null &&
          _collections.containsKey(targetCollectionId)) {
        final target = _collections[targetCollectionId]!;
        if (!target.childrenIds.contains(itemId)) {
          target.childrenIds.add(itemId);
        }
        if (col != null) col.parentId = targetCollectionId;
        if (vid != null) vid.parentId = targetCollectionId;
      } else if (targetCollectionId == null) {
        if (!_rootChildrenIds.contains(itemId)) {
          _rootChildrenIds.add(itemId);
        }
        if (col != null) col.parentId = null;
        if (vid != null) vid.parentId = null;
      }
      changed = true;
    }

    if (changed) {
      await _saveLibrary();
      notifyListeners();
    }
  }

  bool _isDescendant(String potentialDescendantId, String ancestorId) {
    if (potentialDescendantId == ancestorId) return true;

    final col = _collections[potentialDescendantId];
    if (col == null) {
      return false; // Should not happen if ID is valid collection
    }
    if (col.parentId == null) return false;

    return _isDescendant(col.parentId!, ancestorId);
  }

  // Reorder (Only for manual ordering within a parent)
  Future<void> reorderItems(
    String? parentId,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex == newIndex) return;

    // Logic:
    // 1. Get visible items using getContents(parentId) logic.
    // 2. Identify the item being moved (itemToMove).
    // 3. Identify the target insert position.

    // Step 1: Visible Items
    final visibleItems = getContents(parentId);
    if (oldIndex < 0 ||
        newIndex < 0 ||
        oldIndex >= visibleItems.length ||
        newIndex >= visibleItems.length) {
      return;
    }

    final itemToMove = visibleItems[oldIndex];
    final String itemToMoveId = (itemToMove as dynamic).id;

    // Step 2: Determine Insert Before ID
    // If moving down (old < new), we usually want to place AFTER the target.
    // If moving up (old > new), we usually want to place BEFORE the target.

    int targetLookupIndex;
    if (oldIndex < newIndex) {
      targetLookupIndex = newIndex + 1;
    } else {
      targetLookupIndex = newIndex;
    }

    String? insertBeforeId; // If null, insert at end
    if (targetLookupIndex < visibleItems.length) {
      final itemAfter = visibleItems[targetLookupIndex];
      insertBeforeId = (itemAfter as dynamic).id;
    }

    // Master List Reference
    List<String> masterList;
    if (parentId == null) {
      masterList = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return;
      masterList = parent.childrenIds;
    }

    // Step 3: Remove
    final originalIndex = masterList.indexOf(itemToMoveId);
    if (originalIndex == -1) return;
    _markDownloadOrderManual(parentId, [itemToMoveId]);
    masterList.removeAt(originalIndex);

    // Step 4: Insert
    if (insertBeforeId == null) {
      masterList.add(itemToMoveId);
    } else {
      int targetIndex = masterList.indexOf(insertBeforeId);
      if (targetIndex == -1) {
        masterList.add(itemToMoveId);
      } else {
        masterList.insert(targetIndex, itemToMoveId);
      }
    }

    await _saveLibrary();
    notifyListeners();
  }

  // Batch Reorder
  // draggedItemIndex: the index of the item the user is actively dragging
  // targetIndex: the index of the drop target
  Future<void> reorderMultipleItems(
    String? parentId,
    List<String> itemIds,
    int draggedItemIndex,
    int targetIndex,
  ) async {
    if (itemIds.isEmpty) return;

    // 1. Get Visible Items
    final visibleItems = getContents(parentId);
    if (draggedItemIndex < 0 ||
        targetIndex < 0 ||
        draggedItemIndex >= visibleItems.length ||
        targetIndex >= visibleItems.length) {
      return;
    }
    final selected = itemIds.toSet();
    final movingIds = [
      for (final item in visibleItems)
        if (selected.contains((item as dynamic).id))
          (item as dynamic).id as String,
    ];
    if (movingIds.isEmpty ||
        !movingIds.contains((visibleItems[draggedItemIndex] as dynamic).id) ||
        movingIds.contains((visibleItems[targetIndex] as dynamic).id)) {
      return;
    }

    // 2. Identify Target Insert Position
    // We use the same logic as single reorder:
    // If dragging down (draggedItemIndex < targetIndex), insert AFTER target.
    // If dragging up (draggedItemIndex > targetIndex), insert BEFORE target.

    int targetLookupIndex;
    if (draggedItemIndex < targetIndex) {
      targetLookupIndex = targetIndex + 1;
    } else {
      targetLookupIndex = targetIndex;
    }
    while (targetLookupIndex < visibleItems.length &&
        movingIds.contains((visibleItems[targetLookupIndex] as dynamic).id)) {
      targetLookupIndex++;
    }

    String? insertBeforeId;
    if (targetLookupIndex < visibleItems.length) {
      final itemAfter = visibleItems[targetLookupIndex];
      insertBeforeId = (itemAfter as dynamic).id;
    }

    // Master List Reference
    List<String> masterList;
    if (parentId == null) {
      masterList = _rootChildrenIds;
    } else {
      final parent = _collections[parentId];
      if (parent == null) return;
      masterList = parent.childrenIds;
    }

    // 3. Remove ALL items to be moved
    // We must do this carefully. If we remove items, the indices change.
    // But we are using `insertBeforeId` which is stable (unless it's one of the moving items).
    // If `insertBeforeId` is one of the moving items, our target logic is flawed.
    // However, in a valid drag, you don't drag a selection onto itself.
    // But targetLookupIndex logic might pick a moving item if it's adjacent.

    // Optimization: If we are dragging a block [A, B] and dropping on C.
    // We want to insert [A, B] relative to C.
    // C should not be in itemIds.

    // Filter out itemIds from masterList
    _markDownloadOrderManual(parentId, movingIds);
    masterList.removeWhere((id) => movingIds.contains(id));

    // 4. Insert
    if (insertBeforeId == null) {
      masterList.addAll(movingIds);
    } else {
      // Find where to insert
      // Note: insertBeforeId might have been removed if it was in itemIds?
      // No, because we can't drag onto a selected item (usually).
      // But if we selected A and B, and dragged A onto B... well, that's a no-op.

      int insertIndex = masterList.indexOf(insertBeforeId);
      if (insertIndex == -1) {
        // Fallback: append
        masterList.addAll(movingIds);
      } else {
        masterList.insertAll(insertIndex, movingIds);
      }
    }

    await _saveLibrary();
    notifyListeners();
  }

  Future<String?> _generateThumbnail(
    String videoPath, {
    String? videoId,
    String? sidecarHintPath,
    bool allowFfmpegFallback = true,
  }) async {
    if (!communityMediaIsLocal(videoPath)) return null;
    // Audio: extract embedded cover art (album art)
    if (_detectMediaType(videoPath) == MediaType.audio) {
      return await _extractAudioCoverArt(
        videoPath,
        videoId: videoId,
        sidecarHintPath: sidecarHintPath,
        allowFfmpegFallback: allowFfmpegFallback,
      );
    }

    // Desktop Process ffmpeg (Windows + Linux; video_thumbnail has no Linux plugin)
    if (FFmpegUtils.preferSystemFfmpeg || Platform.isLinux) {
      return await _generateThumbnailWindows(videoPath, videoId: videoId);
    }

    // iOS: Use FFmpeg for better compatibility with gallery videos
    if (Platform.isIOS) {
      return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
    }

    // Android and other platforms: use the system thumbnail path first. Some
    // Android MediaMetadataRetriever implementations advertise AV1 support but
    // fail while extracting a 4K frame, so Android gets a software FFmpeg
    // fallback below. Also catch MissingPluginException on any platform.
    try {
      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }

      final outPath = _thumbnailOutputPath(videoPath, videoId: videoId);
      final outFile = File(outPath);
      if (await outFile.exists() && await outFile.length() > 0) {
        return outPath;
      }

      final tempPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
        thumbnailPath: thumbDir.path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 200, // Optimize size
        quality: 75,
      );
      if (tempPath == null) {
        if (Platform.isAndroid) {
          return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
        }
        return null;
      }

      final tempFile = File(tempPath);
      if (!await tempFile.exists() || await tempFile.length() <= 0) {
        if (Platform.isAndroid) {
          return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
        }
        return null;
      }

      if (!_samePath(tempPath, outPath)) {
        await tempFile.copy(outPath);
        try {
          await tempFile.delete();
        } catch (_) {}
      }
      return outPath;
    } on MissingPluginException catch (e) {
      developer.log(
        'Thumbnail MissingPluginException, falling back to ffmpeg',
        error: e,
        name: 'library.thumbnail',
      );
      return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
    } catch (e) {
      developer.log('Thumbnail error', error: e);
      if (Platform.isAndroid) {
        return await _generateThumbnailFFmpeg(videoPath, videoId: videoId);
      }
      return null;
    }
  }

  /// 使用 FFmpeg 生成缩略图（用于 iOS 和其他平台）
  Future<FFmpegSession?> _executeFfmpegWithTimeout(
    List<String> arguments,
    Duration timeout,
  ) async {
    // Linux: FFmpeg Kit .so missing — callers must use Process via preferSystemFfmpeg.
    if (FFmpegUtils.preferSystemFfmpeg) {
      developer.log(
        'Skipped FFmpegKit on desktop system-ffmpeg path',
        name: 'library.ffmpeg',
      );
      return null;
    }
    final completer = Completer<FFmpegSession>();
    FFmpegSession? runningSession;
    var timedOut = false;
    runningSession = await FFmpegKit.executeWithArgumentsAsync(arguments, (
      session,
    ) {
      if (!timedOut && !completer.isCompleted) {
        completer.complete(session);
      }
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      try {
        await runningSession.cancel();
      } catch (_) {}
      developer.log(
        'FFmpeg task timed out after ${timeout.inSeconds}s',
        name: 'library.ffmpeg',
      );
      return null;
    }
  }

  Future<String?> _generateThumbnailFFmpeg(
    String videoPath, {
    String? videoId,
  }) async {
    // Linux/Windows: FFmpegKit unavailable or prefer Process — reuse CLI path.
    if (FFmpegUtils.preferSystemFfmpeg || Platform.isLinux) {
      return await _generateThumbnailWindows(videoPath, videoId: videoId);
    }
    try {
      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }

      final outPath = _thumbnailOutputPath(videoPath, videoId: videoId);

      // Check if thumbnail already exists
      final outFile = File(outPath);
      if (await outFile.exists() && await outFile.length() > 0) {
        return outPath;
      }

      // Seek ~15% in (min 5s) to avoid black intros; see thumbnailSeekSeconds.
      final durationMs = await _probeMediaDurationMs(videoPath);
      final seekSec = thumbnailSeekSeconds(durationMs: durationMs);
      final session = await _executeFfmpegWithTimeout(<String>[
        '-y',
        '-ss',
        seekSec.toStringAsFixed(3),
        '-i',
        videoPath,
        '-vframes',
        '1',
        '-vf',
        'scale=-1:200',
        '-q:v',
        '2',
        outPath,
      ], const Duration(seconds: 30));

      final returnCode = await session?.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('FFmpeg thumbnail generated: $outPath');
          return outPath;
        }
      }

      // If failed, try without seek (some videos might be very short)
      final session2 = await _executeFfmpegWithTimeout(<String>[
        '-y',
        '-i',
        videoPath,
        '-vframes',
        '1',
        '-vf',
        'scale=-1:200',
        '-q:v',
        '2',
        outPath,
      ], const Duration(seconds: 20));

      final returnCode2 = await session2?.getReturnCode();

      if (ReturnCode.isSuccess(returnCode2)) {
        if (await outFile.exists() && await outFile.length() > 0) {
          developer.log('FFmpeg thumbnail generated (fallback): $outPath');
          return outPath;
        }
      }

      developer.log('FFmpeg thumbnail generation failed for: $videoPath');
      return null;
    } catch (e) {
      developer.log('FFmpeg thumbnail error', error: e);
      return null;
    }
  }

  /// 提取音频文件的嵌入式封面，没有内嵌图时再找同目录的 cover/folder 图片。
  ///
  /// 优先直接解析 covr、ID3、FLAC、Ogg、APE、WMA，保留原始图片。ffmpeg 只在
  /// 文件里只剩 attached picture 流、标签里没有图片时才转码。
  Future<String?> _extractAudioCoverArt(
    String audioPath, {
    String? videoId,
    String? sidecarHintPath,
    bool allowFfmpegFallback = true,
  }) async {
    try {
      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) {
        await thumbDir.create(recursive: true);
      }

      final outPath = _thumbnailOutputPath(audioPath, videoId: videoId);
      final outFile = File(outPath);
      if (await _isDisplayableImageFile(outPath)) {
        return outPath;
      }
      if (await outFile.exists()) {
        await _deleteFileIfExists(outPath);
      }

      final written = await AudioCoverArt.writeCover(
        audioPath: audioPath,
        outputPath: outPath,
        sidecarHintPaths: <String>[
          if (sidecarHintPath != null && sidecarHintPath.isNotEmpty)
            sidecarHintPath,
        ],
      );
      if (written != null && await _isDisplayableImageFile(written)) {
        developer.log('音频封面已写入: $written', name: 'library.thumbnail');
        return written;
      }

      if (!allowFfmpegFallback) return null;
      final extracted = await _extractAttachedPictureWithFfmpeg(
        audioPath,
        outPath,
      );
      if (extracted != null) {
        developer.log(
          '音频封面已由 ffmpeg 抽出: $extracted',
          name: 'library.thumbnail',
        );
      }
      return extracted;
    } catch (e) {
      developer.log('Audio cover art extraction error', error: e);
      return null;
    }
  }

  /// Copies an attached-picture stream when the container has no cover tag.
  ///
  /// `-c copy` keeps the original JPEG. Re-encoding is only the fallback,
  /// because forcing mjpeg rejects full-range yuvj420p covers on some builds.
  Future<String?> _extractAttachedPictureWithFfmpeg(
    String audioPath,
    String outPath,
  ) async {
    final attempts = <List<String>>[
      <String>[
        '-y',
        '-i',
        audioPath,
        '-map',
        '0:v:0',
        '-c',
        'copy',
        '-frames:v',
        '1',
        outPath,
      ],
      <String>[
        '-y',
        '-i',
        audioPath,
        '-map',
        '0:v:0',
        '-frames:v',
        '1',
        '-vf',
        'scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuvj420p',
        '-q:v',
        '3',
        outPath,
      ],
    ];

    if (FFmpegUtils.preferSystemFfmpeg) {
      if (!await FFmpegUtils.isAvailable) {
        developer.log(FFmpegUtils.missingBinaryUserMessage);
        return null;
      }
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      for (final args in attempts) {
        try {
          await _runCliProcessWithTimeout(
            ffmpegPath,
            args,
            const Duration(seconds: 20),
          );
        } catch (_) {}
        if (await _isDisplayableImageFile(outPath)) return outPath;
        await _deleteFileIfExists(outPath);
      }
      return null;
    }

    for (final args in attempts) {
      final session = await _executeFfmpegWithTimeout(
        args,
        const Duration(seconds: 20),
      );
      final returnCode = await session?.getReturnCode();
      if (ReturnCode.isSuccess(returnCode) &&
          await _isDisplayableImageFile(outPath)) {
        return outPath;
      }
      await _deleteFileIfExists(outPath);
    }
    return null;
  }

  Future<int?> _runCliProcessWithTimeout(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    final process = await Process.start(executable, arguments);
    final stdoutDrain = process.stdout.drain<void>();
    final stderrDrain = process.stderr.drain<void>();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      await Future.wait<void>([stdoutDrain, stderrDrain]);
      return exitCode;
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await Future.wait<void>([
          stdoutDrain.timeout(const Duration(seconds: 1)),
          stderrDrain.timeout(const Duration(seconds: 1)),
        ]);
      } catch (_) {}
      return null;
    }
  }

  Future<String?> _generateThumbnailWindows(
    String videoPath, {
    String? videoId,
  }) async {
    try {
      if (!await FFmpegUtils.isAvailable) {
        developer.log(FFmpegUtils.missingBinaryUserMessage);
        return null;
      }
      final ffmpegPath = await FFmpegUtils.ffmpegPath;
      if (Platform.isWindows &&
          ffmpegPath != 'ffmpeg' &&
          ffmpegPath != 'ffmpeg.exe' &&
          !await File(ffmpegPath).exists()) {
        developer.log("FFmpeg not found at $ffmpegPath");
        return null;
      }

      final thumbDir = Directory(p.join(_dataRootDir.path, 'thumbnails'));
      if (!await thumbDir.exists()) await thumbDir.create(recursive: true);

      final outPath = _thumbnailOutputPath(videoPath, videoId: videoId);

      // 1. Try to extract embedded cover art
      // -map 0:v selects all video streams
      // -map -0:V excludes "real" video streams (leaving attached pictures)
      try {
        await _runCliProcessWithTimeout(ffmpegPath, [
          '-y',
          '-i',
          videoPath,
          '-map',
          '0:v',
          '-map',
          '-0:V',
          '-c',
          'copy',
          outPath,
        ], const Duration(seconds: 5));

        if (await File(outPath).exists() && await File(outPath).length() > 0) {
          return outPath;
        }
      } catch (e) {
        // Continue to fallback
      }

      // 2. Fallback: frame at ~15% duration (min 5s) to avoid black intros
      final durationMs = await _probeMediaDurationMs(videoPath);
      final seekSec = thumbnailSeekSeconds(durationMs: durationMs);
      await _runCliProcessWithTimeout(ffmpegPath, [
        '-y',
        '-ss',
        seekSec.toStringAsFixed(3),
        '-i',
        videoPath,
        '-vframes',
        '1',
        '-vf',
        'scale=-1:200', // Resize to height 200px to optimize speed and size
        '-q:v',
        '2', // High quality JPEG
        outPath,
      ], const Duration(seconds: 15));

      if (await File(outPath).exists() && await File(outPath).length() > 0) {
        return outPath;
      }

      // Short / odd files: last resort at t=0
      if (seekSec > 0) {
        await _runCliProcessWithTimeout(ffmpegPath, [
          '-y',
          '-i',
          videoPath,
          '-vframes',
          '1',
          '-vf',
          'scale=-1:200',
          '-q:v',
          '2',
          outPath,
        ], const Duration(seconds: 15));
        if (await File(outPath).exists() && await File(outPath).length() > 0) {
          return outPath;
        }
      }
    } catch (e) {
      developer.log('Windows Thumbnail error', error: e);
    }
    return null;
  }

  bool _requiresWindowsThumbnailRepair(String? thumbnailPath) {
    if (!Platform.isWindows) {
      return false;
    }
    final normalized = thumbnailPath?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) {
      return false;
    }
    return normalized.endsWith('.webp');
  }

  Future<int> _probeMediaDurationMs(String mediaPath) async {
    if (!communityMediaIsLocal(mediaPath)) return 0;
    final override = probeMediaDurationOverrideForTesting;
    if (override != null) {
      return override(mediaPath);
    }
    if (skipImportSidecarWorkForTesting) {
      return 0;
    }
    // Bulk imports avoid constructing a VideoPlayerController per file. The
    // native probe has its own cancellation and this outer timeout is a final
    // guard against plugin/channel failures.
    try {
      return await MediaDurationProbe.probeDurationMs(
        mediaPath,
        allowVideoPlayerFallback: false,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          developer.log('媒体时长探测超时: $mediaPath', name: 'library.duration_probe');
          return 0;
        },
      );
    } catch (e) {
      developer.log(
        '媒体时长探测失败: $mediaPath',
        error: e,
        name: 'library.duration_probe',
      );
      return 0;
    }
  }

  /// Lightweight progress update: only updates in-memory value and schedules
  /// a debounced save. Does NOT trigger notifyListeners or full serialization
  /// on every call, which was the primary cause of UI jank during playback.
  Future<void> updateVideoProgress(String id, int positionMs) async {
    final item = _videos[id];
    if (item != null) {
      item.lastPositionMs = positionMs;
      for (final peer in _cloudPlaybackPeers(id)) {
        peer.lastPositionMs = positionMs;
      }
      // A watch-only card is never saved; its progress goes to observers.
      // Its lastUpdated stays at the creation time, which the clean-up uses
      // to tell a card that is about to open from one that was just closed.
      if (!item.isTransient) {
        item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
        _scheduleDebouncedSave();
      }
      for (final observer in List<LibraryProgressObserver>.of(
        _progressObservers,
      )) {
        try {
          observer(item, positionMs);
        } catch (error) {
          developer.log('Progress observer failed', error: error);
        }
      }
    }
  }

  /// Applies a remote checkpoint without reporting it as fresh local playback.
  /// Import dates, pins, hidden state and local media paths stay device-owned.
  Future<void> applySyncedPlaybackProgress({
    required String mediaId,
    required int positionMs,
    required bool completed,
    required bool continueEnrolled,
    required int accumulatedWatchMs,
    int? lastPlayedAtMs,
    bool persist = true,
  }) async {
    final item = _libraryVideo(mediaId);
    if (item == null || item.isRecycled || !_canMutateActivity) return;
    item.lastPositionMs = item.durationMs > 0
        ? positionMs.clamp(0, item.durationMs)
        : positionMs.clamp(0, 315576000000);
    final record = _activity.ensureMedia(mediaId);
    record.completed = completed;
    record.continueEnrolled = continueEnrolled;
    record.lastPlayedAtMs = lastPlayedAtMs;
    record.accumulatedWatchMs = accumulatedWatchMs.clamp(0, 315576000000);
    if (item.sourceRef?.podcast != null) {
      PodcastPlaybackHooks.syncedProgress?.call(
        item,
        positionMs,
        completed,
        lastPlayedAtMs,
      );
    }
    for (final peer in _cloudPlaybackPeers(mediaId)) {
      peer.lastPositionMs = item.lastPositionMs;
    }
    _shareCloudActivity(mediaId);
    if (persist) await _persistActivity(notifyLibrary: true);
  }

  /// Lightweight duration update: only updates in-memory value and schedules
  /// a debounced save. Does NOT trigger notifyListeners on every call.
  Future<void> updateVideoDuration(String id, int durationMs) async {
    final item = _videos[id];
    if (item != null && item.durationMs != durationMs) {
      item.durationMs = durationMs;
      for (final peer in _cloudPlaybackPeers(id)) {
        peer.durationMs = durationMs;
      }
      _scheduleDebouncedSave();
    }
  }

  Future<void> saveProgress() async {
    await _saveLibrary();
  }

  /// Persists the stable sidecar location before a danmaku refresh starts.
  /// A missing file at this path is harmless and lets an interrupted refresh
  /// retry without leaving an unreferenced sidecar behind.
  Future<bool> updateVideoDanmakuPath(
    String videoId,
    String danmakuPath,
  ) async {
    final item = _videos[videoId];
    if (item == null) return false;
    if (item.danmakuPath == danmakuPath) return true;
    item.danmakuPath = danmakuPath;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
    return true;
  }

  /// Online playback followed a replaced part. Persist the cid so the manual
  /// refresh and the next automatic one stay on the video that is playing.
  Future<bool> updateVideoSourceCid(String videoId, int cid) async {
    final item = _videos[videoId];
    final source = item?.sourceRef;
    if (item == null || source == null) return false;
    if (source.cid == cid) return true;
    item.bilibiliDownloadPath = null;
    item.sourceRef = source.copyWith(cid: cid);
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
    return true;
  }

  Future<void> updateVideoSubtitles(
    String videoId,
    String? subtitlePath,
    bool isCached, {
    String? secondarySubtitlePath,
    bool isSecondaryCached = false,
    bool Function()? shouldApply,
  }) async {
    final item = _videos[videoId];
    if (item != null) {
      final oldPrimaryPath = item.subtitlePath;
      final oldSecondaryPath = item.secondarySubtitlePath;
      final oldPrimaryWasCached = item.isSubtitleCached;
      final oldSecondaryWasCached = item.isSecondarySubtitleCached;
      final shouldCachePrimary =
          subtitlePath != null &&
          isCached &&
          await _shouldCacheSubtitleByCopy(subtitlePath);
      final shouldCacheSecondary =
          secondarySubtitlePath != null &&
          isSecondaryCached &&
          await _shouldCacheSubtitleByCopy(secondarySubtitlePath);
      final storage = TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      );
      final subDir = await storage.taskDirectory(
        videoId,
        create: shouldCachePrimary || shouldCacheSecondary,
      );
      if ((shouldCachePrimary || shouldCacheSecondary) &&
          !await subDir.exists()) {
        await subDir.create(recursive: true);
      }

      // 1. Process Primary Subtitle
      if (subtitlePath != null) {
        String finalPath = subtitlePath;
        var cachedPrimary = false;
        if (shouldCachePrimary) {
          final ext = p.extension(subtitlePath);
          // Use _main suffix to avoid collision with secondary if same extension
          final newFileName = "main$ext";
          final newPath = p.join(subDir.path, newFileName);

          if (subtitlePath != newPath) {
            try {
              await File(subtitlePath).copy(newPath);
              finalPath = newPath;
              cachedPrimary = true;
              _upsertManagedSubtitleAssetInMemory(
                item,
                finalPath,
                ManagedSubtitleAssetKind.cached,
                '主字幕缓存',
              );
            } catch (e) {
              developer.log('Error copying primary subtitle', error: e);
            }
          } else {
            cachedPrimary = true;
          }
        }
        if (shouldApply?.call() == false) return;
        item.subtitlePath = finalPath;
        item.isSubtitleCached = cachedPrimary;
      } else {
        // If null passed (cleared), clear it
        if (shouldApply?.call() == false) return;
        item.subtitlePath = null;
        item.isSubtitleCached = false;
      }

      // 2. Process Secondary Subtitle
      if (secondarySubtitlePath != null) {
        String finalSecPath = secondarySubtitlePath;
        var cachedSecondary = false;
        if (shouldCacheSecondary) {
          final ext = p.extension(secondarySubtitlePath);
          final newFileName = "secondary$ext";
          final newPath = p.join(subDir.path, newFileName);

          if (secondarySubtitlePath != newPath) {
            try {
              await File(secondarySubtitlePath).copy(newPath);
              finalSecPath = newPath;
              cachedSecondary = true;
              _upsertManagedSubtitleAssetInMemory(
                item,
                finalSecPath,
                ManagedSubtitleAssetKind.cached,
                '副字幕缓存',
              );
            } catch (e) {
              developer.log('Error copying secondary subtitle', error: e);
            }
          } else {
            cachedSecondary = true;
          }
        }
        if (shouldApply?.call() == false) return;
        item.secondarySubtitlePath = finalSecPath;
        item.isSecondarySubtitleCached = cachedSecondary;
      } else {
        // If null passed (cleared), clear it
        if (shouldApply?.call() == false) return;
        item.secondarySubtitlePath = null;
        item.isSecondarySubtitleCached = false;
      }

      if (item.isRecycled) {
        final paths = <String>[];
        if (item.subtitlePath != null) {
          paths.add(item.subtitlePath!);
        }
        if (item.secondarySubtitlePath != null) {
          paths.add(item.secondarySubtitlePath!);
        }
        item.recycledSelectedSubtitlePaths = paths;
      }
      item.blockAutoAssociatedSubtitleSelection =
          item.subtitlePath == null && item.secondarySubtitlePath == null;

      _shareCloudSubtitles(videoId);
      await _deleteReplacedManagedSubtitleCache(
        oldPrimaryPath,
        videoId: videoId,
        wasCached: oldPrimaryWasCached,
        currentItem: item,
      );
      await _deleteReplacedManagedSubtitleCache(
        oldSecondaryPath,
        videoId: videoId,
        wasCached: oldSecondaryWasCached,
        currentItem: item,
      );

      _invalidateVideoSizeCache(videoId);
      _shareCloudSubtitles(videoId);
      await _saveLibrary();
    }
  }

  Future<void> _deleteReplacedManagedSubtitleCache(
    String? oldPath, {
    required String videoId,
    required bool wasCached,
    required VideoItem currentItem,
  }) async {
    if (!wasCached || oldPath == null || oldPath.isEmpty) return;
    if (_subtitleReferencesContainPath(currentItem, oldPath)) return;
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    if (!await storage.isTaskOwnedPath(oldPath, videoId)) return;
    try {
      final file = File(oldPath);
      if (await file.exists()) await file.delete();
      currentItem.managedSubtitleAssets = currentItem.managedSubtitleAssets
          .where((asset) => !_samePath(asset.path, oldPath))
          .toList(growable: false);
    } catch (error) {
      developer.log('Error deleting replaced subtitle cache', error: error);
    }
  }

  void _upsertManagedSubtitleAssetInMemory(
    VideoItem item,
    String path,
    ManagedSubtitleAssetKind kind,
    String displayName, {
    String? sourceAssetId,
    String? language,
  }) {
    if (item.managedSubtitleAssets.any(
      (asset) => _samePath(asset.path, path),
    )) {
      return;
    }
    item.managedSubtitleAssets = <ManagedSubtitleAsset>[
      ...item.managedSubtitleAssets,
      ManagedSubtitleAsset(
        assetId: const Uuid().v4(),
        path: p.normalize(path),
        kind: kind,
        displayName: displayName,
        wordTimingPath: File(SubtitleWordTimingStore.pathFor(path)).existsSync()
            ? SubtitleWordTimingStore.pathFor(path)
            : null,
        sourceAssetId: sourceAssetId,
        language: language,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    ];
  }

  Future<bool> _shouldCacheSubtitleByCopy(String subtitlePath) async {
    if (subtitlePath.isEmpty) return false;
    try {
      if (_initialized && p.isWithin(_dataRootDir.path, subtitlePath)) {
        return false;
      }
      final tempDir = await getTemporaryDirectory();
      if (p.isWithin(tempDir.path, subtitlePath)) {
        return true;
      }
      if (Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (final dir in extCacheDirs) {
            if (p.isWithin(dir.path, subtitlePath)) {
              return true;
            }
          }
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> updateVideoAdditionalSubtitles(
    String videoId,
    Map<String, String>? additionalSubtitles,
  ) async {
    final item = _videos[videoId];
    if (item != null) {
      item.additionalSubtitles = await _adoptSubtitleMapIntoTask(
        item,
        additionalSubtitles,
        ManagedSubtitleAssetKind.downloaded,
      );
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      _invalidateVideoSizeCache(videoId);
      _shareCloudSubtitles(videoId);
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> updateVideoLocalSubtitles(
    String videoId,
    Map<String, String>? localSubtitles,
  ) async {
    final item = _videos[videoId];
    if (item != null) {
      item.localSubtitles = await _adoptSubtitleMapIntoTask(
        item,
        localSubtitles,
        ManagedSubtitleAssetKind.imported,
      );
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      _invalidateVideoSizeCache(videoId);
      _shareCloudSubtitles(videoId);
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<Map<String, String>?> _adoptSubtitleMapIntoTask(
    VideoItem item,
    Map<String, String>? subtitles,
    ManagedSubtitleAssetKind kind,
  ) async {
    if (subtitles == null) return null;
    if (subtitles.isEmpty) return <String, String>{};
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    final adoptedBySource = <String, String>{};
    final result = <String, String>{};
    for (final entry in subtitles.entries) {
      final sourcePath = entry.value;
      var ownedPath = sourcePath;
      try {
        final alreadyOwned = await storage.isTaskOwnedPath(sourcePath, item.id);
        if (!alreadyOwned) {
          final sourceKey = _normalizeCachePath(sourcePath);
          ownedPath =
              adoptedBySource[sourceKey] ??
              await storage.copyIntoTask(
                item.id,
                sourcePath,
                preferredFileName: p.basename(sourcePath),
              );
          adoptedBySource[sourceKey] = ownedPath;
          _replaceSubtitleReferences(item, sourcePath, ownedPath);
        }
        if (!await File(ownedPath).exists()) {
          throw FileSystemException('任务字幕文件不存在', ownedPath);
        }
        _upsertManagedSubtitleAssetInMemory(
          item,
          ownedPath,
          kind,
          entry.key.trim().isEmpty ? p.basename(ownedPath) : entry.key,
        );
      } catch (error, stackTrace) {
        // Preserve the old reference if copying fails. A failed adoption must
        // never make an otherwise usable subtitle disappear from the card.
        developer.log(
          'Unable to adopt subtitle into task ${item.id}',
          error: error,
          stackTrace: stackTrace,
        );
      }
      result[entry.key] = ownedPath;
    }
    return result;
  }

  /// Schema v2 migration. Only files with an unambiguous task owner are moved.
  /// Files referenced by multiple cards and filename-only guesses stay in place
  /// and continue to behave as external companion subtitles.
  Future<void> _migrateTaskSubtitleAssetsIfNeeded(int savedVersion) async {
    if (savedVersion >= 2) return;

    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    final ownersByPath = <String, Set<String>>{};
    for (final item in _videos.values) {
      for (final path in _allSubtitleReferencePaths(item)) {
        if (path.trim().isEmpty) continue;
        ownersByPath
            .putIfAbsent(_normalizeCachePath(path), () => <String>{})
            .add(item.id);
      }
    }

    final topLevelFiles = <File>[];
    final legacyDirectory = Directory(p.join(_dataRootDir.path, 'subtitles'));
    if (await legacyDirectory.exists()) {
      try {
        await for (final entity in legacyDirectory.list(followLinks: false)) {
          if (entity is File && _isSupportedSubtitlePath(entity.path)) {
            topLevelFiles.add(entity);
          }
        }
      } on FileSystemException catch (error) {
        developer.log(
          'Unable to enumerate legacy subtitles during schema v2 migration',
          error: error,
        );
      }
    }

    final migratedSourceKeys = <String>{};
    for (final item in _videos.values) {
      final candidates = <String>{..._explicitManagedSubtitlePaths(item)};
      for (final file in topLevelFiles) {
        if (_hasTaskIdFilePrefix(file.path, item.id)) {
          candidates.add(file.path);
        }
      }

      for (final sourcePath in candidates) {
        if (!_isSupportedSubtitlePath(sourcePath)) continue;
        final sourceKey = _normalizeCachePath(sourcePath);
        if (migratedSourceKeys.contains(sourceKey)) continue;

        if (await storage.isTaskOwnedPath(sourcePath, item.id)) {
          if (await File(sourcePath).exists()) {
            _upsertManagedSubtitleAssetInMemory(
              item,
              sourcePath,
              _inferManagedSubtitleKind(sourcePath),
              p.basename(sourcePath),
            );
          }
          continue;
        }

        final owners = ownersByPath[sourceKey] ?? const <String>{};
        if (owners.length > 1 ||
            (owners.isNotEmpty && !owners.contains(item.id))) {
          continue;
        }
        final explicitlyReferenced = _explicitManagedSubtitlePaths(
          item,
        ).any((path) => _samePath(path, sourcePath));
        if (!explicitlyReferenced &&
            !_hasTaskIdFilePrefix(sourcePath, item.id)) {
          continue;
        }

        final source = File(sourcePath);
        if (!await source.exists()) continue;
        try {
          final destinationPath = await storage.allocatePath(
            item.id,
            p.basename(sourcePath),
          );
          final destination = File(destinationPath);
          var availableAtDestination = false;
          try {
            await source.rename(destinationPath);
            availableAtDestination = true;
          } on FileSystemException {
            await source.copy(destinationPath);
            availableAtDestination = await destination.exists();
            if (availableAtDestination) {
              try {
                await source.delete();
              } on FileSystemException {
                // A safe duplicate is preferable to losing either reference.
              }
            }
          }
          if (!availableAtDestination) continue;
          final sourceWords = File(SubtitleWordTimingStore.pathFor(sourcePath));
          if (await sourceWords.exists()) {
            try {
              final destinationWords = SubtitleWordTimingStore.pathFor(
                destinationPath,
              );
              await sourceWords.copy(destinationWords);
              _replaceSubtitleReferences(
                item,
                sourceWords.path,
                destinationWords,
              );
              final wordOwners =
                  ownersByPath[_normalizeCachePath(sourceWords.path)] ??
                  const <String>{};
              if (wordOwners.isEmpty ||
                  wordOwners.length == 1 && wordOwners.contains(item.id)) {
                await sourceWords.delete();
              }
            } on FileSystemException catch (error) {
              developer.log('词级附属文件迁移失败，保留原路径', error: error);
            }
          }

          _replaceSubtitleReferences(item, sourcePath, destinationPath);
          _upsertManagedSubtitleAssetInMemory(
            item,
            destinationPath,
            _inferManagedSubtitleKind(sourcePath),
            p.basename(sourcePath),
          );
          migratedSourceKeys.add(sourceKey);
        } catch (error, stackTrace) {
          developer.log(
            'Unable to migrate legacy subtitle for task ${item.id}',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      try {
        final existingTaskFiles = await storage.listTaskSubtitles(item.id);
        for (final file in existingTaskFiles) {
          _upsertManagedSubtitleAssetInMemory(
            item,
            file.path,
            _inferManagedSubtitleKind(file.path),
            p.basename(file.path),
          );
        }
      } catch (error) {
        developer.log(
          'Unable to reconcile task subtitles for ${item.id}',
          error: error,
        );
      }
    }

    // Persist schemaVersion=2 even when there were no files to move.
    _needsPostLoadSave = true;
  }

  Iterable<String> _allSubtitleReferencePaths(VideoItem item) sync* {
    if (item.subtitlePath != null) yield item.subtitlePath!;
    if (item.secondarySubtitlePath != null) {
      yield item.secondarySubtitlePath!;
    }
    yield* item.additionalSubtitles?.values ?? const <String>[];
    yield* item.localSubtitles?.values ?? const <String>[];
    yield* item.recycledSelectedSubtitlePaths ?? const <String>[];
    yield* item.recycledAdditionalSubtitles?.values ?? const <String>[];
    yield* item.recycledLocalSubtitles?.values ?? const <String>[];
    for (final asset in item.managedSubtitleAssets) {
      yield* asset.allFilePaths;
    }
  }

  Set<String> _explicitManagedSubtitlePaths(VideoItem item) {
    final paths = <String>{
      ...?item.additionalSubtitles?.values,
      ...?item.localSubtitles?.values,
      ...?item.recycledAdditionalSubtitles?.values,
      ...?item.recycledLocalSubtitles?.values,
      ...item.managedSubtitleAssets.expand((asset) => asset.allFilePaths),
    };
    if (item.isSubtitleCached && item.subtitlePath != null) {
      paths.add(item.subtitlePath!);
    }
    if (item.isSecondarySubtitleCached && item.secondarySubtitlePath != null) {
      paths.add(item.secondarySubtitlePath!);
    }
    for (final path in <String?>[
      item.subtitlePath,
      item.secondarySubtitlePath,
      ...?item.recycledSelectedSubtitlePaths,
    ]) {
      if (path != null && _looksLikeLegacyGeneratedSubtitle(path, item.id)) {
        paths.add(path);
      }
    }
    return paths;
  }

  bool _looksLikeLegacyGeneratedSubtitle(String path, String videoId) {
    final name = p.basename(path).toLowerCase();
    return _hasTaskIdFilePrefix(path, videoId) ||
        name.contains('.ai.') ||
        name.contains('.manual.') ||
        name.contains('.translated.') ||
        name.contains('.翻译.') ||
        name.contains('.优化.') ||
        name.contains('.stream_') ||
        name.contains('.imported.') ||
        name.endsWith('_main${p.extension(name)}') ||
        name.endsWith('_sec${p.extension(name)}');
  }

  bool _hasTaskIdFilePrefix(String path, String videoId) {
    final name = p.basename(path).toLowerCase();
    final id = videoId.toLowerCase();
    return name.startsWith('$id.') || name.startsWith('${id}_');
  }

  bool _isSupportedSubtitlePath(String path) {
    if (SubtitleWordTimingStore.isCompanion(path)) return false;
    return SubtitleFileMatcher.supportedExtensions.contains(
      p.extension(path).toLowerCase(),
    );
  }

  ManagedSubtitleAssetKind _inferManagedSubtitleKind(String path) {
    final name = p.basename(path).toLowerCase();
    if (name.contains('.translated.') || name.contains('.translation.') || name.contains('.翻译.')) {
      return ManagedSubtitleAssetKind.translated;
    }
    if (name.contains('.manual.')) return ManagedSubtitleAssetKind.manual;
    if (name.contains('.stream_')) return ManagedSubtitleAssetKind.embedded;
    if (name.contains('.download')) return ManagedSubtitleAssetKind.downloaded;
    if (name.contains('.imported.')) return ManagedSubtitleAssetKind.imported;
    if (name.contains('.ai.') || name.contains('.优化.') ||
        name == 'ai.srt' ||
        RegExp(r'^ai\.\d+\.srt$').hasMatch(name)) {
      return ManagedSubtitleAssetKind.ai;
    }
    if (name.contains('.ocr.')) return ManagedSubtitleAssetKind.ocr;
    if (name.startsWith('main.') ||
        name.startsWith('secondary.') ||
        name.contains('_main.') ||
        name.contains('_sec.')) {
      return ManagedSubtitleAssetKind.cached;
    }
    return ManagedSubtitleAssetKind.imported;
  }

  void _replaceSubtitleReferences(
    VideoItem item,
    String oldPath,
    String newPath,
  ) {
    String replace(String value) => _samePath(value, oldPath) ? newPath : value;
    if (item.subtitlePath != null) {
      item.subtitlePath = replace(item.subtitlePath!);
    }
    if (item.secondarySubtitlePath != null) {
      item.secondarySubtitlePath = replace(item.secondarySubtitlePath!);
    }
    item.additionalSubtitles = item.additionalSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.localSubtitles = item.localSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.recycledSelectedSubtitlePaths = item.recycledSelectedSubtitlePaths
        ?.map(replace)
        .toList(growable: false);
    item.recycledAdditionalSubtitles = item.recycledAdditionalSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.recycledLocalSubtitles = item.recycledLocalSubtitles?.map(
      (key, value) => MapEntry(key, replace(value)),
    );
    item.managedSubtitleAssets = item.managedSubtitleAssets
        .map(
          (asset) => asset.copyWith(
            path: replace(asset.path),
            wordTimingPath: asset.wordTimingPath == null
                ? null
                : _samePath(asset.path, oldPath) &&
                      _samePath(
                        asset.wordTimingPath!,
                        SubtitleWordTimingStore.pathFor(oldPath),
                      ) &&
                      File(
                        SubtitleWordTimingStore.pathFor(newPath),
                      ).existsSync()
                ? SubtitleWordTimingStore.pathFor(newPath)
                : replace(asset.wordTimingPath!),
          ),
        )
        .toList(growable: false);
  }

  List<ManagedSubtitleAsset> getManagedSubtitleAssets(String videoId) {
    return List<ManagedSubtitleAsset>.unmodifiable(
      _videos[videoId]?.managedSubtitleAssets ?? const <ManagedSubtitleAsset>[],
    );
  }

  Future<void> refreshSubtitleWordTimingBinding(
    String videoId,
    String path,
  ) async {
    final asset = managedSubtitleAssetForPath(videoId, path);
    if (asset == null) return;
    await registerManagedSubtitleAsset(
      videoId,
      path: path,
      kind: asset.kind,
      displayName: asset.displayName,
      sourceAssetId: asset.sourceAssetId,
      language: asset.language,
    );
  }

  ManagedSubtitleAsset? managedSubtitleAssetForPath(
    String videoId,
    String path,
  ) {
    final item = _videos[videoId];
    if (item == null) return null;
    for (final asset in item.managedSubtitleAssets) {
      if (_samePath(asset.path, path)) return asset;
    }
    return null;
  }

  Future<ManagedSubtitleAsset?> registerManagedSubtitleAsset(
    String videoId, {
    required String path,
    required ManagedSubtitleAssetKind kind,
    required String displayName,
    String? sourceAssetId,
    String? language,
    String? wordTimingPath,
    bool shareWithBilibiliPart = true,
    String? contentHash,
    String? sourceLabel,
    bool machineGenerated = false,
    bool generatedName = false,
    void Function()? authorize,
    String? entryId,
    int? offsetMs,
  }) async {
    final item = _videos[videoId];
    if (item == null) return null;
    wordTimingPath ??=
        await File(SubtitleWordTimingStore.pathFor(path)).exists()
        ? SubtitleWordTimingStore.pathFor(path)
        : null;
    final existing = managedSubtitleAssetForPath(videoId, path);
    if (existing != null) {
      authorize?.call();
      if (wordTimingPath != existing.wordTimingPath) {
        item.managedSubtitleAssets = item.managedSubtitleAssets
            .map(
              (a) => a.assetId == existing.assetId
                  ? a.copyWith(
                      wordTimingPath: wordTimingPath,
                      clearWordTimingPath: wordTimingPath == null,
                    )
                  : a,
            )
            .toList();
        _invalidateVideoSizeCache(videoId);
        _shareCloudSubtitles(videoId);
        await _saveLibrary();
        notifyListeners();
      }
      if (shareWithBilibiliPart) {
        await _mirrorSubtitleAsset(
          videoId,
          path: path,
          kind: kind,
          displayName: existing.displayName,
          sourceAssetId: sourceAssetId,
          language: language,
          wordTimingPath: wordTimingPath,
          contentHash: contentHash,
          sourceLabel: sourceLabel,
          entryId: entryId,
          offsetMs: offsetMs,
        );
      }
      return item.managedSubtitleAssets.firstWhere(
        (asset) => asset.assetId == existing.assetId,
      );
    }
    if (!await subtitleFileBelongsToCard(videoId, path)) {
      throw StateError('只能登记当前媒体任务目录内的字幕');
    }
    authorize?.call();
    final asset = ManagedSubtitleAsset(
      assetId: const Uuid().v4(),
      path: p.normalize(path),
      kind: kind,
      displayName: generatedName
          ? uniqueGeneratedSubtitleName(displayName.trim(), item.managedSubtitleAssets.map((asset) => subtitleManuscriptDisplayName(item, asset)))
          : displayName.trim().isEmpty ? p.basename(path) : displayName.trim(),
      sourceAssetId: sourceAssetId,
      language: language,
      wordTimingPath: wordTimingPath,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      contentHash: contentHash,
      sourceLabel: sourceLabel,
      machineGenerated: machineGenerated,
      entryId: entryId,
      offsetMs: offsetMs,
    );
    item.managedSubtitleAssets = <ManagedSubtitleAsset>[
      ...item.managedSubtitleAssets,
      asset,
    ];
    _invalidateVideoSizeCache(videoId);
    _shareCloudSubtitles(videoId);
    await _saveLibrary();
    notifyListeners();
    if (shareWithBilibiliPart) {
      await _mirrorSubtitleAsset(
        videoId,
        path: path,
        kind: kind,
        displayName: asset.displayName,
        sourceAssetId: sourceAssetId,
        language: language,
        wordTimingPath: wordTimingPath,
        contentHash: contentHash,
        sourceLabel: sourceLabel,
        entryId: entryId,
        offsetMs: offsetMs,
      );
    }
    return asset;
  }

  Future<ManagedSubtitleAsset?> registerManagedLocalSubtitle(
    String videoId, {
    required String path,
    required ManagedSubtitleAssetKind kind,
    required String displayName,
    String? language,
    String? wordTimingPath,
    String? sourceAssetId,
    bool shareWithBilibiliPart = true,
    bool generatedName = false,
  }) async {
    final item = _videos[videoId];
    if (item == null) return null;
    if (!await subtitleFileBelongsToCard(videoId, path)) {
      throw StateError('只能登记当前媒体任务目录内的字幕');
    }
    wordTimingPath ??=
        await File(SubtitleWordTimingStore.pathFor(path)).exists()
        ? SubtitleWordTimingStore.pathFor(path)
        : null;
    final requestedName = subtitleDisplayLabel(
      displayName.trim().isEmpty
          ? p.basenameWithoutExtension(path)
          : displayName,
    );
    final visible = generatedName
        ? uniqueGeneratedSubtitleName(requestedName, item.managedSubtitleAssets
            .where((asset) => !_samePath(asset.path, path))
            .map((asset) => subtitleManuscriptDisplayName(item, asset)))
        : requestedName;
    final local = <String, String>{...?item.localSubtitles};
    // The map key has to be unique. The stored display name stays [visible],
    // so a second "中文" is not renamed to "中文（2）" in the app.
    var key = generatedName
        ? local.entries.where((entry) => _samePath(entry.value, path)).firstOrNull?.key ?? visible
        : visible;
    if (local.containsKey(key) && !_samePath(local[key]!, path)) {
      final baseName = p.basename(path);
      key = baseName;
      var serial = 2;
      while (local.containsKey(key) && !_samePath(local[key]!, path)) {
        final extension = p.extension(baseName);
        final stem = p.basenameWithoutExtension(baseName);
        key = '$stem ($serial)$extension';
        serial++;
      }
    }
    var asset = managedSubtitleAssetForPath(videoId, path);
    if (asset == null) {
      asset = ManagedSubtitleAsset(
        assetId: const Uuid().v4(),
        path: p.normalize(path),
        kind: kind,
        displayName: visible,
        language: language,
        wordTimingPath: wordTimingPath,
        sourceAssetId: sourceAssetId,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      item.managedSubtitleAssets = <ManagedSubtitleAsset>[
        ...item.managedSubtitleAssets,
        asset,
      ];
    }
    if (asset.wordTimingPath != wordTimingPath) {
      final updated = asset.copyWith(
        wordTimingPath: wordTimingPath,
        clearWordTimingPath: wordTimingPath == null,
      );
      item.managedSubtitleAssets = item.managedSubtitleAssets
          .map((a) => a.assetId == updated.assetId ? updated : a)
          .toList();
      asset = updated;
    }
    local[key] = p.normalize(path);
    item.localSubtitles = local;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    _invalidateVideoSizeCache(videoId);
    _shareCloudSubtitles(videoId);
    await _saveLibrary();
    notifyListeners();
    if (shareWithBilibiliPart) {
      await _mirrorSubtitleAsset(
        videoId,
        path: path,
        kind: kind,
        displayName: asset.displayName,
        sourceAssetId: sourceAssetId ?? asset.sourceAssetId,
        language: language,
        wordTimingPath: wordTimingPath,
        alsoLocal: true,
      );
    }
    return asset;
  }

  /// Copies a subtitle binding onto the other cards of the same Bilibili part.
  /// Local files have no part, so this does nothing for them.
  Future<void> _mirrorSubtitleAsset(
    String videoId, {
    required String path,
    required ManagedSubtitleAssetKind kind,
    required String displayName,
    String? sourceAssetId,
    String? language,
    String? wordTimingPath,
    bool alsoLocal = false,
    String? contentHash,
    String? sourceLabel,
    String? entryId,
    int? offsetMs,
  }) async {
    final cards = cardsOfSameBilibiliPart(videoId);
    if (cards.length < 2) return;
    for (final card in cards) {
      if (card.id == videoId) continue;
      try {
        if (alsoLocal) {
          await registerManagedLocalSubtitle(
            card.id,
            path: path,
            kind: kind,
            displayName: displayName,
            language: language,
            wordTimingPath: wordTimingPath,
            shareWithBilibiliPart: false,
          );
        } else {
          await registerManagedSubtitleAsset(
            card.id,
            path: path,
            kind: kind,
            displayName: displayName,
            sourceAssetId: sourceAssetId,
            language: language,
            wordTimingPath: wordTimingPath,
            shareWithBilibiliPart: false,
            contentHash: contentHash,
            sourceLabel: sourceLabel,
            entryId: entryId,
            offsetMs: offsetMs,
          );
        }
      } catch (error) {
        developer.log(
          '同分区字幕未能记到卡片 ${card.id}',
          name: 'subtitles',
          error: error,
        );
      }
    }
  }

  Future<void> reconcileManagedSubtitleAssets(
    String videoId,
    Iterable<String> paths,
  ) async {
    final item = _videos[videoId];
    if (item == null) return;
    var changed = false;
    for (final path in paths) {
      if (SubtitleWordTimingStore.isCompanion(path)) continue;
      if (item.managedSubtitleAssets.any(
        (asset) => _samePath(asset.path, path),
      )) {
        continue;
      }
      if (!await subtitleFileBelongsToCard(videoId, path) ||
          !await File(path).exists()) {
        continue;
      }
      _upsertManagedSubtitleAssetInMemory(
        item,
        path,
        _inferManagedSubtitleKind(path),
        p.basename(path),
      );
      changed = true;
    }
    if (!changed) return;
    _invalidateVideoSizeCache(videoId);
    _shareCloudSubtitles(videoId);
    await _saveLibrary();
    notifyListeners();
  }

  List<String> managedSubtitleDeletionPaths(String videoId, String path) {
    // Lineage records where a subtitle came from, not ownership of its output.
    // Each generated subtitle has an independent lifetime; only its own timing
    // companion belongs to the same deletion operation.
    final asset = managedSubtitleAssetForPath(videoId, path);
    return asset?.allFilePaths.toList(growable: false) ?? <String>[path];
  }

  Future<void> removeManagedSubtitleAssetsByPaths(
    String videoId,
    Iterable<String> paths,
  ) async {
    final item = _videos[videoId];
    if (item == null) return;
    final keys = paths.map(_normalizeCachePath).toSet();
    if (keys.isEmpty) return;
    final previousCount = item.managedSubtitleAssets.length;
    item.managedSubtitleAssets = item.managedSubtitleAssets
        .where((asset) => !keys.contains(_normalizeCachePath(asset.path)))
        .toList(growable: false);
    if (item.managedSubtitleAssets.length == previousCount) return;
    _invalidateVideoSizeCache(videoId);
    _shareCloudSubtitles(videoId);
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> updateVideoSubtitleVisibility(
    String videoId,
    bool showFloatingSubtitles,
  ) async {
    final item = _videos[videoId];
    if (item != null) {
      item.showFloatingSubtitles = showFloatingSubtitles;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> markAutoEmbeddedSubtitleLoadAttempted(String videoId) async {
    final item = _videos[videoId];
    if (item != null && !item.hasAttemptedAutoEmbeddedSubtitleLoad) {
      item.hasAttemptedAutoEmbeddedSubtitleLoad = true;
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      _shareCloudSubtitles(videoId);
      await _saveLibrary();
      notifyListeners();
    }
  }

  Future<void> updateVideoPortraitDisplayAspectRatio(
    String videoId,
    double? aspectRatio, {
    double? customWidth,
    double? customHeight,
    bool markInitialized = true,
  }) async {
    final item = _videos[videoId];
    if (item == null) return;

    final bool ratioUnchanged =
        (item.portraitDisplayAspectRatio == null && aspectRatio == null) ||
        (item.portraitDisplayAspectRatio != null &&
            aspectRatio != null &&
            (item.portraitDisplayAspectRatio! - aspectRatio).abs() < 0.0001);
    final bool customWidthUnchanged =
        (item.portraitCustomAspectWidth == null && customWidth == null) ||
        (item.portraitCustomAspectWidth != null &&
            customWidth != null &&
            (item.portraitCustomAspectWidth! - customWidth).abs() < 0.0001);
    final bool customHeightUnchanged =
        (item.portraitCustomAspectHeight == null && customHeight == null) ||
        (item.portraitCustomAspectHeight != null &&
            customHeight != null &&
            (item.portraitCustomAspectHeight! - customHeight).abs() < 0.0001);
    final bool initializedUnchanged =
        item.hasPortraitAspectPreferenceInitialized ==
        (item.hasPortraitAspectPreferenceInitialized || markInitialized);

    if (ratioUnchanged &&
        customWidthUnchanged &&
        customHeightUnchanged &&
        initializedUnchanged) {
      return;
    }

    item.portraitDisplayAspectRatio = aspectRatio;
    item.portraitCustomAspectWidth = customWidth;
    item.portraitCustomAspectHeight = customHeight;
    item.hasPortraitAspectPreferenceInitialized =
        item.hasPortraitAspectPreferenceInitialized || markInitialized;

    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> updateVideoDisplayTransform(
    String videoId, {
    bool? isMirroredH,
    bool? isMirroredV,
  }) async {
    final item = _videos[videoId];
    if (item == null) return;

    final bool nextMirroredH = isMirroredH ?? item.isVideoMirroredH;
    final bool nextMirroredV = isMirroredV ?? item.isVideoMirroredV;

    if (item.isVideoMirroredH == nextMirroredH &&
        item.isVideoMirroredV == nextMirroredV) {
      return;
    }

    item.isVideoMirroredH = nextMirroredH;
    item.isVideoMirroredV = nextMirroredV;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
  }

  // --- Single Item Management (Exposed for Batch Import) ---

  Future<String?> addSingleVideo(
    VideoItem item, {
    bool useOriginalPath = false,
    bool reuseExistingItem = false,
    bool retainSharedMediaPath = false,
    bool persistReceivedFile = false,
    bool Function()? shouldContinue,
    String? activityBatchId,
    LibraryImportSourceKind sourceKind = LibraryImportSourceKind.localFile,
  }) async {
    _restoreCompletedLocalDownload(item);
    if (_collections[item.parentId]?.isPodcast == true &&
        item.sourceRef?.kind != MediaSourceKind.podcastEpisode) {
      throw const FormatException('请将普通媒体导入其他文件夹');
    }
    final copyImportedMediaToPrivateStorage =
        SettingsService().copyImportedMediaToPrivateStorage;
    final originalMediaPath = item.path;
    // #region debug-point A:add-single-video-enter
    unawaited(
      _reportDebugEvent(
        'A',
        'library_service.dart:addSingleVideo',
        'addSingleVideo entered',
        data: <String, Object?>{
          'id': item.id,
          'path': item.path,
          'useOriginalPath': useOriginalPath,
          'hasThumbnail': item.thumbnailPath != null,
        },
      ),
    );
    // #endregion
    item.title = resolveImportedMediaTitle(
      sourcePath: item.path,
      originalTitle: item.title,
    );
    if (!_isCloudDriveItem(item)) {
      item.sourceFingerprint ??= await _computeSourceFingerprint(item.path);
    }
    final isBilibiliStream = _isBilibiliStreamItem(item);
    if (shouldContinue?.call() == false) throw StateError('入库已取消');
    final retainExistingMedia =
        retainSharedMediaPath &&
        !isBilibiliStream &&
        _videos.values.any(
          (other) =>
              other.id != item.id &&
              (_samePath(other.path, item.path) ||
                  (other.bilibiliDownloadPath != null &&
                      _samePath(other.bilibiliDownloadPath!, item.path))),
        ) &&
        await File(item.path).exists();

    // Every Bilibili streaming import is an explicit card instance. Its URL
    // identifies the playback source, never whether another card already
    // exists, so path/fingerprint deduplication must not apply here.
    if (reuseExistingItem && !isBilibiliStream) {
      final existingId = await _findExistingVideoIdByPathOrFingerprint(
        item.path,
        sourceFingerprint: item.sourceFingerprint,
        originalTitle: item.title,
      );

      if (existingId != null) {
        if (shouldContinue?.call() == false) throw StateError('入库已取消');
        await _restoreExistingVideoToTarget(
          existingId,
          item.parentId,
          preserveOrder: _activity.media[item.id]?.downloadImport != null,
        );
        debugPrint(
          "Video with path ${item.path} already exists, skipping import",
        );
        return existingId;
      }
    }

    // 2. Handle file persistence for temp/cache files
    // 如果 useOriginalPath 为 true，则跳过文件持久化处理，直接使用原始路径
    if (!isBilibiliStream) {
      if (retainExistingMedia) {
        // A sync-created logical entry may share a verified physical resource.
        // File deletion still checks every live and recycled reference.
        await _ensureFilePersistence(item);
      } else if (persistReceivedFile) {
        // Sync publication requires the permanent file. A swallowed move that
        // keeps the extraction path would become an empty card after cleanup.
        final importedDir = await AppStorageService.instance
            .importedMediaDirectory(dataRoot: _dataRootDir);
        final extension = p.extension(item.path).toLowerCase();
        final safeExtension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
            ? extension
            : '';
        item.path = await const FolderMediaCommitter().commitFile(
          sourcePath: item.path,
          permanentDirectory: importedDir,
          reservedFileName: '${item.id}$safeExtension',
        );
      } else if (copyImportedMediaToPrivateStorage) {
        item.path = await _copyImportedMediaToPrivateStorage(
          item.path,
          fileNamePrefix: item.id,
        );
      } else if (!useOriginalPath ||
          await _isDisposableMediaCachePath(item.path)) {
        await _ensureFilePersistence(item);
      } else {
        debugPrint(
          "Using original path for single video (no copy): ${item.path}",
        );
      }
    }

    if (!isBilibiliStream && item.durationMs <= 0) {
      item.durationMs = await _probeMediaDurationMs(item.path);
    }
    // Chapter detection is reconstructable. A received original is published
    // first so a slow or failing probe cannot block or roll back the file.
    if (!isBilibiliStream && !item.hasProbedChapters && !persistReceivedFile) {
      if (item.chapters.isEmpty) {
        item.chapters = await MediaChapterProbe.probe(
          item.path,
          durationMs: item.durationMs,
        );
      }
      item.hasProbedChapters = true;
    }

    // Downloaded/imported subtitle groups are task assets. Adopt them before
    // publishing the card so no other card can observe their original path as
    // if it were shared state.
    item.additionalSubtitles = await _adoptSubtitleMapIntoTask(
      item,
      item.additionalSubtitles,
      ManagedSubtitleAssetKind.downloaded,
    );
    item.localSubtitles = await _adoptSubtitleMapIntoTask(
      item,
      item.localSubtitles,
      ManagedSubtitleAssetKind.imported,
    );

    // #region debug-point D:add-single-video-after-probe
    unawaited(
      _reportDebugEvent(
        'D',
        'library_service.dart:addSingleVideo',
        'Duration probe completed for imported video',
        data: <String, Object?>{
          'id': item.id,
          'path': item.path,
          'durationMs': item.durationMs,
        },
      ),
    );
    // #endregion

    // 3. Audio cover art / video thumbnail will be generated asynchronously below

    if (shouldContinue?.call() == false) {
      await _restoreCancelledDownloadFile(item, originalMediaPath);
      throw StateError('入库已取消');
    }
    _videos[item.id] = item;

    if (item.parentId != null && _collections.containsKey(item.parentId)) {
      _collections[item.parentId]!.childrenIds.add(item.id);
    } else {
      // Safe-guard: if parent missing or null, add to root
      if (item.parentId != null) {
        item.parentId = null;
      }
      _rootChildrenIds.add(item.id);
    }
    if (failAddSingleVideoAfterInsertForTesting) {
      throw StateError('addSingleVideo failed (test)');
    }

    if (activityBatchId != null) {
      noteImportedMedia(
        item.id,
        addedAtMs: DateTime.now().millisecondsSinceEpoch,
        batchId: activityBatchId,
      );
    } else {
      final ownedBatchId = beginImportBatch(
        title: item.title,
        sourceKind: sourceKind,
        targetCollectionId: item.parentId,
      );
      if (ownedBatchId != null) {
        noteImportedMedia(
          item.id,
          addedAtMs: DateTime.now().millisecondsSinceEpoch,
          batchId: ownedBatchId,
        );
        await completeImportBatch(ownedBatchId, persist: false);
      }
    }

    await _saveLibrary();
    notifyListeners();
    if (persistReceivedFile && !isBilibiliStream && !item.hasProbedChapters) {
      unawaited(_probeReceivedChaptersLater(item.id));
    }

    // #region debug-point A:add-single-video-notify
    await _releaseCommittedImportCacheCopies({originalMediaPath: item.path});
    unawaited(
      _reportDebugEvent(
        'A',
        'library_service.dart:addSingleVideo',
        'Library saved and listeners notified for imported video',
        data: <String, Object?>{
          'id': item.id,
          'path': item.path,
          'type': item.type.name,
        },
      ),
    );
    // #endregion

    // Generate thumbnail asynchronously (video thumbnail + audio cover art)
    if (!skipImportSidecarWorkForTesting &&
        item.type == MediaType.audio &&
        (item.thumbnailPath == null || item.thumbnailPath!.isEmpty)) {
      unawaited(
        _resolveImportedAudioCover(
          item,
          sidecarHintPath: originalMediaPath,
          persist: true,
        ).then((thumb) {
          unawaited(
            _reportDebugEvent(
              'C',
              'library_service.dart:addSingleVideo',
              'Async thumbnail generation finished',
              data: <String, Object?>{
                'id': item.id,
                'path': item.path,
                'thumbGenerated': thumb != null,
              },
            ),
          );
        }),
      );
    } else if (!skipImportSidecarWorkForTesting &&
        !isBilibiliStream &&
        item.type == MediaType.video &&
        (item.thumbnailPath == null ||
            _requiresWindowsThumbnailRepair(item.thumbnailPath))) {
      _generateThumbnail(item.path, videoId: item.id).then((thumb) {
        // #region debug-point C:add-single-video-thumb-finished
        unawaited(
          _reportDebugEvent(
            'C',
            'library_service.dart:addSingleVideo',
            'Async thumbnail generation finished',
            data: <String, Object?>{
              'id': item.id,
              'path': item.path,
              'thumbGenerated': thumb != null,
            },
          ),
        );
        // #endregion
        if (thumb != null) {
          item.thumbnailPath = thumb;
          unawaited(
            _saveLibrary().catchError((Object error, StackTrace stackTrace) {
              developer.log(
                'Error saving generated thumbnail',
                error: error,
                stackTrace: stackTrace,
              );
            }),
          );
          notifyListeners();
        }
      });
    }

    return item.id;
  }

  /// Rebinds [mediaId] to [pickedPath] without creating a new card or import
  /// batch. Activity clocks stay untouched; derived playback caches are dropped.
  Future<RelocateLocalMediaResult> relocateLocalMediaSource({
    required String mediaId,
    required String pickedPath,
  }) async {
    final item = _videos[mediaId];
    if (item == null) {
      return const RelocateLocalMediaResult(
        status: RelocateLocalMediaStatus.mediaNotFound,
      );
    }
    if (!canRelocateLocalMediaSource(item)) {
      return const RelocateLocalMediaResult(
        status: RelocateLocalMediaStatus.onlineSource,
      );
    }

    final normalizedPicked = p.normalize(pickedPath);
    if (!isSupportedMediaPath(normalizedPicked)) {
      return const RelocateLocalMediaResult(
        status: RelocateLocalMediaStatus.unsupportedType,
      );
    }
    if (_detectMediaType(normalizedPicked) != item.type) {
      return const RelocateLocalMediaResult(
        status: RelocateLocalMediaStatus.typeMismatch,
      );
    }
    if (!await File(normalizedPicked).exists()) {
      return const RelocateLocalMediaResult(
        status: RelocateLocalMediaStatus.missingFile,
      );
    }

    // Persist first so a failed copy leaves the existing association intact.
    final String storedPath;
    try {
      storedPath = await _persistRelocatedMediaPath(
        mediaId: item.id,
        pickedPath: normalizedPicked,
      );
    } catch (error, stackTrace) {
      developer.log(
        'Relocate persist failed',
        error: error,
        stackTrace: stackTrace,
        name: 'library.relocate',
      );
      return const RelocateLocalMediaResult(
        status: RelocateLocalMediaStatus.missingFile,
      );
    }
    if (!await File(storedPath).exists()) {
      return const RelocateLocalMediaResult(
        status: RelocateLocalMediaStatus.missingFile,
      );
    }

    await _invalidateCachesForSourceRelocate(item);

    item.path = storedPath;
    item.sourceFingerprint = await _computeSourceFingerprint(storedPath);
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    item.chapters = const <MediaChapter>[];
    item.hasProbedChapters = false;

    final probedDuration = await _probeMediaDurationMs(storedPath);
    var positionClamped = false;
    if (probedDuration > 0) {
      item.durationMs = probedDuration;
      if (item.lastPositionMs > item.durationMs) {
        item.lastPositionMs = item.durationMs > 0 ? item.durationMs - 1 : 0;
        positionClamped = true;
      }
    }
    if (!skipImportSidecarWorkForTesting) {
      item.chapters = await MediaChapterProbe.probe(
        storedPath,
        durationMs: item.durationMs,
      );
      item.hasProbedChapters = true;
    }

    if (!skipImportSidecarWorkForTesting && item.type == MediaType.audio) {
      final previousCover = item.thumbnailPath;
      item.thumbnailPath = null;
      item.hasProbedAudioCover = false;
      if (previousCover != null && previousCover.isNotEmpty) {
        await _deleteFileIfExists(previousCover);
      }
      await _deleteFileIfExists(
        _thumbnailOutputPath(item.path, videoId: item.id),
      );
      await _resolveImportedAudioCover(item, persist: false);
    } else if (!skipImportSidecarWorkForTesting &&
        item.type == MediaType.video &&
        item.thumbnailPath == null) {
      unawaited(
        _generateThumbnail(item.path, videoId: item.id).then((thumb) {
          if (thumb == null) return;
          final current = _videos[item.id];
          if (current == null || current.path != item.path) return;
          current.thumbnailPath = thumb;
          unawaited(_saveLibrary());
          notifyListeners();
        }),
      );
    }

    await _saveLibrary();
    notifyListeners();
    return RelocateLocalMediaResult(
      status: RelocateLocalMediaStatus.success,
      positionClamped: positionClamped,
    );
  }

  Future<String> _persistRelocatedMediaPath({
    required String mediaId,
    required String pickedPath,
  }) async {
    final copyImportedMediaToPrivateStorage =
        SettingsService().copyImportedMediaToPrivateStorage;
    if (copyImportedMediaToPrivateStorage) {
      return _copyImportedMediaToPrivateStorage(
        pickedPath,
        fileNamePrefix:
            '${mediaId}_reloc_${DateTime.now().millisecondsSinceEpoch}',
      );
    }
    final importedDir = await AppStorageService.instance.importedMediaDirectory(
      dataRoot: _dataRootDir,
    );
    // Temp/cache picks follow the same long-term path rule as import. User
    // subtitles stay on the existing card and must not be moved here.
    return _moveIfTemporary(pickedPath, importedDir);
  }

  Future<void> _invalidateCachesForSourceRelocate(VideoItem item) async {
    ThumbnailCacheService().evictFromCache(item.id);

    if (item.playbackPath != null && _isInternalPath(item.playbackPath!)) {
      try {
        final referencedElsewhere = _videos.values.any(
          (other) =>
              other.id != item.id &&
              other.playbackPath != null &&
              _samePath(other.playbackPath!, item.playbackPath!),
        );
        final file = File(item.playbackPath!);
        if (!referencedElsewhere && await file.exists()) {
          await file.delete();
        }
      } catch (e) {
        developer.log('Error deleting compatible playback file', error: e);
      }
    }
    item.playbackPath = null;

    final thumbnailPath = item.thumbnailPath;
    if (thumbnailPath != null && _isInternalPath(thumbnailPath)) {
      try {
        final file = File(thumbnailPath);
        if (await file.exists() &&
            !_isThumbnailPathReferencedByOtherVideo(thumbnailPath, item.id)) {
          await file.delete();
        }
      } catch (e) {
        developer.log(
          'Error deleting stale thumbnail after relocate',
          error: e,
        );
      }
    }
    item.thumbnailPath = null;

    try {
      await ChapterThumbnailService.instance.deleteForVideo(item.id);
    } catch (e) {
      developer.log(
        'Error deleting chapter thumbnails after relocate',
        error: e,
      );
    }

    item.codec = null;
    item.bilibiliVideoShot = null;
    item.hasAttemptedAutoEmbeddedSubtitleLoad = false;
  }

  /// Ensures that video and subtitle files are moved to permanent storage
  /// if they are currently in a temporary or cache directory.
  Future<void> _ensureFilePersistence(
    VideoItem item, {
    bool forceMedia = false,
  }) async {
    try {
      final importedDir = await AppStorageService.instance
          .importedMediaDirectory(dataRoot: _dataRootDir);

      // Handle Video File
      item.path = await _moveIfTemporary(
        item.path,
        importedDir,
        force: forceMedia,
      );

      final taskSubtitleDir = await TaskSubtitleStorageService(
        dataRootOverride: _dataRootDir,
      ).taskDirectory(item.id, create: true);

      // Temporary subtitle picker/download results are owned by this card.
      if (item.subtitlePath != null) {
        final previousPath = item.subtitlePath!;
        item.subtitlePath = await _moveIfTemporary(
          previousPath,
          taskSubtitleDir,
        );
        if (!_samePath(previousPath, item.subtitlePath!)) {
          _upsertManagedSubtitleAssetInMemory(
            item,
            item.subtitlePath!,
            ManagedSubtitleAssetKind.imported,
            p.basename(item.subtitlePath!),
          );
        }
      }

      if (item.secondarySubtitlePath != null) {
        final previousPath = item.secondarySubtitlePath!;
        item.secondarySubtitlePath = await _moveIfTemporary(
          previousPath,
          taskSubtitleDir,
        );
        if (!_samePath(previousPath, item.secondarySubtitlePath!)) {
          _upsertManagedSubtitleAssetInMemory(
            item,
            item.secondarySubtitlePath!,
            ManagedSubtitleAssetKind.imported,
            p.basename(item.secondarySubtitlePath!),
          );
        }
      }
    } catch (e) {
      debugPrint("Error ensuring file persistence: $e");
    }
  }

  Future<bool> _isDisposableMediaCachePath(String path) async {
    return isDisposableImportCachePath(path);
  }

  Future<String> _moveIfTemporary(
    String currentPath,
    Directory targetDir, {
    bool force = false,
  }) async {
    try {
      final file = File(currentPath);
      if (!await file.exists()) return currentPath;
      // Existing cards may point at legacy cache files. Moving such a source
      // would break their paths; keep the shared association intact.
      if (_storageFileOwners[Platform.isWindows
                  ? p.normalize(currentPath).toLowerCase()
                  : p.normalize(currentPath)]
              ?.isNotEmpty ==
          true) {
        return currentPath;
      }

      bool isTemporary = force;

      // Desktop system temp also contains user files and other apps' data.
      isTemporary =
          isTemporary || await _isDisposableMediaCachePath(currentPath);

      // Check 2: Android Caches
      if (!isTemporary && Platform.isAndroid) {
        final extCacheDirs = await getExternalCacheDirectories();
        if (extCacheDirs != null) {
          for (var dir in extCacheDirs) {
            if (p.isWithin(dir.path, currentPath)) {
              isTemporary = true;
              break;
            }
          }
        }
      }

      // Only known workspaces are transient. Downloaded/offline media and
      // legacy imported originals already have durable ownership and paths.
      if (!isTemporary &&
          _isInternalPath(currentPath) &&
          p.isWithin(_dataRootDir.path, currentPath)) {
        final parts = p.split(p.relative(currentPath, from: _dataRootDir.path));
        final durable = {
          'imported_media',
          'imported_videos',
          'subtitles',
          'thumbnails',
          'podcasts',
          'cloud_drive_material',
          'cloud_drive_subtitles',
          'artwork',
          'douyin_downloads',
          'web_media_downloads',
          'yt_dlp_downloads',
          'exports',
          'compatible_audio',
        };
        final finishedDownload =
            parts.length > 2 && parts[0] == 'downloads' && parts[2] == 'files';
        if (!durable.contains(parts.first) && !finishedDownload) {
          isTemporary = true;
        }
      }

      if (isTemporary) {
        if (!await targetDir.exists()) await targetDir.create(recursive: true);

        // Use a unique name to avoid collisions
        final fileName =
            "${DateTime.now().millisecondsSinceEpoch}_${p.basename(currentPath)}";
        final newPath = p.join(targetDir.path, fileName);

        // Use safe chunked copy to avoid OOM or OS file limits for large files
        try {
          await file.rename(newPath);
        } catch (e) {
          debugPrint(
            "Rename failed in _moveIfTemporary: $e, falling back to chunked copy",
          );
          final partial = File('$newPath.partial');
          try {
            final before = await file.stat();
            await file.copy(partial.path);
            final after = await file.stat();
            if (await partial.length() != before.size ||
                before.size != after.size ||
                before.modified != after.modified ||
                before.changed != after.changed) {
              throw FileSystemException('媒体副本校验失败', currentPath);
            }
            await partial.rename(newPath);
          } catch (_) {
            if (await partial.exists()) await partial.delete();
            rethrow;
          }
        }

        // Delete original if it was temporary
        try {
          if (await file.exists()) {
            await file.delete();
          }
          debugPrint("Deleted temp file after move: $currentPath");

          // Check for empty unzip parent dir
          final parentDir = file.parent;
          if (p.basename(parentDir.path).startsWith('unzip_')) {
            if (await parentDir.list().isEmpty) {
              await parentDir.delete();
              debugPrint("Deleted empty unzip dir: ${parentDir.path}");
            }
          }
        } catch (e) {
          debugPrint("Failed to delete temp file: $e");
        }

        return newPath;
      }
    } catch (e) {
      debugPrint("Error in _moveIfTemporary for $currentPath: $e");
    }
    return currentPath;
  }

  Future<void> removeSingleVideo(String id, {bool keepFile = false}) async {
    if (_videos.containsKey(id)) {
      _invalidateSizeCaches();
      final vid = _videos[id];
      if (vid != null && !keepFile) await _deleteVideoFiles(vid);
      _deleteVideo(id); // Helper handles parent removal
      await _saveLibrary();
      notifyListeners();
    }
  }

  /// Applies a winning directory event without changing the receiving root's
  /// placement when [preserveRootParent] is requested by its sync binding.
  Future<void> applySyncItemMetadata(
    String id, {
    required String name,
    required String? parentId,
    bool preserveRootParent = false,
  }) async {
    final folder = _collections[id];
    final video = _videos[id];
    if (folder == null && video == null) return;
    final title = name.trim();
    if (title.isEmpty) throw const FormatException('条目名称不能为空');
    final currentParent = folder?.parentId ?? video?.parentId;
    final nextParent = preserveRootParent ? currentParent : parentId;
    if (nextParent != null) {
      final parent = _collections[nextParent];
      if (parent == null || parent.isRecycled || nextParent == id) {
        throw const FormatException('同步目标文件夹无效');
      }
      final visited = <String>{id};
      String? cursor = nextParent;
      while (cursor != null) {
        if (!visited.add(cursor)) throw const FormatException('不能循环嵌套文件夹');
        final ancestor = _collections[cursor];
        if (ancestor == null || ancestor.isRecycled) {
          throw const FormatException('同步目标文件夹无效');
        }
        cursor = ancestor.parentId;
      }
    }
    if ((folder?.name ?? video!.title) == title &&
        currentParent == nextParent) {
      return;
    }
    if (currentParent != nextParent) {
      if (currentParent == null) {
        _rootChildrenIds.remove(id);
      } else {
        _collections[currentParent]?.childrenIds.remove(id);
      }
      final children = nextParent == null
          ? _rootChildrenIds
          : _collections[nextParent]!.childrenIds;
      if (!children.contains(id)) children.add(id);
    }
    if (folder != null) {
      folder.name = title;
      folder.parentId = nextParent;
    } else {
      video!.title = title;
      video.parentId = nextParent;
    }
    _invalidateSizeCaches();
    await _saveLibrary();
    notifyListeners();
  }

  /// Logical deletion only. All media and associated resources remain recoverable.
  Future<void> recycleSyncItem(String id) async {
    if ((_collections[id]?.isRecycled ?? _videos[id]?.isRecycled) != false) {
      return;
    }
    await moveToRecycleBin([id]);
  }

  /// Fills [videoId] with a file that is already on permanent storage.
  ///
  /// The card id and playback position stay put. A missing or unreadable file
  /// throws instead of leaving the old path marked as received.
  Future<void> repairSyncMediaFile({
    required String videoId,
    required String permanentPath,
    required int expectedLength,
  }) async {
    final item = _videos[videoId];
    if (item == null) throw const FormatException('同步媒体条目已不存在');
    final file = File(permanentPath);
    if (!await file.exists() || await file.length() != expectedLength) {
      throw const FormatException('原文件尚未保存到本机');
    }
    final opened = await file.open();
    await opened.close();
    item.path = permanentPath;
    item.playbackPath = null;
    item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> _probeReceivedChaptersLater(String videoId) async {
    final item = _videos[videoId];
    if (item == null || item.hasProbedChapters) return;
    try {
      if (item.chapters.isEmpty) {
        item.chapters = await MediaChapterProbe.probe(
          item.path,
          durationMs: item.durationMs,
        );
      }
      item.hasProbedChapters = true;
      await _saveLibrary();
      notifyListeners();
    } catch (error) {
      debugPrint('Received media chapter probe skipped: $error');
    }
  }

  /// Commits a fully imported revision under the existing logical identity.
  /// Previous bytes and subtitle associations stay on a recoverable old card.
  Future<void> commitSyncMediaRevision({
    required String existingId,
    required String importedId,
  }) async {
    if (existingId == importedId) return;
    final old = _videos[existingId];
    final imported = _videos[importedId];
    if (old == null || imported == null || imported.isRecycled) {
      throw const FormatException('同步媒体条目已不存在');
    }
    final hasOldContent =
        _isBilibiliStreamItem(old) || await File(old.path).exists();
    if (hasOldContent &&
        !_samePath(
          old.bilibiliDownloadPath ?? old.path,
          imported.bilibiliDownloadPath ?? imported.path,
        )) {
      final backupId = const Uuid().v4();
      final backup = VideoItem.fromJson({
        ...old.toJson(),
        'id': backupId,
        'title': '${old.title}（旧版本）',
        'isRecycled': true,
        'recycleTime': DateTime.now().millisecondsSinceEpoch,
      });
      _videos[backupId] = backup;
      final activity = _activity.media[existingId];
      if (activity != null) {
        _activity.media[backupId] = MediaActivityRecord.tryParse({
          ...activity.toJson(),
          'id': backupId,
        })!;
      }
    }
    final replacement = VideoItem.fromJson({
      ...imported.toJson(),
      'id': existingId,
      'title': old.title,
      'parentId': old.parentId,
      'lastPositionMs': old.lastPositionMs,
      'isRecycled': old.isRecycled,
      'recycleTime': old.recycleTime,
    });
    _deleteVideo(importedId); // Logical removal; never deletes the new files.
    _videos[existingId] = replacement;
    _invalidateSizeCaches();
    await _saveLibrary();
    notifyListeners();
  }

  Future<void> renameItem(
    String id,
    String newName, {
    String? coverLabel,
    bool updateCoverLabel = false,
  }) async {
    newName = newName.trim();
    if (newName.isEmpty) return;
    if (_collections.containsKey(id)) {
      final collection = _collections[id]!;
      collection.name = newName;
      final channelId = collection.podcastRef?.channelId;
      if (channelId != null) {
        for (final peer in _collections.values) {
          if (peer.podcastRef?.channelId == channelId) peer.name = newName;
        }
      }
      if (updateCoverLabel) {
        collection.coverLabel = coverLabel;
      }
    } else if (_videos.containsKey(id)) {
      final item = _videos[id]!;
      item.title = newName;
      final episodeId = item.sourceRef?.podcast?.episodeId;
      if (episodeId != null) {
        for (final peer in _videos.values) {
          if (peer.sourceRef?.podcast?.episodeId == episodeId) {
            peer.title = newName;
          }
        }
      }
    } else {
      return;
    }
    for (final observer in List<LibraryRenameObserver>.of(_renameObservers)) {
      observer(id, newName);
    }
    await _saveLibrary();
    notifyListeners();
  }

  // --- Size Calculation Helpers ---

  Future<int> calculateItemSize(dynamic item) async {
    final cacheKey = _itemSizeCacheKey(item);
    if (cacheKey == null) return 0;

    final cachedSize = _itemSizeCache[cacheKey];
    if (cachedSize != null) {
      return cachedSize;
    }

    final inFlight = _itemSizeInFlight[cacheKey];
    if (inFlight != null) {
      return inFlight;
    }

    final future = _calculateAndCacheItemSize(item, cacheKey);
    _itemSizeInFlight[cacheKey] = future;
    return future;
  }

  int? getCachedItemSize(dynamic item) {
    final cacheKey = _itemSizeCacheKey(item);
    if (cacheKey == null) return null;
    return _itemSizeCache[cacheKey];
  }

  Future<int> calculateItemsTotalSize(Iterable<dynamic> items) async {
    final selection = items.toList();
    final providedVideos = {
      for (final item in selection.whereType<VideoItem>()) item.id: item,
    };
    final providedCollections = {
      for (final item in selection.whereType<VideoCollection>()) item.id: item,
    };
    final selectedIds = <String>{};
    void collect(String id) {
      if (!selectedIds.add(id)) return;
      final collection = _collections[id] ?? providedCollections[id];
      if (collection != null) {
        for (final child in {
          ...collection.childrenIds,
          ..._collectionChildIdsIncludingRecycled(id),
        }) {
          collect(child);
        }
      }
    }

    for (final item in selection) {
      if (item is VideoItem) collect(item.id);
      if (item is VideoCollection) collect(item.id);
    }
    String key(String path) => Platform.isWindows
        ? p.normalize(path).toLowerCase()
        : p.normalize(path);
    final candidates = <String, String>{};
    void add(String? path) {
      if (path != null && path.isNotEmpty && !path.contains('://')) {
        candidates[key(path)] = path;
      }
    }

    Future<void> directory(String path) async {
      try {
        final root = Directory(path);
        if (!await root.exists() || !await _isSafeAppDataPath(path)) return;
        await for (final entity in root.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) add(entity.path);
        }
      } on FileSystemException {
        /* A cache can disappear during a scan. */
      }
    }

    for (final id in selectedIds) {
      final item = _videos[id] ?? providedVideos[id];
      if (item != null) {
        for (final path in _videoStorageDirectPaths(item)) {
          if ((_isInternalPath(path) && await _isSafeAppDataPath(path)) ||
              (_samePath(path, item.bilibiliDownloadPath ?? item.path) &&
                  (await _isBilibiliExportedCandidate(item) ||
                      await _isDisposableMediaCachePath(path)))) {
            add(path);
          }
        }
        final safeId = id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        for (final folder in [
          'subtitles/tasks',
          'chapter_thumbnails',
          BilibiliVideoShotService.directoryName,
          'ocr_temp',
          if (_isBilibiliStreamItem(item)) 'bilibili_stream_cache',
        ]) {
          await directory(p.join(_dataRootDir.path, folder, safeId));
        }
      }
      final folder = _collections[id] ?? providedCollections[id];
      if (folder?.thumbnailPath != null &&
          _isInternalPath(folder!.thumbnailPath!) &&
          await _isSafeAppDataPath(folder.thumbnailPath!)) {
        add(folder.thumbnailPath);
      }
    }
    // Shared physical files are releasable only when their last owner is in
    // this deletion selection. Parent + child selection never double-counts.
    final owners = _storageFileOwners;
    candidates.removeWhere(
      (path, _) =>
          BilibiliCoverCache.isSharedCoverPath(path) ||
          (owners[path]?.any((id) => !selectedIds.contains(id)) ?? false),
    );
    var total = 0;
    for (final path in candidates.values) {
      total += await _getFileSize(path);
    }
    return total;
  }

  Future<int> _calculateAndCacheItemSize(dynamic item, String cacheKey) async {
    try {
      int size = 0;
      if (item is VideoItem) {
        size = await _calculateVideoItemSize(item);
      } else if (item is VideoCollection) {
        size = await _calculateCollectionSize(item);
      }
      _itemSizeCache[cacheKey] = size;
      return size;
    } finally {
      _itemSizeInFlight.remove(cacheKey);
    }
  }

  Future<int> _calculateVideoItemSize(VideoItem item) async {
    return calculateItemsTotalSize([item]);
  }

  Iterable<String> _videoStorageDirectPaths(VideoItem item) sync* {
    yield item.path;
    yield* <String?>[
      item.playbackPath,
      item.bilibiliDownloadPath,
      item.thumbnailPath,
      item.subtitlePath,
      item.secondarySubtitlePath,
      item.danmakuPath,
      ...?item.additionalSubtitles?.values,
      ...?item.localSubtitles?.values,
      ...?item.recycledSelectedSubtitlePaths,
      ...?item.recycledAdditionalSubtitles?.values,
      ...?item.recycledLocalSubtitles?.values,
      ...item.managedSubtitleAssets.expand((asset) => asset.allFilePaths),
      ...?item.bilibiliVideoShot?.spritePaths,
    ].whereType<String>();
  }

  Map<String, Set<String>> get _storageFileOwners {
    final cached = _storageFileOwnersIndex;
    if (cached != null) return cached;
    final owners = <String, Set<String>>{};
    void add(String path, String id) {
      final key = Platform.isWindows
          ? p.normalize(path).toLowerCase()
          : p.normalize(path);
      owners.putIfAbsent(key, () => <String>{}).add(id);
    }

    for (final item in _videos.values) {
      for (final path in _videoStorageDirectPaths(item)) {
        add(path, item.id);
      }
    }
    for (final folder in _collections.values) {
      if (folder.thumbnailPath != null) add(folder.thumbnailPath!, folder.id);
    }
    return _storageFileOwnersIndex = owners;
  }

  Future<int> _calculateCollectionSize(VideoCollection col) async {
    return calculateItemsTotalSize([col]);
  }

  String? _itemSizeCacheKey(dynamic item) {
    if (item is VideoItem) return 'video:${item.id}';
    if (item is VideoCollection) return 'collection:${item.id}';
    return null;
  }

  void _invalidateSizeCaches() {
    _storageFileOwnersIndex = null;
    _itemSizeCache.clear();
    _itemSizeInFlight.clear();
  }

  void _invalidateVideoSizeCache(String videoId) {
    _storageFileOwnersIndex = null;
    final videoKey = 'video:$videoId';
    _itemSizeCache.remove(videoKey);
    _itemSizeInFlight.remove(videoKey);
    _itemSizeCache.removeWhere((key, _) => key.startsWith('collection:'));
    _itemSizeInFlight.removeWhere((key, _) => key.startsWith('collection:'));
  }

  /// Invalidates filesystem-derived subtitle data after a subtitle file is
  /// created or deleted outside LibraryService (for example by translation).
  void notifySubtitleFilesChanged({String? videoId}) {
    if (videoId == null || videoId.isEmpty) {
      _invalidateSizeCaches();
    } else {
      _invalidateVideoSizeCache(videoId);
    }
    notifyListeners();
  }

  /// Invalidates recycle-bin size labels when the live online cache changes.
  void notifyOnlineCacheChanged(String videoId) {
    if (videoId.isEmpty) {
      _invalidateSizeCaches();
    } else {
      _invalidateVideoSizeCache(videoId);
    }
    super.notifyListeners();
  }

  bool _isBilibiliStreamItem(VideoItem item) {
    return item.path.startsWith('bilibili://stream/') ||
        (item.sourceRef?.kind == MediaSourceKind.bilibiliStream &&
            (item.path.startsWith('https://') ||
                item.path.startsWith('http://')));
  }

  bool _isCloudDriveItem(VideoItem item) =>
      isCloudDriveMedia(source: item.sourceRef, path: item.path);

  int get _maxConcurrentSizeCalculations => Platform.isWindows ? 3 : 2;

  Future<T> _runWithSizeCalculationPermit<T>(
    Future<T> Function() action,
  ) async {
    while (_activeSizeCalculationCount >= _maxConcurrentSizeCalculations) {
      final completer = Completer<void>();
      _sizeCalculationWaitQueue.add(completer);
      await completer.future;
    }

    _activeSizeCalculationCount++;
    try {
      return await action();
    } finally {
      _activeSizeCalculationCount--;
      if (_sizeCalculationWaitQueue.isNotEmpty) {
        _sizeCalculationWaitQueue.removeAt(0).complete();
      }
    }
  }

  String _normalizeCachePath(String path) {
    final normalized = p.normalize(path);
    if (Platform.isWindows) {
      return normalized.toLowerCase();
    }
    return normalized;
  }

  bool _looksLikeBilibiliExportedFile(String path) {
    final name = p.basenameWithoutExtension(path);
    final reg = RegExp(
      r'_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    );
    return reg.hasMatch(name);
  }

  Future<String?> _getBilibiliCustomDownloadPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString('bilibili_custom_download_path');
    if (path == null || path.isEmpty) return null;
    return path;
  }

  Future<bool> _isBilibiliExportedCandidate(VideoItem item) async {
    if (!Platform.isWindows) return item.isBilibiliExported;
    if (item.isBilibiliExported) return true;
    final customPath = await _getBilibiliCustomDownloadPath();
    if (customPath == null) return false;
    if (!p.isWithin(customPath, item.path)) return false;
    return _looksLikeBilibiliExportedFile(item.path);
  }

  bool _isInternalPath(String path) {
    return _internalStorageRootForPath(path) != null;
  }

  Directory? _internalStorageRootForPath(String path) {
    if (!_initialized) return null;
    final storage = AppStorageService.instance;
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        storage.isReady &&
        !storage.desktop) {
      final documents = storage.roots['documents'];
      if (documents != null &&
          AppStorageService.samePath(_dataRootDir.path, documents.path) &&
          p.isWithin(documents.path, path)) {
        // Old iOS catalogs may retain Documents as their data root. Its
        // ordinary user files remain external even with that historical root.
        final first = p.split(p.relative(path, from: documents.path)).first;
        return AppStorageService.ownedNames.contains(first) ? documents : null;
      }
      if (documents != null &&
          p.isWithin(p.join(documents.path, 'imported_media'), path)) {
        // Only this managed child is owned, not the rest of Documents. Keep
        // Documents as the safety anchor so a link at imported_media cannot
        // broaden deletion rights to an external directory.
        return documents;
      }
    }
    if (p.isWithin(_dataRootDir.path, path)) return _dataRootDir;
    return null;
  }

  Future<bool> _isSharedBilibiliSubtitlePath(String path) {
    if (!_initialized) return Future<bool>.value(false);
    return BilibiliSharedSubtitles(
      dataRootOverride: _dataRootDir,
    ).isSharedPath(path);
  }

  BilibiliSharedSubtitles get _sharedBilibiliSubtitles =>
      BilibiliSharedSubtitles(dataRootOverride: _dataRootDir);

  /// Cards that point at the same cloud account, file and revision.
  ///
  /// A different account or a different file revision is not a match, so
  /// official subtitles are not reused across those cards.
  List<VideoItem> cardsOfSameCloudFile(String videoId) {
    final item = _videos[videoId];
    final source = item?.sourceRef?.cloudDrive;
    if (item == null || item.isRecycled || source == null) {
      return const <VideoItem>[];
    }
    final revision = source.revision ?? '';
    return _videos.values
        .where((other) {
          if (other.isRecycled) return false;
          final cloud = other.sourceRef?.cloudDrive;
          if (cloud == null) return false;
          return cloud.sourceKey == source.sourceKey &&
              (cloud.revision ?? '') == revision;
        })
        .toList(growable: false);
  }

  /// Live cards of the same online Bilibili part as [videoId], including it.
  ///
  /// Empty when [videoId] is not an online part. Two cards that merely point
  /// at the same local file are not a part and are never returned together.
  List<VideoItem> cardsOfSameBilibiliPart(String videoId) {
    final item = _videos[videoId];
    if (item == null || item.isRecycled) return const <VideoItem>[];
    final key = bilibiliOnlinePartKey(item);
    if (key == null) return const <VideoItem>[];
    return _videos.values
        .where((other) {
          if (other.isRecycled) return false;
          return bilibiliOnlinePartKey(other) == key;
        })
        .toList(growable: false);
  }

  /// Where a new subtitle of [videoId] is stored.
  ///
  /// Online Bilibili parts share one folder. Every other card keeps its own
  /// task folder, so identical local files stay separate.
  Future<String> allocateSubtitleFile(
    String videoId,
    String preferredFileName,
  ) async {
    final item = _videos[videoId];
    if (item != null && bilibiliOnlinePartKey(item) != null) {
      final path = await _sharedBilibiliSubtitles.allocate(
        item,
        preferredFileName,
      );
      developer.log(
        '字幕写入 B 站分P共享目录 ${bilibiliOnlinePartKey(item)}',
        name: 'subtitles',
      );
      return path;
    }
    return TaskSubtitleStorageService(
      dataRootOverride: _dataRootDir,
    ).allocatePath(videoId, preferredFileName);
  }

  /// True when [path] is this card's own subtitle, or a subtitle of the same
  /// online Bilibili part (shared folder or a sibling card's task folder).
  Future<bool> subtitleFileBelongsToCard(String videoId, String path) async {
    if (!_initialized) return false;
    final storage = TaskSubtitleStorageService(dataRootOverride: _dataRootDir);
    if (await storage.isTaskOwnedPath(path, videoId)) return true;
    final item = _videos[videoId];
    if (item?.sourceRef?.cloudDrive != null) {
      for (final peer in cardsOfSameCloudFile(videoId)) {
        if (await storage.isTaskOwnedPath(path, peer.id)) return true;
      }
      return false;
    }
    if (item == null || bilibiliOnlinePartKey(item) == null) return false;
    if (await _sharedBilibiliSubtitles.containsPath(path, item)) return true;
    for (final card in cardsOfSameBilibiliPart(videoId)) {
      if (card.id == videoId) continue;
      if (await storage.isTaskOwnedPath(path, card.id)) return true;
    }
    return false;
  }

  /// Drops [paths] from this card and, for an online Bilibili part, from every
  /// other card of that part. Does not delete the files.
  Future<void> forgetSubtitleFiles(
    String videoId,
    Iterable<String> paths,
  ) async {
    final keys = paths.map(_normalizeCachePath).toSet();
    if (keys.isEmpty) return;
    final item = _videos[videoId];
    if (item == null) return;
    final part = _videos[videoId]?.sourceRef?.cloudDrive != null
        ? cardsOfSameCloudFile(videoId)
        : cardsOfSameBilibiliPart(videoId);
    final targets = part.isEmpty ? <VideoItem>[item] : part;
    final changed = <VideoItem>[];
    for (final card in targets) {
      if (_stripSubtitlePaths(card, keys)) changed.add(card);
    }
    for (final card in changed) {
      await noteCardDataChanged(card.id);
    }
  }

  bool _stripSubtitlePaths(VideoItem item, Set<String> keys) {
    var changed = false;
    final assets = item.managedSubtitleAssets
        .where((asset) => !keys.contains(_normalizeCachePath(asset.path)))
        .map(
          (asset) =>
              asset.wordTimingPath != null &&
                  keys.contains(_normalizeCachePath(asset.wordTimingPath!))
              ? asset.copyWith(clearWordTimingPath: true)
              : asset,
        )
        .toList(growable: false);
    if (assets.length != item.managedSubtitleAssets.length ||
        item.managedSubtitleAssets.any(
          (asset) =>
              asset.wordTimingPath != null &&
              keys.contains(_normalizeCachePath(asset.wordTimingPath!)),
        )) {
      item.managedSubtitleAssets = assets;
      changed = true;
    }
    Map<String, String>? stripMap(Map<String, String>? source) {
      if (source == null || source.isEmpty) return source;
      final next = <String, String>{};
      for (final entry in source.entries) {
        if (keys.contains(_normalizeCachePath(entry.value))) {
          changed = true;
          continue;
        }
        next[entry.key] = entry.value;
      }
      return next;
    }

    item.additionalSubtitles = stripMap(item.additionalSubtitles);
    item.localSubtitles = stripMap(item.localSubtitles);
    if (item.subtitlePath != null &&
        keys.contains(_normalizeCachePath(item.subtitlePath!))) {
      item.subtitlePath = null;
      item.isSubtitleCached = false;
      changed = true;
    }
    if (item.secondarySubtitlePath != null &&
        keys.contains(_normalizeCachePath(item.secondarySubtitlePath!))) {
      item.secondarySubtitlePath = null;
      item.isSecondarySubtitleCached = false;
      changed = true;
    }
    if (changed) {
      item.lastUpdated = DateTime.now().millisecondsSinceEpoch;
      _invalidateVideoSizeCache(item.id);
    }
    return changed;
  }

  Future<bool> _isSafeAppDataPath(String path) async {
    final ownedRoot = _internalStorageRootForPath(path);
    if (ownedRoot == null) return false;
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        return false;
      }
      final root = await ownedRoot.resolveSymbolicLinks();
      final expected = p.join(root, p.relative(path, from: ownedRoot.path));
      // Permit OS aliases such as iOS /var, while rejecting a link inside the
      // library that points to a different file or another application's data.
      return _samePath(await File(path).resolveSymbolicLinks(), expected);
    } on FileSystemException {
      return false;
    }
  }

  String _thumbnailOutputPath(String videoPath, {String? videoId}) {
    final thumbDir = p.join(_dataRootDir.path, 'thumbnails');
    if (videoId != null && videoId.isNotEmpty) {
      return p.join(thumbDir, "$videoId.jpg");
    }
    final hash = md5.convert(utf8.encode(videoPath)).toString();
    return p.join(thumbDir, "$hash.jpg");
  }

  bool _isMediaFilePathReferencedByOtherVideo(
    String path,
    String currentVideoId,
  ) {
    return _isStoragePathReferencedByOtherItem(path, currentVideoId);
  }

  bool _isThumbnailPathReferencedByOtherVideo(
    String path,
    String currentVideoId,
  ) {
    return _isStoragePathReferencedByOtherItem(path, currentVideoId);
  }

  bool _isStoragePathReferencedByOtherItem(String path, String currentId) {
    final key = Platform.isWindows
        ? p.normalize(path).toLowerCase()
        : p.normalize(path);
    return _storageFileOwners[key]?.any((id) => id != currentId) ?? false;
  }

  bool _subtitleReferencesContainPath(VideoItem item, String path) {
    final directPaths = <String?>[
      item.subtitlePath,
      item.secondarySubtitlePath,
      item.danmakuPath,
      ...?item.additionalSubtitles?.values,
      ...?item.localSubtitles?.values,
      ...?item.recycledSelectedSubtitlePaths,
      ...?item.recycledAdditionalSubtitles?.values,
      ...?item.recycledLocalSubtitles?.values,
      ...item.managedSubtitleAssets.expand((asset) => asset.allFilePaths),
    ];
    for (final candidate in directPaths) {
      if (candidate != null && _samePath(candidate, path)) {
        return true;
      }
    }
    return false;
  }

  bool _samePath(String a, String b) {
    final left = p.normalize(a);
    final right = p.normalize(b);
    if (Platform.isWindows) {
      return left.toLowerCase() == right.toLowerCase();
    }
    return left == right;
  }

  Future<int> _getFileSize(String path) async {
    try {
      return _runWithSizeCalculationPermit(() async {
        final file = File(path);
        if (await file.exists()) {
          return await file.length();
        }
        return 0;
      });
    } catch (e) {
      // ignore
    }
    return 0;
  }

  static String formatSize(int bytes) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(2)} ${suffixes[i]}';
  }
}

class _ArchiveTemporaryStorageStats {
  final List<File> files;
  final List<Directory> directories;
  final int fileCount;
  final int totalBytes;

  const _ArchiveTemporaryStorageStats({
    required this.files,
    required this.directories,
    required this.fileCount,
    required this.totalBytes,
  });
}

const int _maxArchivePathSegmentLength = 120;
const int _defaultMaxArchiveEntryCount = 20000;
const int _defaultMaxArchivePathDepth = 64;
const int _defaultMaxArchiveCompressionRatio = 1000;
const int _mobileMaxArchiveSingleFileBytes = 4 * 1024 * 1024 * 1024;
const int _mobileMaxArchiveTotalBytes = 16 * 1024 * 1024 * 1024;
const int _desktopMaxArchiveSingleFileBytes = 20 * 1024 * 1024 * 1024;
const int _desktopMaxArchiveTotalBytes = 100 * 1024 * 1024 * 1024;

int get _defaultMaxArchiveSingleFileBytes =>
    Platform.isAndroid || Platform.isIOS
    ? _mobileMaxArchiveSingleFileBytes
    : _desktopMaxArchiveSingleFileBytes;

int get _defaultMaxArchiveTotalBytes => Platform.isAndroid || Platform.isIOS
    ? _mobileMaxArchiveTotalBytes
    : _desktopMaxArchiveTotalBytes;

class _ArchiveWriteBudget {
  final int maxTotalBytes;
  int writtenBytes = 0;

  _ArchiveWriteBudget(this.maxTotalBytes);

  void reserve(int byteCount) {
    if (byteCount < 0 || writtenBytes + byteCount > maxTotalBytes) {
      throw StateError(
        '压缩包解压后的媒体总大小超过安全上限 '
        '(${LibraryService.formatSize(maxTotalBytes)})',
      );
    }
    writtenBytes += byteCount;
  }
}

/// Delegates archive output to disk while enforcing both per-file and global
/// byte limits. Archive headers are untrusted, so checking only entry.size is
/// not sufficient for a forged or malformed compressed stream.
class _BudgetedArchiveOutputStream extends OutputStream {
  final OutputFileStream _delegate;
  final _ArchiveWriteBudget _budget;
  final int _maxFileBytes;
  int _writtenForFile = 0;

  _BudgetedArchiveOutputStream(this._delegate, this._budget, this._maxFileBytes)
    : super(byteOrder: _delegate.byteOrder);

  void _reserve(int count) {
    if (count < 0 || _writtenForFile + count > _maxFileBytes) {
      throw StateError(
        '压缩包内单个媒体超过安全上限 '
        '(${LibraryService.formatSize(_maxFileBytes)})',
      );
    }
    _budget.reserve(count);
    _writtenForFile += count;
  }

  @override
  int get length => _delegate.length;

  @override
  bool get isOpen => _delegate.isOpen;

  @override
  void clear() {
    _delegate.clear();
  }

  @override
  void flush() => _delegate.flush();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  Future<void> close() => _delegate.close();

  @override
  void writeByte(int value) {
    _reserve(1);
    _delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _reserve(count);
    _delegate.writeBytes(bytes, length: count);
  }

  @override
  void writeStream(InputStream stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final count = min(chunkSize, stream.length);
      if (count <= 0) {
        break;
      }
      final bytes = stream.readBytes(count).toUint8List();
      writeBytes(bytes);
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);
}

String _buildArchiveEntryOutputPath({
  required String outputRoot,
  required String entryName,
  required bool treatAsFile,
}) {
  final rawSegments = entryName
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (rawSegments.isEmpty) {
    return outputRoot;
  }

  final sanitizedSegments = <String>[];
  for (var i = 0; i < rawSegments.length; i++) {
    final segment = rawSegments[i];
    if (segment == '.' || segment == '..') {
      continue;
    }
    sanitizedSegments.add(
      _sanitizeArchivePathSegment(
        segment,
        preserveExtension: treatAsFile && i == rawSegments.length - 1,
        fallbackName: treatAsFile && i == rawSegments.length - 1
            ? 'file'
            : 'item',
      ),
    );
  }

  if (sanitizedSegments.isEmpty) {
    sanitizedSegments.add(treatAsFile ? 'file' : 'item');
  }
  return p.normalize(p.join(outputRoot, p.joinAll(sanitizedSegments)));
}

/// 在独立 Isolate 中执行文件夹递归扫描，避免阻塞 UI 线程。
///
/// 使用 listSync 同步遍历（Isolate 内同步不影响 UI），返回仅含原始计数的
/// Map，避免跨 Isolate 传递复杂对象。由 [LibraryService.analyzeFolderSelection]
/// 通过 compute() 调用。
Map<String, dynamic> _analyzeFolderSelectionIsolate((String, bool) selection) {
  final (folderPath, filterMediaExtensions) = selection;
  final rootDir = Directory(folderPath);
  var folderCount = 1;
  var mediaFileCount = 0;
  for (final entity in rootDir.listSync(recursive: true, followLinks: false)) {
    if (entity is Directory) {
      folderCount++;
    } else if (entity is File &&
        (!filterMediaExtensions ||
            LibraryService.isSupportedMediaPath(entity.path))) {
      mediaFileCount++;
    }
  }
  return {'folderCount': folderCount, 'mediaFileCount': mediaFileCount};
}

String _sanitizeArchivePathSegment(
  String segment, {
  required bool preserveExtension,
  required String fallbackName,
}) {
  var cleaned = segment
      .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]+'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  cleaned = cleaned.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    cleaned = fallbackName;
  }
  final windowsBaseName = p.basenameWithoutExtension(cleaned).toUpperCase();
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
  ).hasMatch(windowsBaseName)) {
    cleaned = '_$cleaned';
  }
  if (cleaned.length <= _maxArchivePathSegmentLength) {
    return cleaned;
  }

  final hash = md5.convert(utf8.encode(cleaned)).toString().substring(0, 8);
  if (!preserveExtension) {
    final keepLength = _maxArchivePathSegmentLength - hash.length - 1;
    if (keepLength <= 0) {
      return '${fallbackName}_$hash';
    }
    return '${cleaned.substring(0, keepLength)}_$hash';
  }

  final ext = p.extension(cleaned);
  final base = p.basenameWithoutExtension(cleaned);
  final suffix = '_$hash';
  final keepLength = _maxArchivePathSegmentLength - ext.length - suffix.length;
  if (keepLength <= 0) {
    return '$fallbackName$suffix$ext';
  }
  return '${base.substring(0, keepLength)}$suffix$ext';
}

Map<String, int> _extractArchiveToDiskWorker(Map<String, Object?> args) {
  final archivePath = args['archivePath'];
  final destDir = args['destDir'];
  if (archivePath is! String ||
      archivePath.isEmpty ||
      destDir is! String ||
      destDir.isEmpty) {
    throw ArgumentError('missing archivePath or destDir');
  }

  return _extractArchiveToDiskWithParentsSync(
    archivePath: archivePath,
    outputPath: destDir,
    filterMediaExtensions: args['filterMediaExtensions'] as bool? ?? true,
    maxEntryCount: args['maxEntryCount'] as int?,
    maxTotalBytes: args['maxTotalBytes'] as int?,
    maxSingleFileBytes: args['maxSingleFileBytes'] as int?,
    maxPathDepth: args['maxPathDepth'] as int?,
    maxCompressionRatio: args['maxCompressionRatio'] as int?,
  );
}

Map<String, int> _extractArchiveToDiskWithParentsSync({
  required String archivePath,
  required String outputPath,
  bool filterMediaExtensions = true,
  int? maxEntryCount,
  int? maxTotalBytes,
  int? maxSingleFileBytes,
  int? maxPathDepth,
  int? maxCompressionRatio,
}) {
  Directory? tempDir;
  InputStream? inputToClose;
  Archive? archive;
  final normalizedArchivePath = archivePath.toLowerCase();
  var decodedArchivePath = archivePath;
  var extractedEntries = 0;
  var extractedMediaEntries = 0;
  var extractedSubtitleEntries = 0;
  var skippedNonMediaEntries = 0;
  final effectiveMaxEntryCount = maxEntryCount ?? _defaultMaxArchiveEntryCount;
  final effectiveMaxTotalBytes = maxTotalBytes ?? _defaultMaxArchiveTotalBytes;
  final effectiveMaxSingleFileBytes =
      maxSingleFileBytes ?? _defaultMaxArchiveSingleFileBytes;
  final effectiveMaxPathDepth = maxPathDepth ?? _defaultMaxArchivePathDepth;
  final effectiveMaxCompressionRatio =
      maxCompressionRatio ?? _defaultMaxArchiveCompressionRatio;
  if (effectiveMaxEntryCount <= 0 ||
      effectiveMaxTotalBytes <= 0 ||
      effectiveMaxSingleFileBytes <= 0 ||
      effectiveMaxPathDepth <= 0 ||
      effectiveMaxCompressionRatio <= 0) {
    throw ArgumentError('archive extraction limits must be positive');
  }
  final writeBudget = _ArchiveWriteBudget(effectiveMaxTotalBytes);

  try {
    Directory(outputPath).createSync(recursive: true);

    // 两阶段解压：先将压缩层解压为中间 .tar 文件，再解码 tar 流
    if (normalizedArchivePath.endsWith('tar.gz') ||
        normalizedArchivePath.endsWith('tgz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      decodedArchivePath = p.join(tempDir.path, 'temp.tar');
      final input = InputFileStream(archivePath);
      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(decodedArchivePath),
        _ArchiveWriteBudget(effectiveMaxTotalBytes),
        effectiveMaxTotalBytes,
      );
      try {
        GZipDecoder().decodeStream(input, output);
      } finally {
        try {
          input.closeSync();
        } catch (_) {}
        try {
          output.closeSync();
        } catch (_) {}
      }
    } else if (normalizedArchivePath.endsWith('tar.bz2') ||
        normalizedArchivePath.endsWith('tbz') ||
        normalizedArchivePath.endsWith('tbz2')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      decodedArchivePath = p.join(tempDir.path, 'temp.tar');
      final input = InputFileStream(archivePath);
      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(decodedArchivePath),
        _ArchiveWriteBudget(effectiveMaxTotalBytes),
        effectiveMaxTotalBytes,
      );
      try {
        BZip2Decoder().decodeStream(input, output);
      } finally {
        try {
          input.closeSync();
        } catch (_) {}
        try {
          output.closeSync();
        } catch (_) {}
      }
    } else if (normalizedArchivePath.endsWith('tar.xz') ||
        normalizedArchivePath.endsWith('txz')) {
      tempDir = Directory.systemTemp.createTempSync('dart_archive');
      decodedArchivePath = p.join(tempDir.path, 'temp.tar');
      final input = InputFileStream(archivePath);
      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(decodedArchivePath),
        _ArchiveWriteBudget(effectiveMaxTotalBytes),
        effectiveMaxTotalBytes,
      );
      try {
        XZDecoder().decodeStream(input, output);
      } finally {
        try {
          input.closeSync();
        } catch (_) {}
        try {
          output.closeSync();
        } catch (_) {}
      }
    }

    var decodedEntryCount = 0;
    var declaredImportBytes = 0;
    void validateArchiveEntry(ArchiveFile entry) {
      decodedEntryCount++;
      if (decodedEntryCount > effectiveMaxEntryCount) {
        throw StateError('压缩包文件数量超过安全上限 ($effectiveMaxEntryCount)');
      }

      final pathDepth = entry.name
          .split(RegExp(r'[\\/]+'))
          .where((segment) => segment.isNotEmpty)
          .length;
      if (pathDepth > effectiveMaxPathDepth) {
        throw StateError('压缩包目录层级超过安全上限 ($effectiveMaxPathDepth)');
      }

      final isImportableFile =
          !filterMediaExtensions ||
          LibraryService.isSupportedMediaPath(entry.name) ||
          SubtitleFileMatcher.supportedExtensions.contains(
            p.extension(entry.name).toLowerCase(),
          );
      if (entry.isSymbolicLink || !entry.isFile || !isImportableFile) {
        return;
      }

      final entrySize = entry.size;
      if (entrySize < 0 || entrySize > effectiveMaxSingleFileBytes) {
        throw StateError(
          '压缩包内可导入文件超过单文件安全上限 '
          '(${LibraryService.formatSize(effectiveMaxSingleFileBytes)})',
        );
      }
      declaredImportBytes += entrySize;
      if (declaredImportBytes > effectiveMaxTotalBytes) {
        throw StateError(
          '压缩包内可导入文件总大小超过安全上限 '
          '(${LibraryService.formatSize(effectiveMaxTotalBytes)})',
        );
      }

      final compressedSize = entry.rawContent?.length ?? entrySize;
      if (entrySize > 0 &&
          (compressedSize <= 0 ||
              entrySize > compressedSize * effectiveMaxCompressionRatio)) {
        throw StateError('压缩包内可导入文件压缩比异常，已停止导入以保护设备存储');
      }
    }

    final normalizedDecodedPath = decodedArchivePath.toLowerCase();
    if (normalizedDecodedPath.endsWith('.tar')) {
      final input = InputFileStream(decodedArchivePath);
      inputToClose = input;
      archive = TarDecoder().decodeStream(
        input,
        callback: validateArchiveEntry,
      );
    } else if (normalizedDecodedPath.endsWith('.zip')) {
      final input = InputFileStream(decodedArchivePath);
      inputToClose = input;
      archive = ZipDecoder().decodeStream(
        input,
        callback: validateArchiveEntry,
      );
    } else {
      throw ArgumentError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }

    final normalizedOutputRoot = p.normalize(outputPath);
    final claimedOutputPaths = <String, String>{};
    for (final entry in archive) {
      // Media imports do not need archive links. Skipping every symbolic link
      // also prevents a later entry from traversing a link whose lexical path
      // appears to remain inside the extraction root.
      if (entry.isSymbolicLink) {
        continue;
      }
      final normalizedEntryName = entry.name.replaceAll('\\', '/').trim();
      if (normalizedEntryName.isEmpty ||
          normalizedEntryName == '.' ||
          normalizedEntryName == '/' ||
          normalizedEntryName == Platform.pathSeparator) {
        continue;
      }

      final filePath = _buildArchiveEntryOutputPath(
        outputRoot: normalizedOutputRoot,
        entryName: normalizedEntryName,
        treatAsFile: entry.isFile,
      );
      final isSafePath =
          p.equals(normalizedOutputRoot, filePath) ||
          p.isWithin(normalizedOutputRoot, filePath);
      if (!isSafePath) {
        continue;
      }

      final claimKey = Platform.isWindows ? filePath.toLowerCase() : filePath;
      final previousEntryName = claimedOutputPaths[claimKey];
      if (previousEntryName != null) {
        if (entry.isDirectory && previousEntryName == normalizedEntryName) {
          continue;
        }
        throw StateError(
          '压缩包内存在清理后重名的路径：$previousEntryName / $normalizedEntryName',
        );
      }
      claimedOutputPaths[claimKey] = normalizedEntryName;

      if (entry.isDirectory) {
        Directory(filePath).createSync(recursive: true);
        continue;
      }

      final parentDir = Directory(p.dirname(filePath));
      if (!parentDir.existsSync()) {
        parentDir.createSync(recursive: true);
      }

      if (!entry.isFile) {
        continue;
      }

      // Keep media and supported sidecar subtitles. Other archive contents are
      // intentionally not inflated into the app-managed import directory.
      final isMedia =
          !filterMediaExtensions ||
          LibraryService.isSupportedMediaPath(filePath);
      final isSubtitle = SubtitleFileMatcher.supportedExtensions.contains(
        p.extension(filePath).toLowerCase(),
      );
      if (!isMedia && !isSubtitle) {
        skippedNonMediaEntries++;
        continue;
      }

      final output = _BudgetedArchiveOutputStream(
        OutputFileStream(filePath),
        writeBudget,
        effectiveMaxSingleFileBytes,
      );
      try {
        entry.writeContent(output);
      } on FileSystemException catch (e) {
        throw FileSystemException(
          '解压写入失败，可能是压缩包内文件名或路径过长',
          filePath,
          e.osError,
        );
      } finally {
        try {
          output.closeSync();
        } catch (_) {}
      }

      extractedEntries++;
      if (isMedia) extractedMediaEntries++;
      if (isSubtitle) extractedSubtitleEntries++;
    }

    return <String, int>{
      'extractedEntries': extractedEntries,
      'extractedMediaEntries': extractedMediaEntries,
      'extractedSubtitleEntries': extractedSubtitleEntries,
      'skippedNonMediaEntries': skippedNonMediaEntries,
      'writtenBytes': writeBudget.writtenBytes,
    };
  } finally {
    // 严格按顺序释放资源，每个步骤都有独立 try/catch 确保不中断后续清理
    // 1. 先关闭档案对象的内部流
    try {
      archive?.clearSync();
    } catch (_) {}
    // 2. 再关闭输入流
    try {
      inputToClose?.closeSync();
    } catch (_) {}
    // 3. 最后删除中间解压临时目录（tar.gz/bz2/xz 场景）
    if (tempDir != null) {
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    }
  }
}
