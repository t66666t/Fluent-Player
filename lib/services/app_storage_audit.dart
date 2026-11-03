import 'dart:convert';
import '../features/media_cache/media_cache_service.dart';
import 'app_storage_service.dart';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../features/cloud_drive/services/cloud_drive_runtime.dart';
import '../features/cloud_drive/services/cloud_drive_subtitle_tracks.dart';
import '../features/podcasts/podcast_runtime.dart';
import '../features/portable_transfer/portable_transfer_service.dart';
import '../features/progress_sync/folder_transfer_storage.dart';
import '../features/youtube_download/models/youtube_download_models.dart';
import '../features/youtube_download/services/yt_dlp_download_service.dart';
import '../models/bilibili_download_task.dart';
import '../models/managed_subtitle_asset.dart';
import '../models/video_compose_models.dart';
import '../utils/app_data_paths.dart';
import 'bilibili/bilibili_download_service.dart';
import 'bilibili/bilibili_streaming_service.dart';
import 'bilibili/bilibili_video_shot_service.dart';
import 'library_service.dart';
import 'media_playback_service.dart';
import 'ocr_subtitle_manager.dart';
import 'storage_audit_models.dart';
import 'storage_audit_service.dart';
import 'storage_contributors.dart';
import 'transcription_manager.dart';
import 'video_compose_manager.dart';

/// Platform channels and live services stay on the UI isolate. Only a plain
/// path/reference snapshot is sent to the scanner.
class AppStorageAudit {
  AppStorageAudit({
    required this.library,
    this.bilibili,
    this.ytDlp,
    this.streaming,
    this.playback,
    this.transcription,
    this.ocr,
    this.compose,
  }) {
    final root = library.dataRootDirOrNull?.path;
    final cached = _snapshots[library];
    service = StorageAuditService(
      buildInput: buildInput,
      buildDeletionInput: (paths) => buildInput(onlyPaths: paths),
      deletionBlockedReason: deletionBlockedReason,
      fileDeletionBlockedReason: fileDeletionBlockedReason,
      beforeDelete: (file) async {
        await MediaCacheService.instance?.prepareStorageDeletion(file.path);
      },
      initialSnapshot: cached != null && cached.$1 == root ? cached.$2 : null,
      onSnapshot: (snapshot) {
        _snapshots[library] = (library.dataRootDirOrNull?.path, snapshot);
      },
      onDeleted: (paths) async {
        await library.notifyStorageFilesDeleted(paths);
        await MediaCacheService.instance?.forgetDeletedFiles(paths);
        await bilibili?.forgetStorageFiles(paths);
        await ytDlp?.forgetStorageFiles(paths);
        await PortableTransferService.instance.forgetStorageFiles(paths);
        CloudDriveSubtitleTracks.noteStorageFilesDeleted(paths);
      },
      correctIndexes: (paths) async {
        final root = library.dataRootDirOrNull;
        if (root == null) return const ['媒体库尚未加载，索引未校正。'];
        final podcast = PodcastRuntime.instance;
        final artworkOpen = podcast.ready && podcast.artwork != null;
        final warnings = await correctDeletedStorageFiles(
          dataRoot: root,
          deletedPaths: paths,
          skipArtwork: artworkOpen,
        );
        if (artworkOpen) {
          warnings.addAll(await podcast.artwork!.forgetDeletedFiles(paths));
        }
        CloudDriveRuntime.instance?.materialization?.forgetDeletedStorage(
          paths,
        );
        return warnings;
      },
      resourcesChanged: _resourcesChanged,
    );
    final podcast = PodcastRuntime.instance;
    if (podcast.ready) {
      podcast.addListener(_changed);
      _sources.add(podcast);
    }
    for (final source in <ChangeNotifier?>[
      library,
      library.isImporting,
      library.mediaMaterializationService,
      bilibili,
      ytDlp,
      streaming,
      playback,
      transcription,
      ocr,
      compose,
      PortableTransferService.instance,
      FolderTransferStorage.instance,
    ]) {
      if (source != null) {
        source.addListener(_changed);
        _sources.add(source);
      }
    }
    final cacheChanges = MediaCacheService.instance?.storageChanges;
    if (cacheChanges != null) {
      cacheChanges.addListener(_changed);
      _sources.add(cacheChanges);
    }
  }

  final LibraryService library;
  final BilibiliDownloadService? bilibili;
  final YtDlpDownloadService? ytDlp;
  final BilibiliStreamingService? streaming;
  final MediaPlaybackService? playback;
  final TranscriptionManager? transcription;
  final OcrSubtitleManager? ocr;
  final VideoComposeManager? compose;
  late final StorageAuditService service;
  final List<ChangeNotifier> _sources = [];
  // One inventory per live library. Closing a screen cancels its worker but
  // does not discard an already completed inventory or retain old libraries.
  static final _snapshots = Expando<(String?, StorageSnapshot)>();
  int _revision = 0;
  int _snapshotRevision = 0;
  // Selected cleanup refreshes ownership, while the inventory stays at the
  // last full scan until the user refreshes it.
  int _inventoryRevision = 0;
  List<StorageRoot> _lastRoots = [];
  Directory? _lastCache;
  Set<String> _snapshotMaterializationIds = {};
  Set<String> _snapshotLiveKeys = {};
  Directory? _historicalRoot;
  Directory? _lastAppData;

  Set<String> _liveKeys(StorageLiveProtection live) => {
    ...live.podcastEpisodeIds,
    ...live.podcastAssetIds,
    ...live.cloudDirectories,
    if (live.artworkBusy) 'artwork',
  };

  void _changed() => _revision++;

  String? deletionBlockedReason() {
    if (library.dataRootDirOrNull == null) return '媒体库尚未加载完成。';
    return null;
  }

  Future<String?> fileDeletionBlockedReason(StorageFileEntry file) async {
    final cacheReason = MediaCacheService.instance
        ?.storageDeletionBlockedReason(file.path);
    if (cacheReason != null) return cacheReason;
    // Imports have not necessarily committed a card yet. Retain only their
    // input and destination categories, not unrelated playback/export caches.
    if (library.isImporting.value &&
        {
          StorageCategory.orphaned,
          StorageCategory.picker,
          StorageCategory.transfer,
        }.contains(file.category)) {
      return '正在导入媒体，暂时保留导入源与尚未关联的文件。';
    }
    final live = _liveProtection();
    final liveChanged = !setEquals(_snapshotLiveKeys, _liveKeys(live));
    if (_revision == _snapshotRevision &&
        !liveChanged &&
        setEquals(
          _snapshotMaterializationIds,
          library.mediaMaterializationService?.storageItemIdsInUse ??
              <String>{},
        )) {
      return null;
    }
    final data = library.dataRootDirOrNull;
    if (data == null) return '媒体库尚未加载完成。';
    final revision = _revision;
    final ownership = _collectOwnership(data, _lastCache, roots: _lastRoots);
    final inspection = inspectStorageFeatures(
      dataRoot: data,
      appDataRoot: _lastAppData,
      historicalRoot: _historicalRoot,
      systemTemp: Directory.systemTemp,
      live: live,
      cloudOwners: _cloudOwners(),
      onlyPaths: [file.path],
    );
    final input = StorageScanInput(
      roots: [...ownership.roots, ...inspection.roots],
      references: ownership.references,
      protectedPaths: ownership.protectedPaths,
      protectedPrefixes: ownership.protectedPrefixes,
      protectedFilePrefixes: ownership.protectedFilePrefixes,
      assets: [
        ...inspection.assets,
        ...?MediaCacheService.instance?.storageAssets,
      ],
      verifiedPaths: inspection.verifiedPaths,
      minimumTemporaryAge: ownership.minimumTemporaryAge,
    );
    // A progress event elsewhere must not lock this file. Recheck only its
    // current owners/protections rather than walking the whole app again.
    final snapshot = await scanStorageFiles(input, onlyPaths: [file.path]);
    final actual = snapshot.files.firstOrNull;
    if (actual == null || actual.external || actual.category != file.category) {
      return '文件归属已变化，已跳过；可刷新查看最新分类。';
    }
    if (!storageDeletionPermitted(service.activeDeletionAction, actual)) {
      return actual.protection ?? '文件正在使用或被引用。';
    }
    if (actual.ownerIds.any((id) => !file.ownerIds.contains(id))) {
      return '文件归属已变化，已跳过。';
    }
    if (actual.bytes != file.bytes ||
        actual.modifiedMicros != file.modifiedMicros ||
        actual.changedMicros != file.changedMicros) {
      return '文件内容在核对期间发生变化，已跳过。';
    }
    if (_revision != revision) return '核对期间文件引用发生变化，已跳过。';
    return null;
  }

  Future<StorageScanInput> buildInput({List<String>? onlyPaths}) async {
    final data = library.dataRootDirOrNull;
    if (data == null) throw StateError('媒体库尚未加载完成');
    final roots = <StorageRoot>[];
    final warnings = <String>[];
    StoragePlatformUsage? platformUsage;
    Directory? documents;
    Directory? support;
    Directory? cache;
    Future<Directory?> resolve(
      Future<Directory> Function() getter,
      String label,
    ) async {
      try {
        return await getter();
      } catch (error) {
        warnings.add('$label 无法读取：$error');
        return null;
      }
    }

    documents = await resolve(getApplicationDocumentsDirectory, '文档目录');
    support = await resolve(getApplicationSupportDirectory, '应用支持目录');
    cache = await resolve(getTemporaryDirectory, '缓存目录');
    final applicationCache = await resolve(
      getApplicationCacheDirectory,
      '专用缓存目录',
    );
    final mobile = Platform.isAndroid || Platform.isIOS;
    // macOS Documents may be a shared user directory, even in a sandbox.
    final sharedData =
        !mobile &&
        documents != null &&
        storagePathKey(documents.path) == storagePathKey(data.path);
    roots.add(
      StorageRoot(data.path, '媒体库数据', StorageRootKind.data, scoped: sharedData),
    );
    if (documents != null &&
        storagePathKey(documents.path) != storagePathKey(data.path)) {
      roots.add(
        StorageRoot(
          documents.path,
          '历史文档目录',
          StorageRootKind.data,
          scoped: !mobile,
        ),
      );
    }
    if (support != null) {
      roots.add(StorageRoot(support.path, '应用支持文件', StorageRootKind.support));
    }
    if (cache != null) {
      roots.add(
        StorageRoot(cache.path, '应用缓存', StorageRootKind.cache, scoped: !mobile),
      );
    }
    if (applicationCache != null &&
        (cache == null ||
            storagePathKey(applicationCache.path) !=
                storagePathKey(cache.path))) {
      roots.add(
        StorageRoot(applicationCache.path, '应用专用缓存', StorageRootKind.cache),
      );
    }
    // Includes native plugin data, preferences, tmp (iOS) and old files not in
    // the Flutter directory. Only infer a container from two independent
    // path_provider locations; never infer one on desktop.
    if (mobile && documents != null && support != null) {
      final container = documents.parent;
      if (p.isWithin(container.path, support.path) &&
          cache != null &&
          p.isWithin(container.path, cache.path) &&
          (Platform.isIOS || p.basename(documents.path) == 'app_flutter')) {
        roots.add(
          StorageRoot(
            container.path,
            '应用私有容器',
            StorageRootKind.privateContainer,
          ),
        );
        if (Platform.isIOS) {
          roots.add(
            StorageRoot(
              p.join(container.path, 'tmp'),
              '分享与临时文件',
              StorageRootKind.cache,
            ),
          );
        }
      }
    }
    // Cleanup reuses the known native roots. Android's system-wide usage query
    // can take seconds and contributes nothing to deleting selected files.
    if (onlyPaths != null) {
      roots.addAll(service.lastSnapshot?.roots ?? const <StorageRoot>[]);
    }
    if (Platform.isAndroid && onlyPaths == null) {
      try {
        final native =
            await const MethodChannel(
                  'com.example.video_player_app/storage_audit',
                )
                .invokeMapMethod<String, dynamic>('readUsage')
                .timeout(const Duration(seconds: 8));
        final privateRoot = native?['privateRoot'];
        if (privateRoot is String && privateRoot.isNotEmpty) {
          roots.add(
            StorageRoot(
              privateRoot,
              'Android 应用私有容器',
              StorageRootKind.privateContainer,
            ),
          );
        }
        for (final path
            in (native?['externalMediaRoots'] as List? ?? const [])
                .whereType<String>()) {
          roots.add(StorageRoot(path, 'Android 外部媒体文件', StorageRootKind.data));
        }
        if (native?['appBytes'] is int &&
            native?['dataBytes'] is int &&
            native?['cacheBytes'] is int) {
          platformUsage = StoragePlatformUsage(
            appBytes: native!['appBytes'] as int,
            dataBytes: native['dataBytes'] as int,
            cacheBytes: native['cacheBytes'] as int,
            sampledAt: DateTime.fromMillisecondsSinceEpoch(
              native['sampledAt'] as int,
            ),
          );
        }
        if (native?['systemError'] != null) {
          warnings.add('系统占用统计暂不可用：${native!['systemError']}');
        }
      } catch (error) {
        warnings.add('Android 系统占用统计暂不可用：$error');
      }
      try {
        for (final dir
            in await getExternalCacheDirectories() ?? <Directory>[]) {
          roots.add(StorageRoot(dir.path, '外部应用缓存', StorageRootKind.cache));
        }
        for (final dir
            in await getExternalStorageDirectories() ?? <Directory>[]) {
          roots.add(StorageRoot(dir.path, '外部应用文件', StorageRootKind.data));
        }
      } catch (error) {
        warnings.add('外部应用目录无法读取：$error');
      }
    }
    if (documents != null) {
      roots.add(
        StorageRoot(
          p.join(documents.path, 'Fluent Player', 'Exports'),
          'Fluent Player 导出目录',
          StorageRootKind.exports,
        ),
      );
    }
    Directory? appData;
    try {
      appData = await resolveAppDataDirectory();
    } catch (error) {
      warnings.add('应用数据目录无法读取：$error');
    }
    if (appData != null &&
        !roots.any(
          (root) => storagePathKey(root.path) == storagePathKey(appData!.path),
        )) {
      roots.add(
        StorageRoot(
          appData.path,
          '历史配置与任务数据',
          StorageRootKind.data,
          scoped: !mobile,
        ),
      );
    }
    _lastRoots = roots;
    _lastCache = cache;
    _lastAppData = appData;
    final ownership = _collectOwnership(data, cache, roots: roots);
    final inspection = inspectStorageFeatures(
      dataRoot: data,
      appDataRoot: appData,
      historicalRoot: documents,
      systemTemp: Directory.systemTemp,
      live: _liveProtection(),
      cloudOwners: _cloudOwners(),
      onlyPaths: onlyPaths,
    );
    _historicalRoot = documents;
    _snapshotRevision = _revision;
    if (onlyPaths == null) _inventoryRevision = _revision;
    _snapshotMaterializationIds =
        library.mediaMaterializationService?.storageItemIdsInUse ?? <String>{};
    _snapshotLiveKeys = _liveKeys(_liveProtection());
    final registered = AppStorageService.instance;
    final migrationProtected = <String>[];
    if (registered.isReady) {
      for (final entry in registered.roots.entries) {
        if (entry.key.startsWith('feature:')) {
          roots.add(
            StorageRoot(
              entry.value.path,
              '已登记历史资源',
              StorageRootKind.data,
              feature: entry.key.substring('feature:'.length),
            ),
          );
        }
      }
      roots.add(
        StorageRoot(
          registered.controlDirectory.path,
          '存储配置与迁移记录',
          StorageRootKind.support,
          feature: 'storage',
        ),
      );
      migrationProtected.add(registered.controlDirectory.path);
      final journal = File(
        p.join(registered.controlDirectory.path, 'migration.json'),
      );
      if (journal.existsSync()) {
        try {
          final state = jsonDecode(journal.readAsStringSync());
          for (final entry in state['entries'] as List? ?? const []) {
            if (entry is Map && entry['source'] is String) {
              migrationProtected.add(entry['source'] as String);
            }
            if (state['phase'] != 'committed' &&
                entry is Map &&
                entry['target'] is String) {
              migrationProtected.add(entry['target'] as String);
            }
          }
        } catch (_) {
          warnings.add('迁移记录不可读，登记目录仍受保护');
        }
      }
    }
    return StorageScanInput(
      roots: [...roots, ...inspection.roots],
      references: ownership.references,
      protectedPaths: ownership.protectedPaths,
      protectedPrefixes: [
        ...ownership.protectedPrefixes,
        ...migrationProtected,
      ],
      protectedFilePrefixes: ownership.protectedFilePrefixes,
      warnings: [...warnings, ...inspection.warnings],
      minimumTemporaryAge: const Duration(minutes: 10),
      platformUsage: platformUsage,
      assets: [
        ...inspection.assets,
        ...?MediaCacheService.instance?.storageAssets,
      ],
      verifiedPaths: inspection.verifiedPaths,
      sourceVersions: inspection.sourceVersions,
    );
  }

  bool _resourcesChanged() {
    if (_revision != _inventoryRevision) return true;
    final snapshot = service.lastSnapshot;
    if (snapshot == null) return false;
    for (final entry in snapshot.sourceVersions.entries) {
      final file = File(entry.key);
      if (!file.existsSync()) {
        if (entry.value != 0) return true;
        continue;
      }
      final stat = file.statSync();
      final token = stat.modified.microsecondsSinceEpoch ^ stat.size;
      if (token != entry.value) return true;
    }
    return false;
  }

  StorageLiveProtection _liveProtection() {
    final episodes = <String>{};
    final assets = <String>{};
    var artworkBusy = false;
    final podcast = PodcastRuntime.instance;
    if (podcast.ready) {
      final media = podcast.controller.mediaStore;
      episodes.addAll(media.storageProtectedEpisodeIds);
      assets.addAll(media.storageProtectedAssetIds);
      artworkBusy = podcast.artwork?.storagePublishActive ?? false;
    }
    return StorageLiveProtection(
      podcastEpisodeIds: episodes,
      podcastAssetIds: assets,
      cloudDirectories:
          CloudDriveRuntime
              .instance
              ?.materialization
              ?.storageProtectedDirectories ??
          const {},
      artworkBusy: artworkBusy,
    );
  }

  List<StorageCloudOwnerHint> _cloudOwners() {
    return [
      for (final item in library.storageVideos)
        if (item.sourceRef?.cloudDrive case final cloud?)
          StorageCloudOwnerHint(
            itemId: item.id,
            title: item.title,
            providerId: cloud.providerId,
            remoteAccountId: cloud.remoteAccountId,
            driveId: cloud.driveId,
            fileId: cloud.fileId,
            revision: cloud.revision ?? '',
            quality: cloud.preferredQuality ?? '',
          ),
    ];
  }

  StorageScanInput _collectOwnership(
    Directory data,
    Directory? cache, {
    required List<StorageRoot> roots,
  }) {
    final refs = <StorageReference>[];
    final protected = <String>[];
    final prefixes = <String>[];
    final filePrefixes = <String>[];
    void protect(String? path) {
      if (path != null && path.isNotEmpty) protected.add(path);
    }

    void prefix(String path) {
      if (path.isNotEmpty) prefixes.add(path);
    }

    void ref(
      String? path,
      String id,
      String title,
      StorageCategory category, {
      bool recycled = false,
      bool directory = false,
      bool deletable = false,
      StorageOrigin? origin,
      String? subtitleKind,
      String? assetKey,
      StorageAssetRole role = StorageAssetRole.file,
    }) {
      if (path == null ||
          path.isEmpty ||
          path.contains('://') ||
          !p.isAbsolute(path)) {
        return;
      }
      refs.add(
        StorageReference(
          path: path,
          ownerId: id,
          ownerTitle: title,
          category: category,
          directory: directory,
          recycled: recycled,
          deletable: deletable,
          origin: origin,
          subtitleKind: subtitleKind,
          assetKey: assetKey,
          role: role,
        ),
      );
    }

    for (final root in roots.where((r) => r.kind == StorageRootKind.support)) {
      final fonts = p.join(root.path, 'subtitle_fonts');
      prefix(fonts);
      ref(
        fonts,
        'subtitle-font-library',
        '字幕字体',
        StorageCategory.metadata,
        directory: true,
        origin: StorageOrigin.appData,
      );
    }

    final exportRoots = {
      ...PortableTransferService.instance.storageExportRootIdsInUse,
      ...FolderTransferStorage.instance.sourceRoots,
    };
    final exportItems = <String>{...exportRoots};
    if (exportRoots.isNotEmpty) {
      final children = <String, List<String>>{};
      for (final folder in library.storageCollections) {
        final parent = folder.parentId;
        if (parent != null) {
          children.putIfAbsent(parent, () => []).add(folder.id);
        }
      }
      for (final item in library.storageVideos) {
        final parent = item.parentId;
        if (parent != null) children.putIfAbsent(parent, () => []).add(item.id);
      }
      final pending = exportRoots.toList();
      while (pending.isNotEmpty) {
        for (final child in children[pending.removeLast()] ?? <String>[]) {
          if (exportItems.add(child)) pending.add(child);
        }
      }
    }
    for (final item in library.storageVideos) {
      final recycled = library.isStorageItemRecycled(item.id);
      ref(
        item.path,
        item.id,
        item.title,
        StorageCategory.libraryMedia,
        recycled: recycled,
      );
      ref(
        item.playbackPath,
        item.id,
        item.title,
        StorageCategory.compatibility,
        recycled: recycled,
      );
      ref(
        item.thumbnailPath,
        item.id,
        item.title,
        StorageCategory.thumbnails,
        recycled: recycled,
      );
      for (final path in <String?>[
        item.subtitlePath,
        item.secondarySubtitlePath,
        item.danmakuPath,
        ...?item.additionalSubtitles?.values,
        ...?item.localSubtitles?.values,
        ...?item.recycledSelectedSubtitlePaths,
        ...?item.recycledAdditionalSubtitles?.values,
        ...?item.recycledLocalSubtitles?.values,
      ]) {
        ref(
          path,
          item.id,
          item.title,
          StorageCategory.subtitles,
          recycled: recycled,
          origin: _originForStoredPath(path),
        );
      }
      for (final asset in item.managedSubtitleAssets) {
        final kind = _subtitleKind(asset);
        final origin = asset.assetId.startsWith('cloud-official-')
            ? StorageOrigin.cloudDrive
            : _originForStoredPath(asset.path);
        for (final path in asset.allFilePaths) {
          ref(
            path,
            item.id,
            item.title,
            StorageCategory.subtitles,
            recycled: recycled,
            origin: origin,
            subtitleKind: kind,
            assetKey: asset.assetId,
            role: path == asset.wordTimingPath
                ? StorageAssetRole.wordTiming
                : StorageAssetRole.subtitleBody,
          );
        }
        final stamp = File('${asset.path}.stamp');
        if (stamp.existsSync()) {
          ref(
            stamp.path,
            item.id,
            item.title,
            StorageCategory.subtitles,
            recycled: recycled,
            origin: origin,
            subtitleKind: kind,
            assetKey: asset.assetId,
            role: StorageAssetRole.remoteStamp,
          );
        }
      }
      final safeId = item.id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      for (final (folder, category) in [
        ('subtitles/tasks', StorageCategory.subtitles),
        ('chapter_thumbnails', StorageCategory.thumbnails),
        (BilibiliVideoShotService.directoryName, StorageCategory.thumbnails),
        ('bilibili_stream_cache', StorageCategory.streaming),
      ]) {
        ref(
          p.join(data.path, folder, safeId),
          item.id,
          item.title,
          category,
          recycled: recycled,
          directory: true,
        );
      }
      if (playback?.currentItem?.id == item.id ||
          exportItems.contains(item.id)) {
        protect(item.path);
        protect(item.playbackPath);
        protect(item.thumbnailPath);
        for (final path in <String?>[
          item.subtitlePath,
          item.secondarySubtitlePath,
          item.danmakuPath,
          ...?item.additionalSubtitles?.values,
          ...?item.localSubtitles?.values,
          ...item.managedSubtitleAssets.expand((asset) => asset.allFilePaths),
        ]) {
          protect(path);
        }
        prefix(p.join(data.path, 'subtitles', 'tasks', safeId));
        prefix(p.join(data.path, 'bilibili_stream_cache', safeId));
        prefix(
          p.join(data.path, BilibiliVideoShotService.directoryName, safeId),
        );
        prefix(p.join(data.path, 'chapter_thumbnails', safeId));
      }
    }
    for (final folder in library.storageCollections) {
      if (exportItems.contains(folder.id)) protect(folder.thumbnailPath);
      ref(
        folder.thumbnailPath,
        folder.id,
        folder.name,
        StorageCategory.thumbnails,
        recycled: library.isStorageItemRecycled(folder.id),
      );
    }
    if (cache != null) {
      for (final task in bilibili?.tasks ?? <BilibiliDownloadTask>[]) {
        for (final episode in task.videos.expand((v) => v.episodes)) {
          // Completed outputs awaiting import also remain task-owned.
          if (!episode.isExported) {
            final complete = episode.status == DownloadStatus.completed;
            if (!complete) protect(episode.outputPath);
            ref(
              episode.outputPath,
              task.taskId,
              task.title,
              StorageCategory.downloads,
              deletable: complete,
            );
            ref(
              episode.danmakuPath,
              task.taskId,
              task.title,
              StorageCategory.downloads,
              deletable: complete,
            );
          }
          if (episode.status != DownloadStatus.completed ||
              episode.hasResumeData) {
            final key = episode.tempArtifactKey;
            if (key != null && key.isNotEmpty) {
              filePrefixes.add(
                p.join(
                  cache.path,
                  'bbdown_${key.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')}_',
                ),
              );
            }
            for (final resume in [
              episode.videoResumeState,
              episode.audioResumeState,
            ]) {
              if (resume == null) continue;
              protect(resume.tempPath);
              protect('${resume.tempPath}.assembling');
              for (final part in resume.rangeParts) {
                protect(part.tempPath);
              }
            }
          }
        }
      }
      for (final task in ytDlp?.tasks ?? <YtDlpTaskRecord>[]) {
        if (task.status != YtDlpTaskStatus.exported &&
            task.status != YtDlpTaskStatus.cancelled) {
          final complete = task.status == YtDlpTaskStatus.completed;
          if (!complete) {
            protect(task.outputPath);
            for (final path in task.producedPaths) {
              protect(path);
            }
          }
          protect(task.taskThumbnailPath);
          ref(
            task.outputPath,
            task.taskId,
            task.meta?.title ?? task.sourceUrl,
            StorageCategory.downloads,
            deletable: complete,
          );
          if (complete) {
            for (final path in task.producedPaths) {
              ref(
                path,
                task.taskId,
                task.meta?.title ?? task.sourceUrl,
                StorageCategory.downloads,
                deletable: true,
              );
            }
          }
          if (task.request != null && !complete) {
            final template = task.request!.outputTemplate.split('%(').first;
            if (template.isNotEmpty && p.isAbsolute(template)) {
              filePrefixes.add(template);
            } else if (task.status != YtDlpTaskStatus.completed) {
              prefix(task.request!.outputDir);
            }
          }
          final key = task.tempArtifactKey;
          if (!complete && key != null && key.isNotEmpty) {
            filePrefixes.add(
              p.join(
                cache.path,
                'ytdlp_${key.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')}_',
              ),
            );
          }
        }
      }
      for (final task in PortableTransferService.instance.tasks.where(
        (t) => t.isActive,
      )) {
        prefix(p.join(cache.path, 'fluent_transfer', task.id));
        prefix(p.join(cache.path, 'fluent_zip_export', task.id));
      }
      if (transcription?.isProcessing == true) {
        prefix(p.join(cache.path, 'ai_transcription_temp_audio'));
      }
      if (compose?.runningTask != null) {
        prefix(p.join(cache.path, 'compose_fonts'));
        for (final path in compose!.storageArtifactPathsInUse) {
          protect(path);
        }
      }
    }
    for (final path in PortableTransferService.instance.storagePathsInUse) {
      protect(path);
    }
    for (final path
        in PortableTransferService.instance.storageTemporaryDirectoriesInUse) {
      prefix(path);
    }
    for (final path in FolderTransferStorage.instance.directories) {
      prefix(path);
    }
    for (final id in <String>{
      ...?streaming?.cacheItemIdsInUse,
      ...?library.mediaMaterializationService?.storageItemIdsInUse,
    }) {
      prefix(
        p.join(
          data.path,
          'bilibili_stream_cache',
          BilibiliStreamingService.cacheEntryName(id),
        ),
      );
    }
    for (final task in <VideoComposeTaskState>[
      ...?compose?.queuedTasks,
      if (compose?.runningTask != null) compose!.runningTask!,
    ]) {
      protect(task.request.videoPath);
      protect(task.request.outputPath);
      protect(task.request.primarySubtitlePath);
      protect(task.request.secondarySubtitlePath);
      for (final track in task.request.softSubtitleTracks) {
        protect(track.path);
      }
    }
    if (transcription?.isProcessing == true) {
      protect(transcription?.currentVideoPath);
      final id = transcription?.currentVideoId;
      if (id != null) {
        prefix(
          p.join(
            data.path,
            'subtitles',
            'tasks',
            id.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_'),
          ),
        );
      }
    }
    // Installed and partially downloaded models are managed by the model
    // center; generic cache cleanup must never remove them mid-task.
    prefix(p.join(data.path, 'local_models'));
    prefix(p.join(data.path, 'model_jobs'));
    final ocrRecovery = ocr?.pendingRecoveryDirectory;
    if (ocrRecovery != null) prefix(ocrRecovery);
    if (ocr?.isRunning == true) {
      final job = ocr!.job!;
      protect(job.videoPath);
      for (final path in job.outputPaths) {
        protect(path);
      }
      final id = job.videoId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      prefix(p.join(data.path, 'ocr_temp', id));
      prefix(p.join(data.path, 'subtitles', 'tasks', id));
      prefix(p.join(data.path, 'ocr_models'));
    }
    return StorageScanInput(
      roots: roots,
      references: refs,
      protectedPaths: protected,
      protectedPrefixes: prefixes,
      protectedFilePrefixes: filePrefixes,
      minimumTemporaryAge: const Duration(minutes: 10),
    );
  }

  StorageOrigin? _originForStoredPath(String? path) {
    if (path == null) return null;
    final lower = path.replaceAll('\\', '/').toLowerCase();
    if (lower.contains('/podcasts/')) return StorageOrigin.podcast;
    if (lower.contains('/cloud_drive_')) return StorageOrigin.cloudDrive;
    if (lower.contains('/artwork/')) return StorageOrigin.shared;
    return null;
  }

  String _subtitleKind(ManagedSubtitleAsset asset) {
    if (asset.assetId.startsWith('cloud-official-')) {
      return asset.machineGenerated
          ? StorageSubtitleKinds.cloudOfficialAi
          : StorageSubtitleKinds.cloudOfficial;
    }
    return switch (asset.kind) {
      ManagedSubtitleAssetKind.ai => StorageSubtitleKinds.ai,
      ManagedSubtitleAssetKind.translated => StorageSubtitleKinds.translated,
      ManagedSubtitleAssetKind.ocr => StorageSubtitleKinds.ocr,
      ManagedSubtitleAssetKind.imported ||
      ManagedSubtitleAssetKind.manual ||
      ManagedSubtitleAssetKind.embedded ||
      ManagedSubtitleAssetKind.downloaded ||
      ManagedSubtitleAssetKind.cached =>
        asset.machineGenerated
            ? StorageSubtitleKinds.unverified
            : StorageSubtitleKinds.imported,
    };
  }

  void dispose() {
    for (final source in _sources) {
      source.removeListener(_changed);
    }
    service.dispose();
  }
}
