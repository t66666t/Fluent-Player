import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'storage_audit_models.dart';

String storagePathKey(String path) {
  final normalized = p.normalize(p.absolute(path));
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

bool _within(String root, String path) =>
    storagePathKey(root) == storagePathKey(path) ||
    p.isWithin(storagePathKey(root), storagePathKey(path));

const _dataFolders = {
  'imported_videos',
  'imported_media',
  'downloads',
  'exports',
  'imported_archives',
  'bilibili_stream_cache',
  'thumbnails',
  'chapter_thumbnails',
  'bilibili_videoshots',
  'subtitles',
  'danmaku',
  'compatible_audio',
  'ocr_temp',
  'ocr_models',
  'local_models',
  'model_jobs',
  'douyin_downloads',
  'web_media_downloads',
  'batch_import_cache',
  'ai_transcript_cache',
  'video_player_app',
  'yt_dlp_downloads',
  'yt_dlp_task_thumbnails',
  'yt_dlp_cookies',
  'yt_dlp',
  'portable_transfer',
};
const _dataFiles = {
  'library.json',
  'library.json.bak',
  'library.json.tmp',
  'transient_cards.json',
  'bilibili_watch_playlist.json',
  'transcription_queue_cache.json',
  'transcription_slice_checkpoints.json',
  'compose_tasks.json',
  'cloud_drive_accounts.json',
  'cloud_drive_accounts.json.tmp',
  'storage_runtime_registry.json',
  'model_center.json',
  'bilibili_download_tasks.json',
  'media_cache.json',
  'batch_import_state.json',
  'batch_import_cache.json',
  'network_settings_v1.json',
  'playback_state_snapshot.json',
  'progress_sync_v1.enc',
  'shared_preferences.json',
};

// Atomic writes can leave either a staging file or the last good generation.
// Only known records inherit this classification; arbitrary JSON stays unknown.
String _recordName(String name) {
  while (name.endsWith('.tmp') ||
      name.endsWith('.bak') ||
      name.endsWith('.next')) {
    name = name.substring(0, name.length - 4);
  }
  return name;
}

bool _dataFile(String name) => _dataFiles.contains(_recordName(name));

const _metadataFolders = {
  'subtitle_fonts',
  'web_media_browser',
  'web_media_chromium',
  'douyin_browser',
  'douyin_browser_chromium',
  'yt_dlp_cookies',
  'shared_prefs',
  'databases',
  'bilibili_cookies',
  'cookies',
};

/// Registered feature roots retain their logical folder even when the actual
/// location was restored from an older installation or has been renamed.
List<String> _storageParts(StorageRoot? root, String path) {
  if (root == null) return const [];
  final feature = root.feature;
  final folder = switch (feature) {
    'podcast' => 'podcasts',
    'cloudMaterial' => 'cloud_drive_material',
    'cloudSubtitles' => 'cloud_drive_subtitles',
    _ => feature,
  };
  return [
    if (folder != null) folder.toLowerCase(),
    ...p
        .split(p.relative(path, from: root.path))
        .map((part) => part.toLowerCase()),
  ];
}

const _tempFolders = {
  'file_picker',
  'image_picker',
  'incoming_media',
  'picked_subtitles',
  'picked_archives',
  'picked_fluentpacks',
  'fluent_player_portable_imports',
  'fluent_transfer',
  'fluent_zip_export',
  'seek_preview_cache',
  'ai_transcription_temp_audio',
  'compose_fonts',
};

bool _tempName(String name) =>
    name.startsWith('bbdown_') ||
    name.startsWith('ytdlp_') ||
    name.startsWith('yt_dlp_meta_') ||
    name.startsWith('compose_') ||
    name.startsWith('temp_audio_') ||
    name.startsWith('seek_preview_') ||
    RegExp(
      r'^(temp|merged|repaired)_.*\.(mp4|m4s|m4a|srt|ass|ffmeta|part|tmp)(\..*)?$',
    ).hasMatch(name);

bool _scopedChild(StorageRoot root, String name) => switch (root.kind) {
  StorageRootKind.cache => _tempFolders.contains(name) || _tempName(name),
  _ => _dataFolders.contains(name) || _dataFile(name),
};

/// A shared root may enter a child only when the full path was registered.
/// Matching a common folder name such as `podcasts` is not evidence.
bool _scopedEntryAllowed(
  StorageRoot root,
  String entityPath,
  List<String> verified,
) {
  if (root.feature == 'mediaCacheExternal') {
    return verified.any(
      (raw) => storagePathKey(raw) == storagePathKey(entityPath),
    );
  }
  if (_scopedChild(root, p.basename(entityPath).toLowerCase())) return true;
  final key = storagePathKey(entityPath);
  for (final raw in verified) {
    if (raw.isEmpty) continue;
    final verifiedKey = storagePathKey(raw);
    if (key == verifiedKey ||
        _within(raw, entityPath) ||
        _within(entityPath, raw)) {
      return true;
    }
  }
  return false;
}

bool _scopedFileAllowed(StorageRoot root, String path, List<String> verified) {
  if (root.feature == 'mediaCacheExternal') {
    return _scopedEntryAllowed(root, path, verified);
  }
  // Full scans apply the shared-root boundary to the first child before
  // descending. A selected nested file must use that same boundary.
  final first = p.split(p.relative(path, from: root.path)).first;
  return _scopedEntryAllowed(root, p.join(root.path, first), verified);
}

class StorageScanCancelled implements Exception {}

/// One on-demand scan in a cancellable isolate. Enumeration is streamed and
/// stat calls are sequential; neither video contents nor hashes are loaded.
class StorageAuditService {
  StorageAuditService({
    required this.buildInput,
    required this.deletionBlockedReason,
    this.buildDeletionInput,
    this.onDeleted,
    this.beforeDelete,
    this.correctIndexes,
    this.fileDeletionBlockedReason,
    this.onSnapshot,
    this.resourcesChanged,
    StorageSnapshot? initialSnapshot,
  }) : lastSnapshot = initialSnapshot;

  final Future<StorageScanInput> Function() buildInput;
  final Future<StorageScanInput> Function(List<String> paths)?
  buildDeletionInput;
  final String? Function() deletionBlockedReason;
  final Future<void> Function(List<String> paths)? onDeleted;
  final Future<void> Function(StorageFileEntry file)? beforeDelete;

  /// Repairs feature indexes after bytes are gone. Warnings must not erase
  /// the deletion result; a thrown error is reported the same way.
  final Future<List<String>> Function(List<String> paths)? correctIndexes;
  final FutureOr<String?> Function(StorageFileEntry file)?
  fileDeletionBlockedReason;
  final void Function(StorageSnapshot snapshot)? onSnapshot;
  final bool Function()? resourcesChanged;
  StorageSnapshot? lastSnapshot;
  StorageCleanupAction activeDeletionAction = StorageCleanupAction.listed;
  Isolate? _worker;
  ReceivePort? _port;
  Completer<StorageSnapshot>? _pending;
  bool _disposed = false;
  bool _deleting = false;

  Future<StorageSnapshot> scan({
    void Function(int files, int bytes)? onProgress,
  }) async {
    if (_disposed) throw StorageScanCancelled();
    if (_pending != null) return _pending!.future;
    final pending = Completer<StorageSnapshot>();
    _pending = pending;
    try {
      final input = await buildInput();
      if (_disposed) throw StorageScanCancelled();
      final port = ReceivePort();
      _port = port;
      port.listen((message) {
        if (message is StorageSnapshot) {
          if (!pending.isCompleted) pending.complete(message);
          port.close();
        } else if (message is (int, int)) {
          onProgress?.call(message.$1, message.$2);
        } else if (message is String) {
          if (!pending.isCompleted) pending.completeError(StateError(message));
          port.close();
        } else if (!pending.isCompleted) {
          pending.completeError(StateError('存储扫描提前结束：${message ?? '工作线程已退出'}'));
          port.close();
        }
      });
      _worker = await Isolate.spawn(
        _scanWorker,
        (input, port.sendPort),
        onError: port.sendPort,
        onExit: port.sendPort,
      );
      if (_disposed) {
        _worker?.kill(priority: Isolate.immediate);
        throw StorageScanCancelled();
      }
      final snapshot = await pending.future;
      lastSnapshot = snapshot;
      onSnapshot?.call(snapshot);
      return snapshot;
    } catch (error, stackTrace) {
      // All callers waiting on this scan must receive the same failure, even
      // when input collection or isolate creation fails before a port exists.
      if (!pending.isCompleted) pending.completeError(error, stackTrace);
      return await pending.future;
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      _worker = null;
      _port?.close();
      _port = null;
      _pending = null;
    }
  }

  /// Refresh ownership and stats for the confirmed paths only. Cleanup must
  /// never enumerate unrelated files or replace the retained full inventory.
  Future<StorageDeletionResult> delete(
    StorageDeletionPlan plan, {
    void Function(StorageDeletionProgress progress)? onProgress,
  }) async {
    if (_disposed || _deleting) throw StateError('存储管理正在处理，请稍后重试。');
    final blocked = deletionBlockedReason();
    if (blocked != null) throw StateError(blocked);
    _deleting = true;
    activeDeletionAction = plan.action;
    final deleted = <String>[];
    final skipped = <String, String>{};
    final failed = <String, String>{};
    final warnings = <String>[];
    var released = 0;
    var completed = 0;
    final watch = Stopwatch()..start();
    var lastProgress = 0;
    void reportProgress({bool force = false}) {
      if (!force && watch.elapsedMilliseconds - lastProgress < 100) return;
      lastProgress = watch.elapsedMilliseconds;
      onProgress?.call(
        StorageDeletionProgress(
          completedFiles: completed,
          totalFiles: plan.files.length,
          releasedBytes: released,
        ),
      );
    }

    try {
      reportProgress(force: true);
      if (plan.files.isEmpty) {
        return const StorageDeletionResult(
          deletedPaths: [],
          releasedBytes: 0,
          skipped: {},
          failed: {},
        );
      }
      final retained = lastSnapshot;
      final paths = plan.files.map((file) => file.path).toList();
      final input = await (buildDeletionInput?.call(paths) ?? buildInput());
      if (_disposed) throw StorageScanCancelled();
      final fresh = await _scanSelectedFiles(input, paths);
      final current = {for (final f in fresh.files) storagePathKey(f.path): f};
      for (final expected in plan.files) {
        try {
          if (_disposed || deletionBlockedReason() != null) {
            skipped[expected.path] = deletionBlockedReason() ?? '清理已停止';
            continue;
          }
          final actual = current[storagePathKey(expected.path)];
          final ownersGrew =
              actual != null &&
              actual.ownerIds.any((id) => !expected.ownerIds.contains(id));
          if (actual == null ||
              !storageDeletionPermitted(plan.action, expected) ||
              !storageDeletionPermitted(plan.action, actual) ||
              actual.external ||
              actual.category != expected.category ||
              actual.bytes != expected.bytes ||
              actual.modifiedMicros != expected.modifiedMicros ||
              actual.changedMicros != expected.changedMicros ||
              actual.assetVersion != expected.assetVersion ||
              ownersGrew) {
            skipped[expected.path] = ownersGrew
                ? '核对期间出现新的使用者，已跳过'
                : actual != null && actual.assetVersion != expected.assetVersion
                ? '资产版本已变化，已跳过'
                : '文件已变化、被引用或不再允许清理';
            continue;
          }
          try {
            if (!await storageFileMatches(actual)) {
              skipped[expected.path] = '路径或文件已变化';
              continue;
            }
            // Consult live ownership immediately before each exact deletion.
            final reason =
                (_disposed ? '清理已停止' : deletionBlockedReason()) ??
                await fileDeletionBlockedReason?.call(actual);
            if (reason != null) {
              skipped[expected.path] = reason;
              continue;
            }
            await beforeDelete?.call(actual);
            if (beforeDelete != null && !await storageFileMatches(actual)) {
              skipped[expected.path] = '准备清理时文件发生变化';
              continue;
            }
            final stopped = _disposed ? '清理已停止' : deletionBlockedReason();
            if (stopped != null) {
              skipped[expected.path] = stopped;
              continue;
            }
            await File(actual.path).delete();
            if (await FileSystemEntity.type(actual.path, followLinks: false) ==
                FileSystemEntityType.notFound) {
              released += actual.bytes;
              deleted.add(actual.path);
            } else {
              failed[actual.path] = '文件仍存在，未计入释放空间';
            }
          } catch (error) {
            failed[expected.path] = error.toString();
          }
        } finally {
          completed++;
          reportProgress(force: completed == plan.files.length);
        }
      }
      if (deleted.isNotEmpty) {
        try {
          await onDeleted?.call(deleted);
        } catch (error) {
          warnings.add('文件已删除，但引用通知失败：$error');
        }
        try {
          warnings.addAll(await correctIndexes?.call(deleted) ?? const []);
        } catch (error) {
          warnings.add('文件已删除，索引校正失败：$error');
        }
      }
      if (!_disposed) {
        // Subtract only files actually deleted from the existing inventory.
        // Unselected files keep their accounting without another directory walk.
        final snapshot = await _pruneSnapshot(retained ?? fresh, deleted);
        lastSnapshot = snapshot;
        onSnapshot?.call(snapshot);
      }
      return StorageDeletionResult(
        deletedPaths: deleted,
        releasedBytes: released,
        skipped: skipped,
        failed: failed,
        warnings: warnings,
      );
    } finally {
      activeDeletionAction = StorageCleanupAction.listed;
      _deleting = false;
    }
  }

  void dispose() {
    _disposed = true;
    _worker?.kill(priority: Isolate.immediate);
    _port?.close();
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StorageScanCancelled());
    }
  }
}

Future<StorageSnapshot> _scanSelectedFiles(
  StorageScanInput input,
  List<String> paths,
) => Isolate.run(() => scanStorageFiles(input, onlyPaths: paths));

Future<StorageSnapshot> _pruneSnapshot(
  StorageSnapshot snapshot,
  List<String> deleted,
) => Isolate.run(() => storageSnapshotWithoutFiles(snapshot, deleted));

StorageSnapshot storageSnapshotWithoutFiles(
  StorageSnapshot snapshot,
  List<String> deleted,
) {
  final keys = deleted.map(storagePathKey).toSet();
  return StorageSnapshot(
    scannedAt: snapshot.scannedAt,
    files: snapshot.files
        .where((file) => !keys.contains(storagePathKey(file.path)))
        .toList(),
    roots: snapshot.roots,
    warnings: snapshot.warnings,
    sourceVersions: snapshot.sourceVersions,
    // Android's system sample predates deletion. Do not present it as current.
    platformUsage: deleted.isEmpty ? snapshot.platformUsage : null,
  );
}

/// Reject both a substituted file symlink and a substituted parent directory.
Future<bool> storageFileMatches(StorageFileEntry file) async {
  if (!p.isWithin(storagePathKey(file.rootPath), storagePathKey(file.path))) {
    return false;
  }
  var parent = File(file.path).parent;
  while (storagePathKey(parent.path) != storagePathKey(file.rootPath)) {
    if (await FileSystemEntity.type(parent.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return false;
    }
    final next = parent.parent;
    if (next.path == parent.path) return false;
    parent = next;
  }
  if (await FileSystemEntity.type(file.rootPath, followLinks: false) !=
      FileSystemEntityType.directory) {
    return false;
  }
  if (storagePathKey(await Directory(file.rootPath).resolveSymbolicLinks()) !=
      storagePathKey(file.rootPath)) {
    return false;
  }
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    return false;
  }
  final stat = await File(file.path).stat();
  return stat.size == file.bytes &&
      stat.modified.microsecondsSinceEpoch == file.modifiedMicros &&
      stat.changed.microsecondsSinceEpoch == file.changedMicros;
}

Future<void> _scanWorker((StorageScanInput, SendPort) message) async {
  try {
    message.$2.send(
      await scanStorageFiles(
        message.$1,
        onProgress: (n, b) => message.$2.send((n, b)),
      ),
    );
  } catch (error) {
    message.$2.send(error.toString());
  }
}

/// Also callable directly by filesystem tests. All returned paths are canonical.
Future<StorageSnapshot> scanStorageFiles(
  StorageScanInput input, {
  void Function(int, int)? onProgress,
  List<String>? onlyPaths,
}) async {
  final roots = <StorageRoot>[];
  final canonicalRoots = <String, String>{};
  final warnings = [...input.warnings];
  for (final root in input.roots) {
    try {
      if (!await Directory(root.path).exists()) continue;
      final resolved = await Directory(root.path).resolveSymbolicLinks();
      canonicalRoots[storagePathKey(root.path)] = resolved;
      final existing = roots.indexWhere(
        (r) =>
            storagePathKey(r.path) == storagePathKey(resolved) &&
            r.scoped == root.scoped,
      );
      final canonicalRoot = StorageRoot(
        resolved,
        root.label,
        root.kind,
        scoped: root.scoped,
        feature: root.feature,
      );
      if (existing < 0) {
        roots.add(canonicalRoot);
      } else if (roots[existing].feature == null && root.feature != null) {
        roots[existing] = canonicalRoot;
      }
    } catch (error) {
      warnings.add('${root.label}：$error');
    }
  }
  // More specific locations classify files before the private-container root.
  roots.sort((a, b) => b.path.length.compareTo(a.path.length));
  final originalRoots = List<StorageRoot>.of(input.roots)
    ..sort((a, b) => b.path.length.compareTo(a.path.length));
  String canonicalPath(String path) {
    for (final original in originalRoots) {
      if (_within(original.path, path)) {
        final canonical = canonicalRoots[storagePathKey(original.path)];
        if (canonical != null) {
          return p.join(canonical, p.relative(path, from: original.path));
        }
      }
    }
    return path;
  }

  final refs = <String, List<StorageReference>>{};
  final directoryRefs = <String, List<StorageReference>>{};
  for (final ref in input.references) {
    if (!_auditableLocalPath(ref.path)) continue;
    final path = canonicalPath(ref.path);
    final map = ref.directory ? directoryRefs : refs;
    map.putIfAbsent(storagePathKey(path), () => []).add(ref);
  }
  final protected = input.protectedPaths
      .map(canonicalPath)
      .map(storagePathKey)
      .toSet();
  final prefixes = input.protectedPrefixes
      .map(canonicalPath)
      .map(storagePathKey)
      .toList();
  final filePrefixes = input.protectedFilePrefixes
      .map(canonicalPath)
      .map(storagePathKey)
      .toList();
  final verified = input.verifiedPaths.map(canonicalPath).toList();
  final exactAssets = <String, StorageAssetDescriptor>{};
  final directoryAssetMap = <String, StorageAssetDescriptor>{};
  for (final asset in input.assets) {
    for (final path in asset.paths) {
      if (!_auditableLocalPath(path)) continue;
      exactAssets[storagePathKey(canonicalPath(path))] = asset;
    }
    final directory = asset.directory;
    if (directory != null && _auditableLocalPath(directory)) {
      directoryAssetMap[storagePathKey(canonicalPath(directory))] = asset;
    }
  }
  final directoryAssets = directoryAssetMap.values.toList()
    ..sort(
      (a, b) => storagePathKey(
        canonicalPath(b.directory!),
      ).length.compareTo(storagePathKey(canonicalPath(a.directory!)).length),
    );
  StorageAssetDescriptor? assetFor(String path) {
    final exact = exactAssets[storagePathKey(path)];
    if (exact != null) return exact;
    for (final asset in directoryAssets) {
      if (_within(canonicalPath(asset.directory!), path)) return asset;
    }
    return null;
  }

  final files = <StorageFileEntry>[];
  final seen = <String>{};
  final visited = <String>{};
  var total = 0;
  var links = 0;
  final watch = Stopwatch()..start();
  var lastProgress = 0;

  List<StorageReference> ownersFor(String path) {
    final owners = <StorageReference>[...?refs[storagePathKey(path)]];
    var parent = p.dirname(path);
    while (parent != p.dirname(parent)) {
      owners.addAll(directoryRefs[storagePathKey(parent)] ?? const []);
      parent = p.dirname(parent);
    }
    return owners;
  }

  Future<void> addFile(String path, StorageRoot? root) async {
    final key = storagePathKey(path);
    if (!seen.add(key)) return;
    try {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        links++;
        return;
      }
      final stat = await File(path).stat();
      if (stat.type != FileSystemEntityType.file) return;
      final owners = ownersFor(path);
      final described = assetFor(path);
      final classification = _describeFile(path, root, owners, described);
      final busy =
          protected.contains(key) ||
          prefixes.any((prefix) => _within(prefix, path)) ||
          filePrefixes.any(key.startsWith) ||
          described?.protected == true;
      final external = root == null;
      final recent =
          input.minimumTemporaryAge > Duration.zero &&
          !p.basename(path).toLowerCase().endsWith('.fluentpack') &&
          {
            StorageCategory.picker,
            StorageCategory.downloadTemp,
            StorageCategory.workTemp,
            StorageCategory.transfer,
            StorageCategory.orphaned,
            StorageCategory.thumbnails,
          }.contains(classification.category) &&
          DateTime.now().difference(stat.modified) < input.minimumTemporaryAge;
      final safe = !external && !busy && !recent && classification.deletable;
      final explicit =
          !external && !busy && !recent && classification.explicitDelete;
      final ownerIds = {
        ...owners.map((r) => r.ownerId),
        ...?described?.ownerIds,
      }.toList();
      final ownerTitles = {
        ...owners.map((r) => r.ownerTitle),
        if (described != null && described.title.isNotEmpty) described.title,
      }.toList();
      files.add(
        StorageFileEntry(
          path: path,
          rootPath: root?.path ?? '',
          rootLabel: root?.label ?? '外部原文件',
          category: classification.category,
          bytes: stat.size,
          modifiedMicros: stat.modified.microsecondsSinceEpoch,
          changedMicros: stat.changed.microsecondsSinceEpoch,
          ownerIds: ownerIds,
          ownerTitles: ownerTitles,
          canDelete: safe,
          external: external,
          origin: classification.origin,
          sourceTags: classification.sourceTags,
          assetKey: classification.assetKey,
          role: classification.role,
          cleanupPolicy: busy || recent
              ? StorageCleanupPolicy.protected
              : classification.policy,
          subtitleKind: classification.subtitleKind,
          detail: classification.detail,
          explicitDelete: explicit,
          assetVersion: classification.version,
          protection: external
              ? '设备上的外部原文件'
              : busy
              ? described?.protection ?? '任务或播放正在使用 / 需要恢复'
              : recent
              ? '刚生成的文件，稍后重新扫描再清理'
              : safe
              ? null
              : classification.reason,
        ),
      );
      total += external ? 0 : stat.size;
      if (watch.elapsedMilliseconds - lastProgress >= 250) {
        lastProgress = watch.elapsedMilliseconds;
        onProgress?.call(files.length, total);
      }
    } catch (error) {
      warnings.add('$path：$error');
    }
  }

  for (final root in onlyPaths == null ? roots : <StorageRoot>[]) {
    final stack = [(root.path, root.scoped)];
    while (stack.isNotEmpty) {
      final (directory, scoped) = stack.removeLast();
      if (!visited.add('${storagePathKey(directory)}:$scoped')) continue;
      try {
        await for (final entity in Directory(
          directory,
        ).list(followLinks: false)) {
          if (scoped && !_scopedEntryAllowed(root, entity.path, verified)) {
            continue;
          }
          if (entity is Link) {
            links++;
            continue;
          }
          if (entity is Directory) {
            stack.add((entity.path, false));
          } else if (entity is File) {
            final specificRoot =
                roots.where((r) => _within(r.path, entity.path)).firstOrNull ??
                root;
            await addFile(entity.path, specificRoot);
          }
        }
      } catch (error) {
        warnings.add('$directory：$error');
      }
    }
  }
  // Count only explicit external references; never enumerate user directories.
  for (final path in onlyPaths?.map(canonicalPath) ?? refs.keys.toList()) {
    if (seen.contains(path)) continue;
    try {
      if (!await File(path).exists()) continue;
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        links++;
        continue;
      }
      final resolved = await File(path).resolveSymbolicLinks();
      if (storagePathKey(resolved) != storagePathKey(path)) {
        links++;
        continue;
      }
      final root = roots
          .where(
            (r) =>
                _within(r.path, resolved) &&
                (!r.scoped || _scopedFileAllowed(r, resolved, verified)),
          )
          .firstOrNull;
      await addFile(resolved, root);
    } catch (error) {
      warnings.add('$path：$error');
    }
  }
  if (links > 0) warnings.add('跳过 $links 个符号链接，未进入链接目标。');
  files.sort((a, b) => b.bytes.compareTo(a.bytes));
  return StorageSnapshot(
    scannedAt: DateTime.now(),
    files: files,
    roots: roots,
    warnings: warnings,
    platformUsage: input.platformUsage,
    sourceVersions: input.sourceVersions,
  );
}

bool _auditableLocalPath(String path) {
  if (path.isEmpty || !p.isAbsolute(path)) return false;
  final lower = path.toLowerCase();
  if (lower.contains('://') ||
      lower.startsWith('podcast:') ||
      lower.startsWith('cloud-drive:')) {
    return false;
  }
  return true;
}

(StorageCategory, bool, String?) _classify(
  String path,
  StorageRoot? root,
  List<StorageReference> owners,
) {
  final name = p.basename(path).toLowerCase();
  final parts = _storageParts(root, path);
  final first = parts.isEmpty ? '' : parts.first;
  final mediaOwners = owners
      .where(
        (o) =>
            o.category == StorageCategory.libraryMedia ||
            o.category == StorageCategory.compatibility,
      )
      .toList();
  if (mediaOwners.isNotEmpty) {
    final category = mediaOwners.every((o) => o.recycled)
        ? StorageCategory.recycleBin
        : mediaOwners.first.category;
    return (
      category,
      category == StorageCategory.compatibility,
      category == StorageCategory.compatibility ? null : '通过所属卡片管理，防止产生失效的卡片',
    );
  }
  if (first == 'bilibili_stream_cache') {
    final material =
        name.startsWith('materializ') || name.startsWith('transcription_audio');
    return (
      material ? StorageCategory.materialized : StorageCategory.streaming,
      true,
      null,
    );
  }
  if (owners.isNotEmpty && owners.every((o) => o.recycled)) {
    return (StorageCategory.recycleBin, false, '通过回收站永久删除所属卡片');
  }
  if ({
    'thumbnails',
    'chapter_thumbnails',
    'bilibili_videoshots',
    'yt_dlp_task_thumbnails',
  }.contains(first)) {
    return (StorageCategory.thumbnails, true, null);
  }
  if ({'subtitles', 'danmaku'}.contains(first)) {
    if (owners.isEmpty) return (StorageCategory.orphaned, true, null);
    return (StorageCategory.subtitles, false, '已保存的字幕或弹幕，需单独确认后删除');
  }
  if (owners.isNotEmpty &&
      owners.every(
        (o) => o.category == StorageCategory.downloads && o.deletable,
      )) {
    return (StorageCategory.downloads, true, null);
  }
  if (owners.isNotEmpty) return (owners.first.category, false, '被卡片或任务引用');
  if (root?.kind == StorageRootKind.cache &&
      root!.scoped &&
      ({
            'file_picker',
            'image_picker',
            'incoming_media',
            'compose_fonts',
          }.contains(first) ||
          RegExp(
            r'^(temp|merged|repaired|compose|temp_audio|seek_preview)_',
          ).hasMatch(first))) {
    return (StorageCategory.other, false, '位于共享临时目录，无法确认是否属于本应用');
  }
  // Only roots already proven to belong to this application reach here.
  // A filename extension alone never authorizes scanning a shared directory.
  if (first == 'portable_transfer' &&
      parts.length > 2 &&
      parts[1] == 'nearby') {
    return (StorageCategory.transfer, true, null);
  }
  if (name.endsWith('.fluentpack')) {
    return (StorageCategory.transfer, true, null);
  }
  if ({
    'imported_videos',
    'imported_archives',
    'compatible_audio',
  }.contains(first)) {
    return (StorageCategory.orphaned, true, null);
  }
  if ({
    'downloads',
    'web_media_downloads',
    'douyin_downloads',
    'yt_dlp_downloads',
  }.contains(first)) {
    final record = _recordName(name);
    if (record.endsWith('.json') &&
        (parts.contains('tasks') ||
            const {
              'index.json',
              'tasks.json',
              'task.json',
              'manifest.json',
              'resume.json',
              'checkpoint.json',
            }.contains(record))) {
      return (StorageCategory.metadata, false, '下载队列、任务索引和续传记录由对应下载页管理');
    }
    final intermediate =
        parts.contains('tasks') ||
        name.contains('.part') ||
        name.endsWith('.tmp') ||
        name.endsWith('.m4s') ||
        name.endsWith('.seg') ||
        parts.any((part) => part.startsWith('hls_segments_'));
    return intermediate
        ? (StorageCategory.downloadTemp, false, '下载任务和续传数据由对应下载页管理')
        : (
            StorageCategory.downloads,
            first == 'yt_dlp_downloads',
            first == 'yt_dlp_downloads' ? null : '下载成品由对应下载页管理',
          );
  }
  if (first == 'imported_media') {
    return (StorageCategory.orphaned, false, '导入原件需确认引用后管理');
  }
  if (first == 'exports') {
    return (StorageCategory.transfer, false, '用户生成成果需显式删除');
  }
  if (first == 'ocr_temp') return (StorageCategory.workTemp, true, null);
  if (first == 'local_models') {
    return (StorageCategory.models, false, '本地模型与下载断点由模型中心管理');
  }
  if (first == 'model_jobs') {
    if (const {'.wav', '.pcm', '.f32'}.contains(p.extension(name)) ||
        name.startsWith('asr-hotwords-') ||
        parts.any(
          (part) =>
              part.startsWith('asr-gpu-') || part.startsWith('asr-benchmark-'),
        )) {
      return (StorageCategory.workTemp, false, '本地推理、模型测试和硬件加速工作文件由模型中心管理');
    }
    return (StorageCategory.metadata, false, '模型设置、转录和翻译断点由模型中心管理');
  }
  if (first == 'ocr_models') return (StorageCategory.models, true, null);
  if (first == 'yt_dlp' && parts.length > 1 && parts[1] == 'cookies') {
    return (StorageCategory.metadata, false, '下载账号与登录信息由下载功能管理');
  }
  if (first == 'yt_dlp') return (StorageCategory.models, false, '模型和工具由对应功能管理');
  if (first == 'ai_transcript_cache') {
    return (StorageCategory.workTemp, false, 'AI 文稿预处理缓存由 AI 功能管理');
  }
  if (first == 'batch_import_cache') {
    return (StorageCategory.picker, false, '批量导入的工作副本由导入功能管理');
  }
  if (_dataFile(name) ||
      _metadataFolders.contains(first) ||
      first == 'portable_transfer' ||
      (first == 'video_player_app' &&
          parts.length > 1 &&
          parts[1] == 'ai_chat') ||
      (first == 'storage' && root?.kind == StorageRootKind.support)) {
    return (StorageCategory.metadata, false, '设置、账号、索引或任务恢复数据');
  }
  if (root?.kind == StorageRootKind.cache) {
    if ({
      'file_picker',
      'image_picker',
      'incoming_media',
      'picked_subtitles',
    }.contains(first)) {
      return (StorageCategory.picker, true, null);
    }
    if ({
      'picked_archives',
      'picked_fluentpacks',
      'fluent_player_portable_imports',
      'fluent_transfer',
      'fluent_zip_export',
    }.contains(first)) {
      return (StorageCategory.transfer, true, null);
    }
    if ({
          'seek_preview_cache',
          'ai_transcription_temp_audio',
          'compose_fonts',
        }.contains(first) ||
        name.startsWith('compose_') ||
        name.startsWith('temp_audio_') ||
        name.startsWith('seek_preview_')) {
      return (StorageCategory.workTemp, true, null);
    }
    if (_tempName(name)) return (StorageCategory.downloadTemp, true, null);
  }
  if (root?.kind == StorageRootKind.exports) {
    return (StorageCategory.transfer, true, null);
  }
  final hinted = _featureHint(path, root, name);
  if (hinted != null) return hinted;
  return (StorageCategory.other, false, '用途尚未确认，请先核对路径');
}

/// Folder rules apply only inside an application root or a registered feature
/// root. A shared Documents folder with the same name is not classified here.
String? storageFeatureKey(StorageRoot? root, String path) {
  if (root == null) return null;
  if (root.feature != null) {
    return switch (root.feature) {
      'podcasts' => 'podcast',
      'cloud_drive_material' => 'cloudMaterial',
      'cloud_drive_subtitles' => 'cloudSubtitles',
      _ => root.feature,
    };
  }
  if (root.scoped) return null;
  final relative = p.relative(path, from: root.path);
  if (relative == '.') return null;
  final first = p.split(relative).first.toLowerCase();
  final name = p.basename(path).toLowerCase();
  return switch (first) {
    'podcasts' => 'podcast',
    'artwork' => 'artwork',
    'cloud_drive_material' => 'cloudMaterial',
    'cloud_drive_subtitles' => 'cloudSubtitles',
    _ => switch (name) {
      'cloud_drive_accounts.json' ||
      'cloud_drive_accounts.json.tmp' => 'cloudAccounts',
      'transcription_slice_checkpoints.json' => 'checkpoint',
      _ => null,
    },
  };
}

(StorageCategory, bool, String?)? _featureHint(
  String path,
  StorageRoot? root,
  String name,
) {
  switch (storageFeatureKey(root, path)) {
    case 'podcast':
      if (name == 'podcasts.sqlite' ||
          name.endsWith('.sqlite-wal') ||
          name.endsWith('.sqlite-shm')) {
        return (StorageCategory.metadata, false, '播客订阅、目录和任务记录');
      }
      if (name.endsWith('.bak')) {
        return (StorageCategory.metadata, false, '播客数据库升级备份，不是普通缓存');
      }
      if (name.endsWith('.srt') || name.endsWith('.vtt')) {
        return (StorageCategory.subtitles, false, '播客文稿需单独确认后删除');
      }
      if (name.endsWith('.jpg') ||
          name.endsWith('.png') ||
          name.endsWith('.webp')) {
        return (StorageCategory.thumbnails, false, '播客封面可能仍被引用');
      }
      return (StorageCategory.other, false, '播客文件需要索引确认后才能清理');
    case 'artwork':
      if (name.contains('index.sqlite')) {
        return (StorageCategory.metadata, false, '封面索引');
      }
      if (p.split(path).map((part) => part.toLowerCase()).contains('staging')) {
        return (StorageCategory.workTemp, true, null);
      }
      return (StorageCategory.thumbnails, false, '封面缺少可清理证据时按成果保留');
    case 'cloudMaterial':
      if (name == 'media.bin') {
        return (StorageCategory.materialized, false, '网盘素材需确认没有使用者后再清理');
      }
      if (name.contains('.part') ||
          name.endsWith('.tmp') ||
          name == 'init.map' ||
          name.contains('checkpoint') ||
          name.startsWith('seg-')) {
        return (StorageCategory.downloadTemp, false, '网盘续传数据不会按文件年龄清理');
      }
      if (name.endsWith('.json')) {
        return (StorageCategory.metadata, false, '网盘素材记录');
      }
      return (StorageCategory.other, false, '网盘素材用途尚未确认');
    case 'cloudSubtitles':
      return (StorageCategory.subtitles, false, '网盘字幕需确认是否仍是可重新获取的副本');
    case 'cloudAccounts':
      return (StorageCategory.metadata, false, '网盘账号记录不参与缓存清理');
    case 'checkpoint':
      return (StorageCategory.metadata, false, '转写恢复检查点不参与缓存清理');
    case 'cloudLogin':
      return (StorageCategory.workTemp, false, '网盘登录临时目录需有归属标记才能清理');
    default:
      return null;
  }
}

class _DescribedFile {
  const _DescribedFile({
    required this.category,
    required this.deletable,
    required this.explicitDelete,
    required this.reason,
    required this.origin,
    required this.sourceTags,
    required this.policy,
    required this.role,
    this.assetKey,
    this.subtitleKind,
    this.detail,
    this.version = 0,
  });
  final StorageCategory category;
  final bool deletable;
  final bool explicitDelete;
  final String? reason;
  final StorageOrigin origin;
  final List<StorageOrigin> sourceTags;
  final StorageCleanupPolicy policy;
  final StorageAssetRole role;
  final String? assetKey;
  final String? subtitleKind;
  final String? detail;
  final int version;
}

bool _libraryOriginal(List<StorageReference> owners) => owners.any(
  (owner) => owner.category == StorageCategory.libraryMedia && !owner.directory,
);

_DescribedFile _describeFile(
  String path,
  StorageRoot? root,
  List<StorageReference> owners,
  StorageAssetDescriptor? asset,
) {
  final nativeName = p.basename(path).toLowerCase();
  final nativeParts = p.split(path).map((part) => part.toLowerCase());
  if (root != null &&
      !root.scoped &&
      (nativeName.startsWith('cfnetworkdownload_') ||
          nativeParts.contains('com.apple.nsurlsessiond'))) {
    return const _DescribedFile(
      category: StorageCategory.downloadTemp,
      deletable: false,
      explicitDelete: false,
      reason: '系统后台传输持有的暂存文件，由任务完成或取消时释放',
      origin: StorageOrigin.appData,
      sourceTags: [StorageOrigin.appData],
      policy: StorageCleanupPolicy.protected,
      role: StorageAssetRole.resumePart,
      detail: 'URLSession 后台传输',
    );
  }
  final base = _classify(path, root, owners);
  final keepOriginal = _libraryOriginal(owners);
  final category = !keepOriginal && asset != null ? asset.category : base.$1;
  final deletable = !keepOriginal && asset != null ? asset.deletable : base.$2;
  final reason = !keepOriginal && asset != null ? asset.protection : base.$3;
  final origin = !keepOriginal && asset != null
      ? asset.origin
      : _originFor(category, root, path, owners);
  final tags = <StorageOrigin>{
    origin,
    ...owners.map((owner) => owner.origin).whereType<StorageOrigin>(),
    if (asset != null) ...asset.sourceTags,
  };
  final policy = !keepOriginal && asset != null
      ? asset.policy
      : _policyFor(category, deletable);
  final role = _roleFor(path, asset, owners);
  var resolvedCategory = category;
  var resolvedDeletable = deletable;
  var resolvedPolicy = policy;
  var resolvedReason = reason;
  var resolvedExplicit =
      !keepOriginal &&
      (asset?.explicitDelete == true ||
          (policy == StorageCleanupPolicy.savedContent &&
              (category == StorageCategory.subtitles ||
                  category == StorageCategory.offlineDownloads)));
  // Resume fragments stay with an offline asset. A missing index means the
  // file is only an aged residue, which the grace period still protects.
  final feature = storageFeatureKey(root, path);
  if (!keepOriginal &&
      (asset != null ||
          const {
            'podcast',
            'artwork',
            'cloudMaterial',
            'cloudSubtitles',
            'cloudLogin',
          }.contains(feature)) &&
      (role == StorageAssetRole.resumePart ||
          role == StorageAssetRole.partialCommit) &&
      resolvedCategory != StorageCategory.offlineDownloads &&
      resolvedCategory != StorageCategory.metadata &&
      resolvedCategory != StorageCategory.models) {
    resolvedCategory = StorageCategory.downloadTemp;
    if (asset == null || asset.cacheableResidue) {
      resolvedPolicy = StorageCleanupPolicy.regenerableCache;
      resolvedDeletable = asset?.protected != true;
      resolvedExplicit = false;
      resolvedReason = asset?.protected == true ? asset?.protection : null;
    } else {
      resolvedPolicy = StorageCleanupPolicy.featureManaged;
      resolvedDeletable = false;
      resolvedExplicit = asset.protected != true;
      resolvedReason = asset.protected
          ? asset.protection
          : '放弃后续传才会删除；超过十分钟也不代表可以自动清理';
    }
  }
  return _DescribedFile(
    category: resolvedCategory,
    deletable: resolvedDeletable,
    explicitDelete: resolvedExplicit && asset?.protected != true,
    reason: resolvedReason,
    origin: origin,
    sourceTags: tags.toList(),
    policy: resolvedPolicy,
    role: role,
    assetKey:
        asset?.assetKey ??
        owners.map((o) => o.assetKey).whereType<String>().firstOrNull,
    subtitleKind:
        asset?.subtitleKind ??
        owners.map((o) => o.subtitleKind).whereType<String>().firstOrNull,
    detail: asset?.detail,
    version: asset?.version ?? 0,
  );
}

StorageCleanupPolicy _policyFor(StorageCategory category, bool deletable) {
  if (category == StorageCategory.subtitles ||
      category == StorageCategory.offlineDownloads) {
    return StorageCleanupPolicy.savedContent;
  }
  if (category == StorageCategory.metadata ||
      category == StorageCategory.models) {
    return StorageCleanupPolicy.featureManaged;
  }
  if (category == StorageCategory.other) return StorageCleanupPolicy.unknown;
  if (deletable) return StorageCleanupPolicy.regenerableCache;
  return StorageCleanupPolicy.protected;
}

StorageOrigin _originFor(
  StorageCategory category,
  StorageRoot? root,
  String path,
  List<StorageReference> owners,
) {
  final tagged = owners.map((o) => o.origin).whereType<StorageOrigin>().toSet();
  if (tagged.length == 1) return tagged.single;
  final feature = storageFeatureKey(root, path);
  if (feature == 'podcast') return StorageOrigin.podcast;
  if (feature == 'artwork') return StorageOrigin.shared;
  if (feature == 'checkpoint') return StorageOrigin.appData;
  if (feature == 'cloudMaterial' ||
      feature == 'cloudSubtitles' ||
      feature == 'cloudLogin' ||
      feature == 'cloudAccounts') {
    return StorageOrigin.cloudDrive;
  }
  final lower = path.toLowerCase();
  if (lower.contains('bilibili')) return StorageOrigin.bilibili;
  if (lower.contains('yt_dlp') || lower.contains('ytdlp')) {
    return StorageOrigin.ytDlp;
  }
  return switch (category) {
    StorageCategory.libraryMedia ||
    StorageCategory.recycleBin ||
    StorageCategory.compatibility => StorageOrigin.localMedia,
    StorageCategory.metadata || StorageCategory.models => StorageOrigin.appData,
    _ => StorageOrigin.unknown,
  };
}

StorageAssetRole _roleFor(
  String path,
  StorageAssetDescriptor? asset,
  List<StorageReference> owners,
) {
  final name = p.basename(path).toLowerCase();
  if (name.endsWith('.seg')) return StorageAssetRole.mediaSegment;
  if (name.startsWith('complete-')) return StorageAssetRole.assembledMedia;
  if (name.endsWith('.wordtiming.json')) return StorageAssetRole.wordTiming;
  if (name.endsWith('.stamp')) return StorageAssetRole.remoteStamp;
  if (name.endsWith('.partial')) return StorageAssetRole.partialCommit;
  if (name.endsWith('.tmp') || name.contains('.part')) {
    return StorageAssetRole.resumePart;
  }
  if (name == 'manifest.json' || name.contains('checkpoint')) {
    return StorageAssetRole.checkpoint;
  }
  if (name.endsWith('.sqlite')) return StorageAssetRole.database;
  if (name.endsWith('.sqlite-wal') || name.endsWith('.sqlite-shm')) {
    return StorageAssetRole.databaseAuxiliary;
  }
  if (name.endsWith('.bak')) return StorageAssetRole.upgradeBackup;
  final owned = owners
      .map((o) => o.role)
      .where((r) => r != StorageAssetRole.file);
  if (owned.isNotEmpty) return owned.first;
  return asset?.role ?? StorageAssetRole.file;
}
