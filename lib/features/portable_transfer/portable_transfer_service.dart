import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/import_card_placement.dart';
import '../../models/library_activity.dart';
import '../../models/media_source_ref.dart';
import '../../models/video_collection.dart';
import '../../models/video_item.dart';
import '../../models/podcast_source_ref.dart';
import '../podcasts/podcast_runtime.dart';
import '../podcasts/podcast_models.dart';
import '../../services/library_service.dart';
import '../../services/community_media_input.dart';
import '../../services/app_storage_service.dart';
import '../../services/media_materialization_service.dart';
import '../media_cache/bilibili_download_cache.dart';
import '../media_cache/media_cache_models.dart';
import '../media_cache/media_cache_service.dart';
import '../../services/settings_service.dart';
import '../../services/subtitle_word_timing_store.dart';
import '../../services/bilibili/bilibili_video_shot_service.dart';
import 'portable_media_selection.dart';
import 'portable_transfer_models.dart';
import 'sync_media_origin.dart';
import 'zip_media_exporter.dart';

const _maxPortableManifestBytes = 32 * 1024 * 1024;

// Only explicitly journaled staging IDs are passed by the rollback paths
// below. Move them into the bin before using its guarded physical deletion.
Future<void> _deleteTransferStaging(
  LibraryService library,
  List<String> ids,
) async {
  await library.moveToRecycleBin(ids);
  final result = await library.deleteFromRecycleBin(ids);
  if (result.failedIds.isNotEmpty || !result.saved) {
    throw const FormatException('暂存数据未能清理，请保持存储位置可用后重试');
  }
}

class PortableTransferService extends ChangeNotifier {
  PortableTransferService._();

  @visibleForTesting
  PortableTransferService.forTesting();

  static final PortableTransferService instance = PortableTransferService._();
  static const int formatVersion = 6;
  static const String extension = 'fluentpack';
  static const String mimeType = 'application/x-fluent-player-package';
  static const List<String> importPickerExtensions = <String>[
    extension,
    'zip',
    'tar',
    'tgz',
    'gz',
    'tbz',
    'tbz2',
    'bz2',
    'txz',
    'xz',
  ];

  static bool hasPackageExtension(String pathOrName) =>
      p.extension(pathOrName).toLowerCase() == '.$extension';

  final List<PortableTransferTask> _tasks = <PortableTransferTask>[];
  final Map<String, _PortableWorkerControl> _workers =
      <String, _PortableWorkerControl>{};
  final Map<String, _PortableRetrySpec> _retrySpecs =
      <String, _PortableRetrySpec>{};
  final Map<String, Map<String, String>> _receivedFolderMappings = {};
  final Map<String, Map<String, _FolderStagedMedia>> _receivedFolderStaging =
      {};
  bool _receivedMappingsUnavailable = false;
  final Set<String> _storageTemporaryDirectoriesInUse = {};
  Future<void> _receivedMappingWrites = Future<void>.value();
  Future<void> _folderImportChain = Future<void>.value();
  Future<void>? _initialization;
  File? _stateFile;
  Timer? _persistTimer;
  Future<void> _persistChain = Future<void>.value();
  List<PortableTransferTask> get tasks => List.unmodifiable(_tasks);

  /// Private extraction directories still being read by a network import.
  Set<String> get storageTemporaryDirectoriesInUse =>
      Set.unmodifiable(_storageTemporaryDirectoriesInUse);

  /// Exact files used by a live transfer. Historical tasks must never retain
  /// the entire picker directory. Inactive retry sources can be explicitly
  /// cleaned; [forgetStorageFiles] then removes their retry specification.
  Set<String> get storagePathsInUse => {
    for (final task in _tasks.where((task) => task.isActive)) ...[
      if (task.filePath != null) task.filePath!,
      if (_retrySpecs[task.id]?.packagePath != null)
        _retrySpecs[task.id]!.packagePath!,
      if (_retrySpecs[task.id]?.outputPath != null) ...[
        _retrySpecs[task.id]!.outputPath!,
        '${_retrySpecs[task.id]!.outputPath}.part',
      ],
      ...?_retrySpecs[task.id]?.createdAssetPaths,
    ],
  };

  Set<String> get storageExportRootIdsInUse => {
    for (final task in _tasks.where(
      (task) => task.isActive && task.kind == PortableTransferKind.export,
    ))
      ...?_retrySpecs[task.id]?.rootIds,
  };

  Future<void> forgetStorageFiles(List<String> paths) async {
    final deleted = paths.map(_normalizedTaskPath).toSet();
    var changed = false;
    for (final task in _tasks.where((task) => !task.isActive)) {
      final source = _retrySpecs[task.id]?.packagePath;
      if (source != null && deleted.contains(_normalizedTaskPath(source))) {
        _retrySpecs.remove(task.id);
        changed = true;
      }
      final file = task.filePath;
      if (file != null && deleted.contains(_normalizedTaskPath(file))) {
        task.filePath = null;
        task.status = PortableTransferStatus.failed;
        task.error = '文件已在存储空间管理中删除';
        task.subtitle = '文件已清理';
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      await _persistStateNow();
    }
  }

  Future<void> initialize({LibraryService? library}) {
    return _initialization ??= _initializeState(library);
  }

  Future<void> _initializeState(LibraryService? library) async {
    try {
      final support = await getApplicationSupportDirectory();
      final stateDirectory = await Directory(
        p.join(support.path, 'portable_transfer'),
      ).create(recursive: true);
      _stateFile = File(p.join(stateDirectory.path, 'tasks_v1.json'));
      final stateFile = _stateFile!;
      if (await stateFile.exists()) {
        final decoded = jsonDecode(await stateFile.readAsString());
        if (decoded is Map) {
          final rawTasks = decoded['tasks'];
          if (rawTasks is List && _tasks.isEmpty) {
            for (final raw in rawTasks.whereType<Map>()) {
              final task = PortableTransferTask.fromJson(
                Map<String, dynamic>.from(raw),
              );
              if (task.id.isEmpty) continue;
              if (task.isActive) {
                task.status = PortableTransferStatus.failed;
                task.error = '应用在任务完成前退出';
                task.subtitle = '上次运行被中断，可重试';
              }
              _tasks.add(task);
            }
          }
          final rawRetries = decoded['retrySpecs'];
          final rawMappings = decoded['receivedFolderMappings'];
          if (rawMappings is Map) {
            for (final entry in rawMappings.entries) {
              if (entry.value is Map) {
                _receivedFolderMappings[entry.key.toString()] = {
                  for (final item in (entry.value as Map).entries)
                    if (item.key is String && item.value is String)
                      item.key as String: item.value as String,
                };
              }
            }
          }
          if (rawRetries is Map) {
            for (final entry in rawRetries.entries) {
              if (entry.value is Map) {
                _retrySpecs[entry.key.toString()] = _PortableRetrySpec.fromJson(
                  Map<String, dynamic>.from(entry.value as Map),
                );
              }
            }
          }
        }
      }
      final receipts = File(
        p.join(stateDirectory.path, 'folder_receipts_v1.json'),
      );
      if (await receipts.exists()) {
        _receivedMappingsUnavailable = true;
        final decoded = jsonDecode(await receipts.readAsString());
        if (decoded is Map) {
          if (decoded.containsKey('version') && decoded['version'] != 2) {
            throw const FormatException('文件夹恢复记录版本不受支持');
          }
          final mappings = decoded['version'] == 2
              ? decoded['mappings'] as Map? ?? {}
              : decoded;
          for (final entry in mappings.entries) {
            if (entry.value is Map) {
              _receivedFolderMappings[entry.key.toString()] = {
                for (final item in (entry.value as Map).entries)
                  if (item.key is String && item.value is String)
                    item.key as String: item.value as String,
              };
            }
          }
          if (decoded['version'] == 2 && decoded['staging'] is Map) {
            for (final entry in (decoded['staging'] as Map).entries) {
              if (entry.key is! String || entry.value is! Map) continue;
              final pending = <String, _FolderStagedMedia>{};
              for (final item in (entry.value as Map).entries) {
                if (item.key is! String || item.value is! Map) continue;
                final raw = item.value as Map;
                final existingId = raw['existingId'];
                final stagedId = raw['stagedId'];
                if (existingId is! String ||
                    stagedId is! String ||
                    existingId.isEmpty ||
                    stagedId.isEmpty ||
                    existingId == stagedId) {
                  throw const FormatException('文件夹恢复记录损坏');
                }
                pending[item.key as String] = _FolderStagedMedia(
                  existingId: existingId,
                  stagedId: stagedId,
                );
              }
              if (pending.isNotEmpty) {
                _receivedFolderStaging[entry.key as String] = pending;
              }
            }
          }
          _receivedMappingsUnavailable = false;
        }
      }
      if (library != null) {
        await _recoverInterruptedFolderStaging(library);
        for (final entry in _retrySpecs.entries) {
          final task = _tasks.where((item) => item.id == entry.key).firstOrNull;
          final rootId = entry.value.transactionRootId;
          if (task?.status == PortableTransferStatus.failed && rootId != null) {
            try {
              await _deleteTransferStaging(library, <String>[rootId]);
              entry.value.transactionRootId = null;
            } catch (_) {}
          }
          if (task?.status == PortableTransferStatus.failed) {
            await _deleteTrackedAssets(entry.value);
          }
        }
      }
      await _cleanupInterruptedArtifacts();
      await _persistStateNow();
    } catch (_) {
      // Persistence and recovery must never prevent transfers from opening.
    }
    notifyListeners();
  }

  Future<void> _cleanupInterruptedArtifacts() async {
    final referencedSources = _retrySpecs.values
        .where((spec) => spec.kind == PortableTransferKind.import)
        .map((spec) => spec.packagePath)
        .whereType<String>()
        .map(_normalizedTaskPath)
        .toSet();
    final temp = await getTemporaryDirectory();
    final extractionRoot = Directory(p.join(temp.path, 'fluent_transfer'));
    if (await extractionRoot.exists()) {
      try {
        await extractionRoot.delete(recursive: true);
      } catch (_) {}
    }
    final zipScratch = Directory(
      p.join(temp.path, zipExportScratchDirectoryName),
    );
    if (await zipScratch.exists()) {
      try {
        await zipScratch.delete(recursive: true);
      } catch (_) {}
    }
    for (final name in const <String>[
      'fluent_player_portable_imports',
      'picked_fluentpacks',
    ]) {
      final directory = Directory(p.join(temp.path, name));
      if (!await directory.exists()) continue;
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final normalized = _normalizedTaskPath(entity.path);
        if (entity.path.endsWith('.partial') ||
            !referencedSources.contains(normalized)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    for (final spec in _retrySpecs.values) {
      if (spec.kind != PortableTransferKind.export || spec.outputPath == null) {
        continue;
      }
      final partial = File('${spec.outputPath}.part');
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
    try {
      final documents = await getApplicationDocumentsDirectory();
      final exports = Directory(
        p.join(documents.path, 'Fluent Player', 'Exports'),
      );
      if (await exports.exists()) {
        await for (final entity in exports.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.part')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    try {
      final dataRoot = await SettingsService().resolveLargeDataRootDir();
      for (final directory in <Directory>[
        Directory(p.join(dataRoot.path, 'thumbnails')),
        Directory(p.join(dataRoot.path, 'danmaku')),
        Directory(
          p.join(dataRoot.path, BilibiliVideoShotService.directoryName),
        ),
      ]) {
        if (!await directory.exists()) continue;
        await for (final entity in directory.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && entity.path.endsWith('.partial')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _deleteTrackedAssets(_PortableRetrySpec spec) async {
    for (final path in spec.createdAssetPaths.toList(growable: false)) {
      final file = File(path);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {
          continue;
        }
      }
      spec.createdAssetPaths.remove(path);
    }
  }

  void _schedulePersist() {
    if (_stateFile == null) return;
    _persistTimer?.cancel();
    _persistTimer = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_persistStateNow()),
    );
  }

  Future<void> _persistStateNow({
    MapEntry<String, Map<String, dynamic>>? taskOverride,
  }) {
    final stateFile = _stateFile;
    if (stateFile == null) return Future<void>.value();
    final encoded = jsonEncode(<String, dynamic>{
      'tasks': _tasks
          .map(
            (task) => task.id == taskOverride?.key
                ? taskOverride!.value
                : task.toJson(),
          )
          .toList(growable: false),
      'retrySpecs': _retrySpecs.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
      'receivedFolderMappings': _receivedFolderMappings,
    });
    _persistChain = _persistChain
        .then((_) => _writePersistedState(stateFile, encoded))
        .catchError((_) {});
    return _persistChain;
  }

  Future<void> _finishTask(
    PortableTransferTask task,
    PortableTransferStatus status,
    String subtitle,
    String? error,
  ) async {
    // Publishing a terminal status means all readers, cleanup and durable
    // task writes have finished. Polling clients may immediately close us.
    await _persistStateNow(
      taskOverride: MapEntry(task.id, {
        ...task.toJson(),
        'status': status.name,
        'subtitle': subtitle,
        'error': error,
      }),
    );
    task.status = status;
    task.subtitle = subtitle;
    task.error = error;
    notifyListeners();
  }

  Future<void> _writePersistedState(File stateFile, String encoded) async {
    final partial = File('${stateFile.path}.partial');
    try {
      await partial.writeAsString(encoded, flush: true);
      if (await stateFile.exists()) await stateFile.delete();
      await partial.rename(stateFile.path);
    } catch (_) {
      if (await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
    }
  }

  PortableTransferTask _newTask(
    PortableTransferKind kind,
    String title,
    String subtitle,
  ) {
    final task = PortableTransferTask(
      id: const Uuid().v4(),
      kind: kind,
      title: title,
      subtitle: subtitle,
      createdAt: DateTime.now(),
    );
    _tasks.insert(0, task);
    notifyListeners();
    return task;
  }

  void cancel(String id) {
    final task = _tasks.where((item) => item.id == id).firstOrNull;
    if (task == null || !task.isActive) return;
    task.cancelRequested = true;
    task.subtitle = '正在安全停止…';
    ZipExportRuntime.cancel(id);
    _workers[task.id]?.cancel();
    _schedulePersist();
    notifyListeners();
  }

  bool canRetry(String id) {
    final task = _tasks.where((item) => item.id == id).firstOrNull;
    return task != null &&
        !task.isActive &&
        task.status != PortableTransferStatus.completed &&
        _retrySpecs.containsKey(id);
  }

  Future<void> retryTask(String id, LibraryService library) async {
    await initialize(library: library);
    final task = _tasks.where((item) => item.id == id).firstOrNull;
    final spec = _retrySpecs[id];
    if (task == null || spec == null || task.isActive) return;
    task
      ..status = PortableTransferStatus.queued
      ..progress = 0
      ..processedBytes = 0
      ..cancelRequested = false
      ..error = null
      ..subtitle = '正在重新准备…';
    await _persistStateNow();
    notifyListeners();
    if (spec.kind == PortableTransferKind.export) {
      unawaited(
        _runExport(
          task,
          library,
          spec.rootIds!,
          spec.outputPath!,
          spec.options!,
        ),
      );
      return;
    }
    if (spec.transactionRootId != null) {
      try {
        await _deleteTransferStaging(library, <String>[
          spec.transactionRootId!,
        ]);
        spec.transactionRootId = null;
        await _persistStateNow();
      } catch (error) {
        task
          ..status = PortableTransferStatus.failed
          ..subtitle = '清理上次导入失败'
          ..error = error.toString();
        await _persistStateNow();
        notifyListeners();
        return;
      }
    }
    final packagePath = spec.packagePath!;
    if (!await File(packagePath).exists()) {
      task
        ..status = PortableTransferStatus.failed
        ..subtitle = '无法重试'
        ..error = spec.isArchive ? '原始压缩包已不存在' : '原始 FluentPack 文件已不存在';
      await _persistStateNow();
      notifyListeners();
      return;
    }
    if (spec.isArchive) {
      unawaited(
        _runArchiveImport(
          task,
          library,
          packagePath,
          sortOptions: StructuredImportSortOptions(
            field: spec.archiveSortField == 'modifiedTime'
                ? StructuredImportSortField.modifiedTime
                : StructuredImportSortField.fileName,
            direction: spec.archiveSortDirection == 'descending'
                ? StructuredImportSortDirection.descending
                : StructuredImportSortDirection.ascending,
          ),
          deleteArchiveWhenDone: spec.deletePackageWhenDone,
          libraryFolderId: spec.libraryFolderId,
        ),
      );
      return;
    }
    unawaited(
      _runImport(
        task,
        library,
        packagePath,
        deletePackageWhenDone: spec.deletePackageWhenDone,
        libraryFolderId: spec.libraryFolderId,
      ),
    );
  }

  void remove(String id) {
    _tasks.removeWhere((task) => task.id == id && !task.isActive);
    notifyListeners();
  }

  Future<PortableTaskRemovalResult> removeTasks(
    Iterable<String> ids, {
    bool deleteFiles = true,
  }) async {
    final requestedIds = ids.toSet();
    final targets = _tasks
        .where((task) => requestedIds.contains(task.id) && !task.isActive)
        .toList(growable: false);
    if (targets.isEmpty) {
      return const PortableTaskRemovalResult(
        removedTaskCount: 0,
        deletedFileCount: 0,
      );
    }

    final failedPaths = <String>[];
    final failedNormalizedPaths = <String>{};
    var deletedFileCount = 0;
    if (deleteFiles) {
      final paths = targets
          .map((task) => task.filePath?.trim())
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toSet();
      for (final path in paths) {
        final normalized = _normalizedTaskPath(path);
        final file = File(path);
        try {
          if (await file.exists()) {
            await file.delete();
            deletedFileCount++;
          }
        } catch (_) {
          failedPaths.add(path);
          failedNormalizedPaths.add(normalized);
        }
      }
    }

    final removableIds = targets
        .where((task) {
          if (!deleteFiles || failedNormalizedPaths.isEmpty) return true;
          final path = task.filePath?.trim();
          return path == null ||
              path.isEmpty ||
              !failedNormalizedPaths.contains(_normalizedTaskPath(path));
        })
        .map((task) => task.id)
        .toSet();
    _tasks.removeWhere((task) => removableIds.contains(task.id));
    for (final id in removableIds) {
      _retrySpecs.remove(id);
    }
    _schedulePersist();
    notifyListeners();
    return PortableTaskRemovalResult(
      removedTaskCount: removableIds.length,
      deletedFileCount: deletedFileCount,
      failedFilePaths: List<String>.unmodifiable(failedPaths),
    );
  }

  void clearFinished() {
    final removedIds = _tasks
        .where((task) => !task.isActive)
        .map((task) => task.id)
        .toList(growable: false);
    _tasks.removeWhere((task) => removedIds.contains(task.id));
    for (final id in removedIds) {
      _retrySpecs.remove(id);
    }
    _schedulePersist();
    notifyListeners();
  }

  static String _normalizedTaskPath(String path) {
    final normalized = p.normalize(File(path).absolute.path);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  /// Adds [path] without dropping another file that already uses [label].
  static void _rememberSubtitlePath(
    Map<String, String> target,
    String label,
    String path,
  ) {
    if (target.values.any(
      (value) => _normalizedTaskPath(value) == _normalizedTaskPath(path),
    )) {
      return;
    }
    final visible = label.trim().isEmpty ? p.basename(path) : label.trim();
    final existing = target[visible];
    if (existing == null ||
        _normalizedTaskPath(existing) == _normalizedTaskPath(path)) {
      target[visible] = path;
      return;
    }
    final baseName = p.basename(path);
    var key = baseName;
    var serial = 2;
    while (target.containsKey(key)) {
      final extension = p.extension(baseName);
      final stem = p.basenameWithoutExtension(baseName);
      key = '$stem ($serial)$extension';
      serial++;
    }
    target[key] = path;
  }

  /// Estimates local payload without reading the media bytes.
  Future<PortableFolderEstimate> estimateFolderTransfer({
    required LibraryService library,
    required String collectionId,
  }) async {
    final folder = library.getCollection(collectionId);
    if (folder == null || folder.isRecycled) {
      throw const FormatException('文件夹已不存在');
    }
    final task = _folderTask(PortableTransferKind.export, folder.name);
    final leases = <MaterializedMediaLease>[];
    try {
      final plan = await _buildExportPlan(
        library,
        [collectionId],
        PortableExportOptions(packageName: folder.name, wrapInFolder: false),
        task,
        retainedLeases: leases,
        folderTransfer: true,
      );
      return PortableFolderEstimate(
        name: folder.name,
        mediaCount: plan.mediaCount,
        folderCount: (plan.manifest['folderCount'] as int?) ?? 0,
        totalBytes: plan.totalBytes,
      );
    } finally {
      await _releaseSourceLeases(leases);
    }
  }

  Future<PortableFolderFiles> prepareFolderTransferFiles({
    required LibraryService library,
    required String collectionId,
    Set<String>? includeMediaIds,
    bool includeSidecars = true,
    Set<String> skipContentKeys = const {},
    Map<String, PortableFolderFingerprint> knownFingerprints = const {},
    bool Function()? isCancelled,
  }) async {
    final folder = library.getCollection(collectionId);
    if (folder == null || folder.isRecycled) {
      throw const FormatException('文件夹已不存在');
    }
    final task = _folderTask(PortableTransferKind.export, folder.name);
    final timer = _watchFolderCancellation(task, isCancelled);
    final leases = <MaterializedMediaLease>[];
    var handedOff = false;
    try {
      var plan = await _buildExportPlan(
        library,
        [collectionId],
        PortableExportOptions(
          packageName: folder.name,
          wrapInFolder: false,
          includeSidecars: includeSidecars,
        ),
        task,
        retainedLeases: leases,
        folderTransfer: true,
        folderMediaIds: includeMediaIds,
      );
      final fingerprints = <String, PortableFolderFingerprint>{};
      if (skipContentKeys.isNotEmpty || includeMediaIds != null) {
        plan = await _filterFolderTransferPlan(
          plan,
          skipContentKeys,
          knownFingerprints,
          fingerprints,
          task,
          isCancelled,
          includeMediaIds: includeMediaIds,
          retainReusedAssets: true,
          cachedOnly: true,
        );
      }
      final files = <PortableFolderFile>[];
      for (final file in plan.files) {
        if (isCancelled?.call() == true) throw const PortableExportCancelled();
        final stat = await file.file.stat();
        if (stat.type != FileSystemEntityType.file || stat.size != file.size) {
          throw const FormatException('源文件已变化');
        }
        files.add(
          PortableFolderFile(
            path: file.file.path,
            relativePath: file.archivePath,
            size: stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
          ),
        );
      }
      var released = false;
      final prepared = PortableFolderFiles(
        manifest: plan.manifest,
        files: files,
        fingerprints: fingerprints,
        onRelease: () async {
          if (released) return;
          released = true;
          await _releaseSourceLeases(leases);
        },
      );
      handedOff = true;
      return prepared;
    } on _TransferCancelled {
      throw const PortableExportCancelled();
    } finally {
      timer.cancel();
      if (!handedOff) await _releaseSourceLeases(leases);
    }
  }

  Future<PortablePreparedFolderPackage> prepareFolderTransferPackage({
    required LibraryService library,
    required String collectionId,
    required String outputPath,
    Set<String>? includeMediaIds,
    bool includeSidecars = true,
    Map<String, String> stableIds = const {},
    Map<String, dynamic> syncMetadata = const {},
    Set<String> skipContentKeys = const {},
    Map<String, PortableFolderFingerprint> knownFingerprints = const {},
    Future<void> Function(int payloadBytes)? onPayloadSize,
    PortableFolderProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    await initialize(library: library);
    final folder = library.getCollection(collectionId);
    if (folder == null || folder.isRecycled) {
      throw const FormatException('文件夹已不存在');
    }
    final task = _folderTask(PortableTransferKind.export, folder.name);
    final partial = File('$outputPath.part');
    final timer = _watchFolderCancellation(task, isCancelled);
    final leases = <MaterializedMediaLease>[];
    final outputOwnership = ZipExportHandle();
    var outputBound = false;
    void changed() => onProgress?.call(task.progress, task.subtitle);
    addListener(changed);
    try {
      ZipExportRuntime.bind(task.id, outputOwnership, partial.path);
      outputBound = true;
      if (isCancelled?.call() == true) throw const PortableExportCancelled();
      onProgress?.call(0, '正在整理文件');
      var plan = await _buildExportPlan(
        library,
        [collectionId],
        PortableExportOptions(
          packageName: folder.name,
          wrapInFolder: false,
          includeSidecars: includeSidecars,
        ),
        task,
        retainedLeases: leases,
        folderTransfer: true,
        folderMediaIds: includeMediaIds,
      );
      final fingerprints = <String, PortableFolderFingerprint>{};
      if (skipContentKeys.isNotEmpty || includeMediaIds != null) {
        plan = await _filterFolderTransferPlan(
          plan,
          skipContentKeys,
          knownFingerprints,
          fingerprints,
          task,
          isCancelled,
          includeMediaIds: includeMediaIds,
          retainReusedAssets: stableIds.isNotEmpty || includeMediaIds != null,
        );
      }
      final snapshotIds = _snapshotIds(plan.manifest['snapshot'] as Map);
      final filteredStableIds = {
        for (final entry in stableIds.entries)
          if (snapshotIds.contains(entry.key)) entry.key: entry.value,
      };
      _validateStableIds(filteredStableIds, snapshotIds);
      _validateSyncMetadata(syncMetadata);
      plan.manifest['stableIds'] = filteredStableIds;
      plan.manifest['folderSync'] = syncMetadata;
      final verifiedByPath = {
        for (final fingerprint in fingerprints.values)
          fingerprint.path: fingerprint,
      };
      await onPayloadSize?.call(plan.totalBytes);
      if (task.cancelRequested || isCancelled?.call() == true) {
        throw const _TransferCancelled();
      }
      await partial.parent.create(recursive: true);
      if (await partial.exists()) await partial.delete();
      final verified = await _runWorker(
        task: task,
        entryPoint: _portableExportWorker,
        useNetworkProgress: true,
        outputOwnership: outputOwnership,
        payload: {
          'partialPath': partial.path,
          'level': ZipFileEncoder.store,
          'verifyChecksums': true,
          'networkTransfer': true,
          'manifestPath': plan.manifestPath,
          'manifest': plan.manifest,
          'files': [
            for (final file in plan.files)
              {
                'sourcePath': file.file.path,
                'archivePath': file.archivePath,
                'size': file.size,
              },
          ],
          'totalBytes': plan.totalBytes,
          'knownFingerprints': {
            for (final file in plan.files)
              if (verifiedByPath[file.file.path] case final fingerprint?)
                file.archivePath: {
                  'path': fingerprint.path,
                  'size': fingerprint.size,
                  'modified': fingerprint.modifiedMs,
                  'sha256': fingerprint.sha256,
                },
          },
        },
      );
      if (task.cancelRequested || isCancelled?.call() == true) {
        throw const _TransferCancelled();
      }
      final target = File(outputPath);
      if (await target.exists()) await target.delete();
      await partial.rename(outputPath);
      final hashes = verified['checksums'] as Map? ?? {};
      final stats = verified['stats'] as Map? ?? {};
      final snapshot = plan.manifest['snapshot'] as Map;
      for (final record in snapshot['videos'] as List) {
        if (record['isOnline'] == true) continue;
        final ref = (record['video']['path'] as String).substring(7);
        final stat = stats[ref];
        final hash = hashes[ref];
        if (stat is Map && hash is String) {
          fingerprints[record['exportId']
              as String] = PortableFolderFingerprint(
            path: stat['path'] as String,
            size: stat['size'] as int,
            modifiedMs: stat['modified'] as int,
            sha256: hash,
          );
        }
      }
      for (final fingerprint in fingerprints.values) {
        final stat = await File(fingerprint.path).stat();
        if (stat.size != fingerprint.size ||
            stat.modified.millisecondsSinceEpoch != fingerprint.modifiedMs) {
          await target.delete();
          throw const FormatException('准备期间源文件发生变化，请重试');
        }
      }
      onProgress?.call(1, '已准备好发送');
      return PortablePreparedFolderPackage(
        path: outputPath,
        collectionId: collectionId,
        name: folder.name,
        totalBytes: await target.length(),
        mediaCount: plan.mediaCount,
        fingerprints: Map.unmodifiable(fingerprints),
      );
    } on _TransferCancelled {
      throw const PortableExportCancelled();
    } finally {
      timer.cancel();
      removeListener(changed);
      await _cleanupAfterPortableWorker(task, () async {
        try {
          await _releaseSourceLeases(leases);
          if (outputBound && await partial.exists()) await partial.delete();
        } finally {
          if (outputBound) ZipExportRuntime.unbind(task.id, outputOwnership);
        }
      });
    }
  }

  Set<String> _snapshotIds(Map snapshot) => {
    for (final record in [
      ...?snapshot['collections'] as List?,
      ...?snapshot['videos'] as List?,
    ].whereType<Map>())
      if (record['exportId'] is String) record['exportId'] as String,
  };

  Map<String, String> _validateStableIds(Object? raw, Set<String> recordIds) {
    if (raw is! Map || raw.length > 100000) {
      throw const FormatException('同步条目标识无效');
    }
    final result = <String, String>{};
    final unique = <String>{};
    bool valid(Object? id) =>
        id is String &&
        id.isNotEmpty &&
        id.length <= 200 &&
        !RegExp(r'[\x00-\x1f\x7f]').hasMatch(id);
    for (final entry in raw.entries) {
      if (!valid(entry.key) ||
          !valid(entry.value) ||
          !recordIds.contains(entry.key) ||
          !unique.add(entry.value as String)) {
        throw const FormatException('同步条目标识重复或损坏');
      }
      result[entry.key as String] = entry.value as String;
    }
    return result;
  }

  Map<String, dynamic> _validateSyncMetadata(Object? raw) {
    var entries = 0;
    void check(Object? value, int depth) {
      if (++entries > 250000 || depth > 32) {
        throw const FormatException('目录同步信息过大');
      }
      if (value == null ||
          value is String ||
          value is bool ||
          value is int ||
          value is double && value.isFinite) {
        return;
      }
      if (value is List) {
        if (value.length > 100000) throw const FormatException('目录同步信息过大');
        for (final item in value) {
          check(item, depth + 1);
        }
        return;
      }
      if (value is Map && value.keys.every((key) => key is String)) {
        for (final item in value.values) {
          check(item, depth + 1);
        }
        return;
      }
      throw const FormatException('目录同步信息格式无效');
    }

    if (raw is! Map) throw const FormatException('目录同步信息格式无效');
    check(raw, 0);
    final encoded = jsonEncode(raw);
    if (utf8.encode(encoded).length > _maxPortableManifestBytes) {
      throw const FormatException('目录同步信息过大');
    }
    return Map<String, dynamic>.from(jsonDecode(encoded) as Map);
  }

  Future<_ExportPlan> _filterFolderTransferPlan(
    _ExportPlan plan,
    Set<String> skipContentKeys,
    Map<String, PortableFolderFingerprint> knownFingerprints,
    Map<String, PortableFolderFingerprint> verified,
    PortableTransferTask task,
    bool Function()? isCancelled, {
    Set<String>? includeMediaIds,
    bool retainReusedAssets = true,
    bool cachedOnly = false,
  }) async {
    final snapshot = plan.manifest['snapshot'] as Map<String, dynamic>;
    final videos = (snapshot['videos'] as List).cast<Map<String, dynamic>>();
    final byArchivePath = {
      for (final file in plan.files) file.archivePath: file,
    };
    final skipSizes = <int>{};
    for (final key in skipContentKeys) {
      final match = RegExp(r'^sha256:(\d+):[0-9a-f]{64}$').firstMatch(key);
      final size = match == null ? null : int.tryParse(match.group(1)!);
      if (size != null) skipSizes.add(size);
    }
    final remaining = <Map<String, dynamic>>[];
    for (var index = 0; index < videos.length; index++) {
      if (task.cancelRequested || isCancelled?.call() == true) {
        throw const _TransferCancelled();
      }
      final record = videos[index];
      if (includeMediaIds != null &&
          !includeMediaIds.contains(record['exportId'])) {
        continue;
      }
      if (record['isOnline'] == true) {
        remaining.add(record);
        continue;
      }
      final id = record['exportId'] as String;
      final primary = (record['video']['path'] as String).substring(7);
      final file = byArchivePath[primary]!;
      final before = await file.file.stat();
      // A different byte length can never match a receiver's content key.
      if (!skipSizes.contains(before.size)) {
        remaining.add(record);
        continue;
      }
      task.subtitle = '正在比对文件 ${index + 1}/${videos.length}';
      task.progress = (index + 1) / videos.length;
      notifyListeners();
      final cached = knownFingerprints[id];
      if (cachedOnly &&
          (cached == null ||
              cached.path != file.file.path ||
              cached.size != before.size ||
              cached.modifiedMs != before.modified.millisecondsSinceEpoch)) {
        remaining.add(record);
        continue;
      }
      final hash =
          cached != null &&
              cached.path == file.file.path &&
              cached.size == before.size &&
              cached.modifiedMs == before.modified.millisecondsSinceEpoch &&
              RegExp(r'^[0-9a-f]{64}$').hasMatch(cached.sha256)
          ? cached.sha256
          : await _hashFolderMedia(file.file, task);
      final after = await file.file.stat();
      if (after.size != before.size || after.modified != before.modified) {
        throw const FormatException('比对期间源文件发生变化，请重试');
      }
      verified[id] = PortableFolderFingerprint(
        path: file.file.path,
        size: after.size,
        modifiedMs: after.modified.millisecondsSinceEpoch,
        sha256: hash,
      );
      final contentKey = 'sha256:${after.size}:$hash';
      record['contentKey'] = contentKey;
      if (skipContentKeys.contains(contentKey)) {
        record['reuseContent'] = true;
        (record['video'] as Map)['path'] = '@content:$contentKey';
        if (!retainReusedAssets) {
          final video = record['video'] as Map;
          for (final key in [
            'thumbnailPath',
            'subtitlePath',
            'secondarySubtitlePath',
            'danmakuPath',
            'extraSubtitles',
            'localSubtitles',
            'bilibiliVideoShot',
          ]) {
            video[key] = null;
          }
          video['managedSubtitleAssets'] = <dynamic>[];
        }
      }
      remaining.add(record);
    }
    final references = <String>{};
    void collect(Object? value) {
      if (value is String && value.startsWith('@asset:')) {
        references.add(value.substring(7));
      } else if (value is Map) {
        for (final entry in value.values) {
          collect(entry);
        }
      } else if (value is List) {
        for (final entry in value) {
          collect(entry);
        }
      }
    }

    final filteredSnapshot = <String, dynamic>{
      'collections': snapshot['collections'],
      'videos': remaining,
      if (snapshot['podcasts'] != null) 'podcasts': snapshot['podcasts'],
    };
    collect(filteredSnapshot);
    final files = plan.files
        .where((file) => references.contains(file.archivePath))
        .toList(growable: false);
    final totalBytes = files.fold<int>(0, (total, file) => total + file.size);
    return _ExportPlan(
      files: files,
      manifest: {
        ...plan.manifest,
        'snapshot': filteredSnapshot,
        'mediaCount': remaining
            .where((record) => record['reuseContent'] != true)
            .length,
        'fileCount': files.length,
        'totalBytes': totalBytes,
        'checksums': <String, String>{},
      },
      manifestPath: plan.manifestPath,
      mediaCount: remaining
          .where((record) => record['reuseContent'] != true)
          .length,
      totalBytes: totalBytes,
    );
  }

  /// Applies a verified snapshot to a receiving folder. Stable nodes retain
  /// their local card and activity; replaced resources keep a recoverable version.
  Future<PortableReceivedFolder> importFolderTransferPackage({
    required LibraryService library,
    required String packagePath,
    required String originDeviceId,
    required String sourceCollectionId,
    Directory? receivedDirectory,
    Map<String, dynamic>? receivedManifest,
    Map<String, PortableFolderFingerprint> existingFingerprints = const {},
    String? existingTargetCollectionId,
    Map<String, String> stableIds = const {},
    Map<String, String> existingLocalIds = const {},
    Set<String> suppressedNodeIds = const {},
    Set<String> protectedNodeIds = const {},
    PortableFolderProtection? resolveProtectedNodeIds,
    Future<void> Function(int bytes)? beforeExtraLocalCopy,
    bool reconcileStructure = false,
    PortableFolderProgress? onProgress,
    bool Function()? isCancelled,
  }) {
    final operation = _folderImportChain.then(
      (_) => _importFolderTransferPackage(
        library: library,
        packagePath: packagePath,
        originDeviceId: originDeviceId,
        sourceCollectionId: sourceCollectionId,
        receivedDirectory: receivedDirectory,
        receivedManifest: receivedManifest,
        existingFingerprints: existingFingerprints,
        existingTargetCollectionId: existingTargetCollectionId,
        stableIds: stableIds,
        existingLocalIds: existingLocalIds,
        suppressedNodeIds: suppressedNodeIds,
        protectedNodeIds: protectedNodeIds,
        resolveProtectedNodeIds: resolveProtectedNodeIds,
        beforeExtraLocalCopy: beforeExtraLocalCopy,
        reconcileStructure: reconcileStructure,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
    _folderImportChain = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  Future<PortableReceivedFolder> _importFolderTransferPackage({
    required LibraryService library,
    required String packagePath,
    required String originDeviceId,
    required String sourceCollectionId,
    Directory? receivedDirectory,
    Map<String, dynamic>? receivedManifest,
    Map<String, PortableFolderFingerprint> existingFingerprints = const {},
    String? existingTargetCollectionId,
    Map<String, String> stableIds = const {},
    Map<String, String> existingLocalIds = const {},
    Set<String> suppressedNodeIds = const {},
    Set<String> protectedNodeIds = const {},
    PortableFolderProtection? resolveProtectedNodeIds,
    Future<void> Function(int bytes)? beforeExtraLocalCopy,
    bool reconcileStructure = false,
    PortableFolderProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (originDeviceId.isEmpty || sourceCollectionId.isEmpty) {
      throw const FormatException('缺少来源设备或文件夹');
    }
    await initialize(library: library);
    if (_receivedMappingsUnavailable) {
      throw const FormatException('文件夹恢复记录无法读取，请更新应用后重试');
    }
    await _recoverInterruptedFolderStaging(library);
    final task = _folderTask(PortableTransferKind.import, '接收文件夹');
    final temp = await getTemporaryDirectory();
    // Network receive passes its own directory. This import must not delete it:
    // a failure after the file landed still needs those bytes for recovery.
    // Fluentpack imports create the directory and still remove it here.
    final ownsExtraction = receivedDirectory == null;
    final extraction =
        receivedDirectory ??
        await Directory(
          p.join(temp.path, 'fluent_transfer', task.id),
        ).create(recursive: true);
    _storageTemporaryDirectoriesInUse.add(extraction.path);
    notifyListeners();
    final timer = _watchFolderCancellation(task, isCancelled);
    void changed() => onProgress?.call(task.progress, task.subtitle);
    addListener(changed);
    try {
      if (isCancelled?.call() == true) throw const PortableExportCancelled();
      final manifest =
          receivedManifest ??
          await _runWorker(
            task: task,
            entryPoint: _portableImportWorker,
            useNetworkProgress: true,
            payload: {
              'packagePath': packagePath,
              'extractionPath': extraction.path,
              'supportedVersion': formatVersion,
              'networkTransfer': true,
            },
          );
      if (task.cancelRequested || isCancelled?.call() == true) {
        throw const _TransferCancelled();
      }
      final snapshot = manifest['snapshot'];
      if (snapshot is! Map) throw const FormatException('接收的文件夹缺少快照');
      final nodeIds = _validateStableIds(
        stableIds.isEmpty ? manifest['stableIds'] ?? {} : stableIds,
        _snapshotIds(snapshot),
      );
      final metadata = _validateSyncMetadata(manifest['folderSync'] ?? {});
      final protectedIds = {
        ...protectedNodeIds,
        if (resolveProtectedNodeIds != null)
          ...await resolveProtectedNodeIds(metadata),
      };
      if (task.cancelRequested || isCancelled?.call() == true) {
        throw const _TransferCancelled();
      }
      final sourceKey = jsonEncode([originDeviceId, sourceCollectionId]);
      final context = _FolderImportContext(
        sourceCollectionId: sourceCollectionId,
        idMap: Map.of(_receivedFolderMappings[sourceKey] ?? {}),
        stagedMedia: _receivedFolderStaging.putIfAbsent(sourceKey, () => {}),
        requestedTargetId: existingTargetCollectionId,
        checksums: Map<String, dynamic>.from(
          manifest['checksums'] as Map? ?? {},
        ),
        existingFingerprints: existingFingerprints,
        beforeExtraLocalCopy: beforeExtraLocalCopy,
        persistMapping: _persistReceivedMappings,
        isCancelled: isCancelled,
        stableIds: nodeIds,
        existingLocalIds: existingLocalIds,
        suppressedNodeIds: suppressedNodeIds,
        protectedNodeIds: protectedIds,
        reconcileStructure: reconcileStructure,
      );
      _receivedFolderMappings[sourceKey] = context.idMap;
      await _importSnapshot(
        library: library,
        extraction: extraction,
        packageName: manifest['packageName']?.toString() ?? '接收的文件夹',
        snapshot: Map<String, dynamic>.from(snapshot),
        task: task,
        network: context,
      );
      _receivedFolderMappings[sourceKey] = Map.of(context.idMap);
      await _persistReceivedMappings();
      await _persistStateNow();
      onProgress?.call(1, '已接收文件夹');
      return PortableReceivedFolder(
        collectionId: context.rootId!,
        sourceToLocalIds: Map.unmodifiable(context.idMap),
        importedMediaCount: context.imported,
        skippedMediaCount: context.skipped,
        fingerprints: Map.unmodifiable(context.fingerprints),
        stableToLocalIds: Map.unmodifiable({
          for (final entry in nodeIds.entries)
            entry.value: ?context.idMap[entry.key],
        }),
        syncMetadata: metadata,
      );
    } on _TransferCancelled {
      throw const PortableExportCancelled();
    } finally {
      timer.cancel();
      removeListener(changed);
      try {
        if (ownsExtraction && await extraction.exists()) {
          await extraction.delete(recursive: true);
        }
      } finally {
        _storageTemporaryDirectoriesInUse.remove(extraction.path);
        notifyListeners();
      }
    }
  }

  PortableTransferTask _folderTask(PortableTransferKind kind, String title) =>
      PortableTransferTask(
        id: const Uuid().v4(),
        kind: kind,
        title: title,
        subtitle: '正在准备',
        createdAt: DateTime.now(),
      );

  Future<void> _persistReceivedMappings() {
    if (_receivedMappingsUnavailable) {
      throw const FormatException('文件夹恢复记录无法读取，请更新应用后重试');
    }
    final parent = _stateFile?.parent;
    if (parent == null) throw StateError('传输记录尚未初始化');
    final encoded = jsonEncode({
      'version': 2,
      'mappings': _receivedFolderMappings,
      'staging': {
        for (final entry in _receivedFolderStaging.entries)
          if (entry.value.isNotEmpty)
            entry.key: {
              for (final item in entry.value.entries)
                item.key: {
                  'existingId': item.value.existingId,
                  'stagedId': item.value.stagedId,
                },
            },
      },
    });
    final operation = _receivedMappingWrites.then((_) async {
      await parent.create(recursive: true);
      final target = File(p.join(parent.path, 'folder_receipts_v1.json'));
      final partial = File('${target.path}.next');
      await partial.writeAsString(encoded, flush: true);
      // Rename replaces the prior journal in one filesystem operation.
      await partial.rename(target.path);
    });
    _receivedMappingWrites = operation.catchError((_) {});
    return operation;
  }

  Future<void> _recoverInterruptedFolderStaging(LibraryService library) async {
    if (_receivedFolderStaging.values.every((items) => items.isEmpty)) return;
    for (final source in _receivedFolderStaging.entries) {
      for (final entry in source.value.entries.toList()) {
        final staged = entry.value;
        if (library.getVideo(staged.stagedId) != null) {
          // Only an explicitly journaled temporary revision may be rolled back.
          // The original logical card and every shared file remain protected.
          if (_receivedFolderMappings[source.key]?[entry.key] !=
              staged.existingId) {
            throw const FormatException('文件夹恢复记录与媒体不一致');
          }
          await _deleteTransferStaging(library, [staged.stagedId]);
          if (library.hasPersistenceFailure) {
            throw const FormatException('媒体库保存失败，请稍后继续');
          }
        }
        source.value.remove(entry.key);
        await _persistReceivedMappings();
      }
    }
  }

  Timer _watchFolderCancellation(
    PortableTransferTask task,
    bool Function()? isCancelled,
  ) => Timer.periodic(const Duration(milliseconds: 150), (_) {
    if (isCancelled?.call() == true) {
      task.cancelRequested = true;
      _workers[task.id]?.cancel();
    }
  });

  Future<PortableTransferTask> exportSelection({
    required LibraryService library,
    required List<String> rootIds,
    required String outputPath,
    required PortableExportOptions options,
  }) async {
    await initialize(library: library);
    final task = _newTask(
      PortableTransferKind.export,
      options.packageName,
      '正在整理 ${rootIds.length} 个项目…',
    );
    task.filePath = outputPath;
    _retrySpecs[task.id] = _PortableRetrySpec.export(
      rootIds: rootIds,
      outputPath: outputPath,
      options: options,
    );
    await _persistStateNow();
    unawaited(_runExport(task, library, rootIds, outputPath, options));
    return task;
  }

  Future<void> _runExport(
    PortableTransferTask task,
    LibraryService library,
    List<String> rootIds,
    String outputPath,
    PortableExportOptions options,
  ) async {
    if (options.format == PortableExportFormat.zip) {
      await _runZipExport(task, library, rootIds, outputPath, options);
      return;
    }
    final partial = File('$outputPath.part');
    final retainedLeases = <MaterializedMediaLease>[];
    final outputOwnership = ZipExportHandle();
    var outputBound = false;
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    try {
      ZipExportRuntime.bind(task.id, outputOwnership, partial.path);
      outputBound = true;
      task.status = PortableTransferStatus.preparing;
      notifyListeners();
      final plan = await _buildExportPlan(
        library,
        rootIds,
        options,
        task,
        retainedLeases: retainedLeases,
      );
      task.itemCount = plan.mediaCount;
      task.totalBytes = plan.totalBytes;
      task.subtitle = '准备写入 ${plan.files.length} 个文件';
      notifyListeners();

      if (await partial.exists()) await partial.delete();
      await partial.parent.create(recursive: true);
      final level = switch (options.compression) {
        PortableCompression.fast => ZipFileEncoder.store,
        PortableCompression.balanced => 3,
        PortableCompression.smallest => 9,
      };
      task.status = PortableTransferStatus.running;
      task.subtitle = options.verifyChecksums ? '正在计算完整性校验…' : '开始打包';
      notifyListeners();
      await _runWorker(
        task: task,
        entryPoint: _portableExportWorker,
        outputOwnership: outputOwnership,
        payload: <String, dynamic>{
          'partialPath': partial.path,
          'level': level,
          'verifyChecksums': options.verifyChecksums,
          'manifestPath': plan.manifestPath,
          'manifest': plan.manifest,
          'files': plan.files
              .map(
                (entry) => <String, dynamic>{
                  'sourcePath': entry.file.path,
                  'archivePath': entry.archivePath,
                  'size': entry.size,
                },
              )
              .toList(growable: false),
          'totalBytes': plan.totalBytes,
        },
      );
      if (task.cancelRequested) throw const _TransferCancelled();
      final target = File(outputPath);
      // The partial is in the same directory. Native rename replaces a regular
      // destination on success, keeping the previous export if publication fails.
      await partial.rename(outputPath);
      task.progress = 1;
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle =
          '${plan.mediaCount} 个媒体 · ${_formatBytes(await target.length())}';
      final missingSidecars = plan.manifest['missingSidecarCount'] as int? ?? 0;
      if (missingSidecars > 0) {
        terminalSubtitle += ' · 缺少 $missingSidecars 个字幕/弹幕附件，未能原样保留';
      }
      _retrySpecs.remove(task.id);
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消，没留下半成品';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导出失败';
    } finally {
      await _cleanupAfterPortableWorker(task, () async {
        try {
          for (final lease in retainedLeases) {
            try {
              await lease.release();
            } catch (error) {
              debugPrint(
                'Export cache lease cleanup deferred: ${error.runtimeType}',
              );
            }
          }
          if (outputBound &&
              terminalStatus != PortableTransferStatus.completed &&
              await partial.exists()) {
            try {
              await partial.delete();
            } catch (_) {}
          }
        } finally {
          if (outputBound) ZipExportRuntime.unbind(task.id, outputOwnership);
        }
      });
      await _finishTask(
        task,
        terminalStatus ?? PortableTransferStatus.failed,
        terminalSubtitle ?? '导出失败',
        terminalError,
      );
    }
  }

  Future<void> _runZipExport(
    PortableTransferTask task,
    LibraryService library,
    List<String> rootIds,
    String outputPath,
    PortableExportOptions options,
  ) async {
    final partial = File('$outputPath.part');
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    try {
      task.status = PortableTransferStatus.preparing;
      task.progress = 0;
      task.subtitle = '正在整理 ${rootIds.length} 个项目…';
      notifyListeners();
      final result = await ZipMediaExporter().run(
        library: library,
        rootIds: rootIds,
        partialPath: partial.path,
        options: options,
        taskId: task.id,
        isCancelled: () => task.cancelRequested,
        onProgress: (progress, subtitle, processedBytes, totalBytes) {
          if (task.cancelRequested) return;
          task.status = PortableTransferStatus.running;
          task.progress = progress.clamp(0, 0.99);
          task.subtitle = subtitle;
          task.processedBytes = processedBytes;
          task.totalBytes = totalBytes;
          notifyListeners();
        },
      );
      if (task.cancelRequested) throw const PortableExportCancelled();
      if (!await partial.exists()) {
        throw StateError('导出文件没有写完');
      }
      final target = File(outputPath);
      // Never remove a complete previous export before the new one is committed.
      await partial.rename(outputPath);
      task
        ..progress = 1
        ..itemCount = result.mediaCount + result.referenceCount
        ..totalBytes = await target.length();
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle = result.summary(task.totalBytes);
      _retrySpecs.remove(task.id);
    } on PortableExportCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消，没留下半成品';
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消，没留下半成品';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导出失败';
    } finally {
      if (terminalStatus != PortableTransferStatus.completed &&
          !ZipExportRuntime.isOutputBusy(partial.path) &&
          await partial.exists()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      await _finishTask(
        task,
        terminalStatus ?? PortableTransferStatus.failed,
        terminalSubtitle ?? '导出失败',
        terminalError,
      );
    }
  }

  Future<void> _releaseSourceLeases(List<MaterializedMediaLease> leases) async {
    for (final lease in leases.reversed) {
      try {
        await lease.release();
      } catch (error) {
        debugPrint('释放传输源文件保护失败：$error');
      }
    }
    leases.clear();
  }

  Future<_ExportPlan> _buildExportPlan(
    LibraryService library,
    List<String> rootIds,
    PortableExportOptions options,
    PortableTransferTask task, {
    List<MaterializedMediaLease>? retainedLeases,
    bool folderTransfer = false,
    Set<String>? folderMediaIds,
  }) async {
    final files = <_PackageFile>[];
    final checksums = <String, String>{};
    final collectionRecords = <Map<String, dynamic>>[];
    final podcastBundles = <String, Map<String, dynamic>>{};
    final podcastEpisodeIds = <String, Set<String>>{};
    final podcastChannelIds = <String>{};
    final videoRecords = <Map<String, dynamic>>[];
    final usedPaths = <String>{};
    final packagedSourcePaths = <String, String>{};
    var mediaCount = 0;
    var folderCount = 0;
    var totalBytes = 0;
    final resourceResults = <Map<String, dynamic>>[];
    final missingSidecars = <Map<String, dynamic>>[];
    final standalone = retainedLeases != null && !folderTransfer;
    final rootPrefix = options.wrapInFolder
        ? '${_safeName(options.packageName)}/'
        : '';

    Future<String?> addFile(String sourcePath, String relativePath) async {
      if (task.cancelRequested) throw const _TransferCancelled();
      final source = File(sourcePath);
      if (!await source.exists()) return null;
      final normalizedSource = p.normalize(source.path);
      final sourceKey = Platform.isWindows
          ? normalizedSource.toLowerCase()
          : normalizedSource;
      final existing = packagedSourcePaths[sourceKey];
      if (existing != null) return existing;
      var archivePath = '$rootPrefix${_safeRelativePath(relativePath)}';
      archivePath = _uniqueArchivePath(archivePath, usedPaths);
      final size = await source.length();
      files.add(_PackageFile(source, archivePath, size));
      totalBytes += size;
      packagedSourcePaths[sourceKey] = archivePath;
      return archivePath;
    }

    String? assetReference(String? archivePath) =>
        archivePath == null ? null : '@asset:$archivePath';

    Future<String?> packageAsset(
      String? sourcePath,
      String relativePath,
    ) async {
      if (sourcePath == null || sourcePath.trim().isEmpty) return null;
      return assetReference(await addFile(sourcePath, relativePath));
    }

    Future<String?> packageSubtitle(
      String? sourcePath,
      String relativePath,
    ) async {
      final reference = await packageAsset(sourcePath, relativePath);
      if (reference != null && sourcePath != null) {
        final archivedPath = reference.substring('@asset:'.length);
        final relative = rootPrefix.isEmpty
            ? archivedPath
            : archivedPath.substring(rootPrefix.length);
        await addFile(
          SubtitleWordTimingStore.pathFor(sourcePath),
          '$relative${SubtitleWordTimingStore.suffix}',
        );
      }
      return reference;
    }

    Future<void> retainLocalFile(
      VideoItem item,
      String path, {
      CacheVariant? variant,
    }) async {
      if (retainedLeases == null) return;
      final cache = MediaCacheService.instance;
      final source = CacheSource.fromItem(item);
      if (cache != null &&
          source != null &&
          !communityMediaIsLocal(item.path)) {
        await cache.initialize();
        variant ??= cache.variants
            .where(
              (entry) =>
                  entry.source.key == source.key &&
                  entry.completeMedia &&
                  AppStorageService.samePath(entry.path, path),
            )
            .firstOrNull;
      }
      if (variant != null && cache != null) {
        final lease = await cache.acquireVariant(variant, item);
        if (lease == null) throw StateError('缓存文件已不可用，请重试传输');
        retainedLeases.add(lease);
        return;
      }
      // Imported local files can remember a cloud/Bilibili source without a
      // cache entry. They still need global path protection during transfer.
      retainedLeases.add(
        MaterializedMediaLease(
          videoId: item.id,
          retainedOffline: true,
          audioPath: path,
          videoPath: item.type == MediaType.audio ? null : path,
          completePath: path,
          qualityId: null,
          width: null,
          height: null,
          onRelease: () async {},
        ),
      );
    }

    Future<Map<String, String>?> packageSubtitleMap(
      Map<String, String>? source,
      String cardAssetPath,
    ) async {
      if (source == null) return null;
      final result = <String, String>{};
      for (final entry in source.entries) {
        final ref = await packageSubtitle(
          entry.value,
          p.posix.join(cardAssetPath, 'subtitles', p.basename(entry.value)),
        );
        if (ref != null) result[entry.key] = ref;
      }
      return result;
    }

    Future<void> addVideo(
      VideoItem item,
      String? parentExportId,
      String parentPath,
    ) async {
      if (task.cancelRequested) throw const _TransferCancelled();
      if (folderTransfer &&
          folderMediaIds != null &&
          !folderMediaIds.contains(item.id)) {
        return;
      }
      requireCommunityProcessingSource(item.path, source: item.sourceRef);
      final exportId = item.id;
      final localMedia = communityMediaIsLocal(item.path);
      final referenceOnlyPodcast =
          !localMedia && standalone && item.sourceRef?.podcast != null;
      final standaloneCloud =
          !localMedia && standalone && item.sourceRef?.cloudDrive != null;
      final cacheSource = CacheSource.fromItem(item);
      final standaloneBilibili =
          !localMedia && standalone && cacheSource?.isBilibili == true;
      final transferredBilibili =
          !localMedia && folderTransfer && cacheSource?.isBilibili == true;
      final transferredCloud =
          !localMedia && folderTransfer && item.sourceRef?.cloudDrive != null;
      final ownedBilibiliPath =
          (standaloneBilibili || transferredBilibili) &&
              item.bilibiliDownloadPath?.trim().isNotEmpty == true
          ? item.bilibiliDownloadPath!
          : null;
      var origin = await classifySyncMediaOrigin(
        path: referenceOnlyPodcast
            ? 'podcast:${item.sourceRef!.podcast!.episodeId}'
            : item.path,
        playbackPath: transferredBilibili
            ? ownedBilibiliPath
            : referenceOnlyPodcast ||
                  standaloneCloud ||
                  transferredCloud ||
                  standaloneBilibili ||
                  retainedLeases != null &&
                      (item.bilibiliDownloadPath != null ||
                          item.path.startsWith('bilibili://'))
            ? null
            : item.playbackPath ?? item.bilibiliDownloadPath,
        sourceKind: item.sourceRef?.kind,
      );
      CacheQuality? transferredCloudQuality;
      if (transferredCloud) {
        final cache = MediaCacheService.instance;
        CacheVariant? variant;
        if (cache != null && cacheSource != null) {
          await cache.initialize();
          await cache.discoverMaterial(cacheSource);
          await cache.refreshAvailability(mediaKey: cacheSource.key);
          variant = origin.placement == SyncMediaPlacement.localFile
              ? cache.variants
                    .where(
                      (entry) =>
                          entry.source.key == cacheSource.key &&
                          entry.completeMedia &&
                          AppStorageService.samePath(
                            entry.path,
                            origin.localPath!,
                          ),
                    )
                    .firstOrNull
              : cache.completeExportVariant(item);
        }
        if (origin.placement != SyncMediaPlacement.localFile &&
            variant != null) {
          origin = SyncMediaOrigin(
            placement: SyncMediaPlacement.localFile,
            localPath: variant.path,
          );
        }
        final local = origin.localPath;
        if (origin.placement != SyncMediaPlacement.localFile ||
            local == null ||
            !await File(local).exists() ||
            await File(local).length() <= 0) {
          throw FormatException('网盘媒体「${item.title}」尚无完整缓存，请先选择画质并缓存完成后再迁移');
        }
        await retainLocalFile(item, local, variant: variant);
        transferredCloudQuality =
            variant?.quality ??
            CacheQuality(
              id: 'original',
              label: '原文件',
              revision: item.sourceRef!.cloudDrive!.revision ?? '',
            );
      }
      final isOnline = origin.placement == SyncMediaPlacement.onlineReference;
      if (transferredBilibili && ownedBilibiliPath != null && isOnline) {
        throw FormatException('哔哩哔哩视频「${item.title}」的下载成品已不可用，请恢复本地文件后再迁移');
      }
      if ((standaloneBilibili || transferredBilibili) &&
          !isOnline &&
          (origin.placement != SyncMediaPlacement.localFile ||
              await File(origin.localPath!).length() <= 0)) {
        if (transferredBilibili) {
          throw FormatException('哔哩哔哩视频「${item.title}」的下载成品已不可用，请恢复本地文件后再迁移');
        }
        throw StateError('「${item.title}」的下载成品已不可用，未导出为仅含链接的卡片；请恢复本地文件后重试');
      }
      if (standaloneCloud &&
          (!isOnline &&
              (origin.placement != SyncMediaPlacement.localFile ||
                  await File(origin.localPath!).length() <= 0))) {
        throw StateError('「${item.title}」的完整媒体已不可用，请重新缓存后导出');
      }
      Map<String, dynamic>? cachedBilibiliMedia;
      Map<String, dynamic>? cachedCloudMedia;
      if (isOnline && standalone) {
        final cache = MediaCacheService.instance;
        final source = cacheSource;
        final wantsBilibiliMedia =
            source?.isBilibili == true &&
            (ownedBilibiliPath != null || options.includeBilibiliCache);
        if (cache != null &&
            source != null &&
            !source.isPodcast &&
            (!source.isBilibili || wantsBilibiliMedia)) {
          await cache.initialize();
          await cache.discoverMaterial(source);
          await cache.refreshAvailability(mediaKey: source.key);
        }
        final ownedVariant = source?.isBilibili == true
            ? cache?.completeBilibiliVariant(item, ownedDownload: true)
            : null;
        if (ownedBilibiliPath != null && ownedVariant == null) {
          throw StateError(
            '「${item.title}」的下载成品已不可用或尚未登记，未导出为仅含链接的卡片；请恢复本地文件或缓存服务后重试',
          );
        }
        final variant = source?.isBilibili == true
            ? ownedVariant ??
                  (options.includeBilibiliCache
                      ? cache?.completeExportVariant(item)
                      : null)
            : cache?.completeExportVariant(item);
        if (standaloneCloud && variant == null) {
          throw StateError('「${item.title}」尚无完整缓存，请先选择画质并完成缓存后导出');
        }
        if (cache != null && variant != null) {
          await retainLocalFile(item, variant.path, variant: variant);
          final reference = await packageAsset(
            variant.path,
            p.posix.join(
              'assets',
              'cards',
              exportId,
              'media${p.extension(variant.path)}',
            ),
          );
          if (reference == null) throw StateError('缓存文件已丢失');
          final cachedMedia = <String, dynamic>{
            'path': reference,
            'quality': variant.quality.toJson(),
          };
          if (source?.isBilibili == true) {
            cachedBilibiliMedia = {
              ...cachedMedia,
              'downloadOrigin':
                  ownedBilibiliPath != null &&
                  AppStorageService.samePath(variant.path, ownedBilibiliPath),
            };
          } else if (standaloneCloud) {
            cachedCloudMedia = cachedMedia;
          }
        }
      }
      final videoJson = Map<String, dynamic>.from(item.toJson());
      final cardAssetPath = p.posix.join('assets', 'cards', exportId);
      final namedPath = origin.localPath ?? item.path;
      final mediaName = _safeName(
        p.basename(namedPath).isEmpty || isOnline
            ? '${item.title}${item.type == MediaType.audio ? '.m4a' : '.mp4'}'
            : p.basename(namedPath),
      );

      if (origin.placement == SyncMediaPlacement.unavailable ||
          origin.placement == SyncMediaPlacement.localContentUri) {
        // Absence stays on the manifest. Dropping the row would look like a
        // complete sync of a smaller folder.
        resourceResults.add({
          'exportId': exportId,
          'role': 'primary',
          'result': 'unavailable',
          'reason': origin.reason ?? origin.placement.name,
          'title': item.title,
        });
        return;
      }
      if (isOnline) {
        resourceResults.add({
          'exportId': exportId,
          'role': 'primary',
          'result': 'onlineReference',
        });
        videoJson['path'] = referenceOnlyPodcast
            ? 'podcast:${item.sourceRef!.podcast!.episodeId}'
            : item.path;
      } else {
        await retainLocalFile(item, origin.localPath!);
        final primary = await packageAsset(
          origin.localPath ?? item.path,
          p.posix.join(parentPath, mediaName),
        );
        if (primary == null) {
          if (standaloneCloud) {
            throw StateError('「${item.title}」的完整媒体已丢失，请重新缓存后导出');
          }
          resourceResults.add({
            'exportId': exportId,
            'role': 'primary',
            'result': 'unavailable',
            'reason': 'missing-file',
            'title': item.title,
          });
          return;
        }
        resourceResults.add({
          'exportId': exportId,
          'role': 'primary',
          'result': 'localFile',
        });
        videoJson['path'] = primary;
      }
      CacheQuality? transferredBilibiliQuality;
      if (transferredBilibili && !isOnline) {
        videoJson['isBilibiliExported'] = true;
        transferredBilibiliQuality = MediaCacheService.instance
            ?.variantsFor(cacheSource!.key)
            .where(
              (entry) =>
                  entry.completeMedia &&
                  AppStorageService.samePath(entry.path, origin.localPath!),
            )
            .firstOrNull
            ?.quality;
        transferredBilibiliQuality ??= const CacheQuality(
          id: 'legacy',
          label: '已有离线版本',
          revision: 'cid',
        );
      }
      mediaCount++;
      videoJson['id'] = exportId;
      videoJson['parentId'] = parentExportId;
      videoJson['isRecycled'] = false;
      videoJson['recycleTime'] = null;
      videoJson['playbackPath'] = null;
      videoJson['bilibiliDownloadPath'] = null;
      videoJson['sourceFingerprint'] = null;
      videoJson['recycledSelectedSubtitlePaths'] = null;
      videoJson['recycledExtraSubtitles'] = null;
      videoJson['recycledLocalSubtitles'] = null;

      videoJson['thumbnailPath'] = referenceOnlyPodcast
          ? null
          : await packageAsset(
              item.thumbnailPath,
              p.posix.join(
                cardAssetPath,
                'cover${p.extension(item.thumbnailPath ?? '').isEmpty ? '.jpg' : p.extension(item.thumbnailPath!)}',
              ),
            );

      if (options.includeSidecars && !referenceOnlyPodcast) {
        videoJson['subtitlePath'] = await packageSubtitle(
          item.subtitlePath,
          p.posix.join(
            cardAssetPath,
            'subtitles',
            p.basename(item.subtitlePath ?? 'primary.srt'),
          ),
        );
        videoJson['secondarySubtitlePath'] = await packageSubtitle(
          item.secondarySubtitlePath,
          p.posix.join(
            cardAssetPath,
            'subtitles',
            p.basename(item.secondarySubtitlePath ?? 'secondary.srt'),
          ),
        );
        videoJson['danmakuPath'] = await packageAsset(
          item.danmakuPath,
          p.posix.join(
            cardAssetPath,
            'danmaku',
            p.basename(item.danmakuPath ?? 'danmaku.ass'),
          ),
        );
        videoJson['extraSubtitles'] = await packageSubtitleMap(
          item.additionalSubtitles,
          cardAssetPath,
        );
        videoJson['localSubtitles'] = await packageSubtitleMap(
          item.localSubtitles,
          cardAssetPath,
        );

        final managed = <Map<String, dynamic>>[];
        for (final asset in item.managedSubtitleAssets) {
          final ref = await packageSubtitle(
            asset.path,
            p.posix.join(cardAssetPath, 'subtitles', p.basename(asset.path)),
          );
          if (ref != null) {
            final timing = await packageAsset(
              asset.wordTimingPath,
              p.posix.join(
                cardAssetPath,
                'subtitles',
                p.basename(asset.wordTimingPath ?? 'timing.json'),
              ),
            );
            managed.add(<String, dynamic>{
              ...asset.toJson(),
              'path': ref,
              'wordTimingPath': timing,
            });
          }
        }
        videoJson['managedSubtitleAssets'] = managed;

        final shot = item.bilibiliVideoShot;
        if (shot != null) {
          final spriteRefs = <String>[];
          for (var index = 0; index < shot.spritePaths.length; index++) {
            final source = shot.spritePaths[index];
            final ref = await packageAsset(
              source,
              p.posix.join(
                cardAssetPath,
                'videoshot',
                'sprite_${index.toString().padLeft(3, '0')}${p.extension(source)}',
              ),
            );
            if (ref != null) spriteRefs.add(ref);
          }
          videoJson['bilibiliVideoShot'] = spriteRefs.isEmpty
              ? null
              : <String, dynamic>{...shot.toJson(), 'spritePaths': spriteRefs};
        }
      } else {
        videoJson['subtitlePath'] = null;
        videoJson['secondarySubtitlePath'] = null;
        videoJson['danmakuPath'] = null;
        videoJson['extraSubtitles'] = null;
        videoJson['localSubtitles'] = null;
        videoJson['managedSubtitleAssets'] = <dynamic>[];
        videoJson['bilibiliVideoShot'] = null;
      }

      if (standalone && options.includeSidecars && !referenceOnlyPodcast) {
        final checked = <String>{};
        final expected = <(String?, String)>[
          (item.subtitlePath, 'primarySubtitle'),
          (item.secondarySubtitlePath, 'secondarySubtitle'),
          (item.danmakuPath, 'danmaku'),
          for (final path in item.additionalSubtitles?.values ?? <String>[])
            (path, 'subtitle'),
          for (final path in item.localSubtitles?.values ?? <String>[])
            (path, 'subtitle'),
          for (final asset in item.managedSubtitleAssets) ...[
            (asset.path, 'managedSubtitle'),
            (asset.wordTimingPath, 'wordTiming'),
          ],
        ];
        for (final (path, role) in expected) {
          if (path == null || path.trim().isEmpty) continue;
          final normalized = p.normalize(path);
          final key = Platform.isWindows
              ? normalized.toLowerCase()
              : normalized;
          if (checked.add(key) && !packagedSourcePaths.containsKey(key)) {
            missingSidecars.add({
              'kind': 'missingSidecar',
              'exportId': exportId,
              'title': item.title,
              'role': role,
              'fileName': p.basename(path),
            });
          }
        }
      }

      videoRecords.add(<String, dynamic>{
        'exportId': exportId,
        'parentExportId': parentExportId,
        'isOnline': isOnline,
        'cachedBilibiliMedia': ?cachedBilibiliMedia,
        'cachedCloudMedia': ?cachedCloudMedia,
        if ((standaloneCloud || transferredCloud) && !isOnline)
          'cloudDownloadQuality':
              (transferredCloudQuality ??
                      CacheQuality(
                        id: 'original',
                        label: '原文件',
                        revision: item.sourceRef!.cloudDrive!.revision ?? '',
                      ))
                  .toJson(),
        if (transferredBilibiliQuality != null)
          'bilibiliDownloadQuality': transferredBilibiliQuality.toJson()
        else if (!localMedia && !isOnline && item.bilibiliDownloadPath != null)
          'bilibiliDownloadQuality': MediaCacheService.instance
              ?.completeBilibiliVariant(item, ownedDownload: true)
              ?.quality
              .toJson(),
        'video': videoJson,
      });
    }

    final inclusion = PortableMediaSelection(
      rootIds,
    ).resolveAgainstLibrary(library);
    final visited = <String>{};

    Future<void> walk(
      String id,
      String? parentExportId,
      String parentPath,
    ) async {
      if (task.cancelRequested) throw const _TransferCancelled();
      if (!visited.add(id)) return;
      final collection = library.getCollection(id);
      if (collection != null && !collection.isRecycled) {
        if (!inclusion.collectionIds.contains(id)) {
          // Folders above the selection's lowest common ancestor are omitted
          // so a nested export does not recreate unused outer shells. Walk
          // through them without emitting a collection record.
          for (final childId in collection.childrenIds) {
            await walk(childId, parentExportId, parentPath);
          }
          return;
        }
        folderCount++;
        final ownPath = p.posix.join(parentPath, _safeName(collection.name));
        final thumbnailRef = await packageAsset(
          collection.thumbnailPath,
          p.posix.join(
            'assets',
            'collections',
            collection.id,
            'cover${p.extension(collection.thumbnailPath ?? '').isEmpty ? '.jpg' : p.extension(collection.thumbnailPath!)}',
          ),
        );
        collectionRecords.add(<String, dynamic>{
          'exportId': collection.id,
          'parentExportId': parentExportId,
          'name': collection.name,
          'createTime': collection.createTime,
          'thumbnailPath': thumbnailRef,
          'coverLabel': collection.coverLabel,
          'sourceRef': collection.sourceRef?.toJson(),
          if (collection.podcastRef != null)
            'podcastRef': collection.podcastRef!.toJson(),
        });
        for (final childId in collection.childrenIds) {
          await walk(childId, collection.id, ownPath);
        }
        return;
      }
      final video = library.getVideo(id);
      if (video != null &&
          !video.isRecycled &&
          inclusion.videoIds.contains(id)) {
        await addVideo(video, parentExportId, parentPath);
      }
    }

    for (final item in library.getContents(null)) {
      final id = item is VideoCollection ? item.id : (item as VideoItem).id;
      await walk(id, null, '');
    }
    // Orphaned selection roots that are not reachable from the library root
    // still need a chance to be packed at the package root.
    for (final id in [...inclusion.collectionIds, ...inclusion.videoIds]) {
      if (!visited.contains(id)) {
        await walk(id, null, '');
      }
    }
    if (collectionRecords.isEmpty &&
        videoRecords.isEmpty &&
        resourceResults.isEmpty) {
      throw StateError('所选项目中没有可导出的内容');
    }
    for (final bundle in podcastBundles.values) {
      final runtime = PodcastRuntime.instance;
      if (standalone) {
        // A portable podcast card carries feed/episode links and presentation
        // state only. Exporting one episode never copies its entire channel.
        final channelId = (bundle['channel'] as Map)['id'] as String;
        final selected = podcastChannelIds.contains(channelId)
            ? null
            : podcastEpisodeIds[channelId] ?? <String>{};
        if (selected != null) {
          bundle['episodes'] = (bundle['episodes'] as List? ?? [])
              .where((raw) => raw is Map && selected.contains(raw['id']))
              .toList();
          for (final key in ['states', 'presentations']) {
            if (bundle[key] is Map) {
              bundle[key] = Map<String, dynamic>.from(bundle[key] as Map)
                ..removeWhere((id, _) => !selected.contains(id));
            }
          }
          bundle.remove('manualOrder');
        }
        bundle.remove('downloads');
        continue;
      }
      if (!runtime.store.preferences.flag('includeDownloadsInExport')) continue;
      final channel = PodcastChannel.fromJson(
        Map<String, dynamic>.from(bundle['channel']),
      );
      final offline = <Map<String, dynamic>>[];
      for (final task in runtime.controller.downloads.where(
        (t) => t.status == PodcastDownloadStatus.completed,
      )) {
        final episode = runtime.store.episode(task.episodeId);
        if (episode == null || episode.channelId != channel.id) continue;
        final media = episode.media
            .where((m) => m.url == task.mediaUrl)
            .firstOrNull;
        if (media == null ||
            !runtime.controller.mediaStore.isDownloaded(
              episode.id,
              media.url,
            )) {
          continue;
        }
        final file = await runtime.controller.mediaStore.assemble(
          episode,
          media,
        );
        final reference = await packageAsset(
          file.path,
          p.posix.join(
            'podcasts',
            channel.id,
            episode.id + p.extension(file.path),
          ),
        );
        if (reference != null) {
          offline.add({
            'episodeId': episode.id,
            'mediaUrl': media.url,
            'path': reference,
          });
        }
      }
      bundle['downloads'] = offline;
    }
    final manifestPath = '${rootPrefix}manifest.json';
    final manifest = <String, dynamic>{
      'format': 'fluent-player-portable-package',
      'formatVersion':
          videoRecords.any(
                (record) =>
                    record['cachedCloudMedia'] != null ||
                    record['cloudDownloadQuality'] != null ||
                    ((record['video'] as Map)['managedSubtitleAssets']
                                as List? ??
                            [])
                        .any(
                          (asset) =>
                              asset is Map && asset['wordTimingPath'] != null,
                        ),
              ) ||
              files.any(
                (file) =>
                    file.archivePath.endsWith(SubtitleWordTimingStore.suffix),
              )
          ? 6
          : videoRecords.any(
              (record) =>
                  record['cachedBilibiliMedia'] != null ||
                  record['bilibiliDownloadQuality'] != null,
            )
          ? 5
          : podcastBundles.isEmpty
          ? 2
          : 4,
      'packageName': options.packageName,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'mediaCount': mediaCount,
      'folderCount': folderCount,
      'fileCount': files.length,
      'totalBytes': totalBytes,
      'wrappedInFolder': options.wrapInFolder,
      'checksums': checksums,
      'resourceResults': resourceResults,
      if (missingSidecars.isNotEmpty) ...{
        'missingSidecarCount': missingSidecars.length,
        'warnings': missingSidecars,
      },
      'unavailableCount': resourceResults
          .where((item) => item['result'] == 'unavailable')
          .length,
      'snapshot': <String, dynamic>{
        'collections': collectionRecords,
        'videos': videoRecords,
        if (podcastBundles.isNotEmpty)
          'podcasts': podcastBundles.values.toList(),
      },
    };
    return _ExportPlan(
      files: files,
      manifest: manifest,
      manifestPath: manifestPath,
      mediaCount: mediaCount,
      totalBytes: totalBytes,
    );
  }

  Future<PortablePackagePreview> inspectPackage(String packagePath) async {
    if (!hasPackageExtension(packagePath)) {
      throw const FormatException('只能导入 .fluentpack 文件');
    }
    final raw = await Isolate.run(
      () => _inspectPortablePackageWorker(<String, dynamic>{
        'packagePath': packagePath,
        'supportedVersion': formatVersion,
      }),
    );
    return PortablePackagePreview(
      packageName: raw['packageName'] as String,
      createdAt: DateTime.parse(raw['createdAt'] as String),
      mediaCount: raw['mediaCount'] as int,
      folderCount: raw['folderCount'] as int,
      fileCount: raw['fileCount'] as int,
      totalBytes: raw['totalBytes'] as int,
      hasChecksums: raw['hasChecksums'] as bool,
      formatVersion: raw['formatVersion'] as int,
    );
  }

  Future<PortableTransferTask> importPackage({
    required LibraryService library,
    required String packagePath,
    required PortablePackagePreview preview,
    bool deletePackageWhenDone = false,
    String? libraryFolderId,
    ImportPlacementRequest? importPlacement,
  }) async {
    final placement =
        importPlacement ??
        SettingsService().captureImportPlacement(
          ImportCardFeature.fluentPack,
          openedFromFolderId: libraryFolderId,
        );
    await initialize(library: library);
    final task = _newTask(
      PortableTransferKind.import,
      preview.packageName,
      '正在检查导出包…',
    );
    task.filePath = packagePath;
    task.itemCount = preview.mediaCount;
    task.totalBytes = preview.totalBytes;
    _retrySpecs[task.id] = _PortableRetrySpec.import(
      importPlacement: placement,
      packagePath: packagePath,
      preview: preview,
      deletePackageWhenDone: deletePackageWhenDone,
      libraryFolderId: libraryFolderId,
    );
    await _persistStateNow();
    unawaited(
      _runImport(
        task,
        library,
        packagePath,
        deletePackageWhenDone: deletePackageWhenDone,
        libraryFolderId: libraryFolderId,
      ),
    );
    return task;
  }

  Future<PortableTransferTask> importArchive({
    required LibraryService library,
    required String archivePath,
    required String displayName,
    bool deleteArchiveWhenDone = false,
    String? libraryFolderId,
    ImportPlacementRequest? importPlacement,
  }) async {
    final placement =
        importPlacement ??
        SettingsService().captureImportPlacement(
          ImportCardFeature.archive,
          openedFromFolderId: libraryFolderId,
        );
    if (!LibraryService.isSupportedArchivePath(displayName) &&
        !LibraryService.isSupportedArchivePath(archivePath)) {
      throw UnsupportedError('当前仅支持 zip、tar、tar.gz、tar.bz2、tar.xz 压缩包');
    }
    await initialize(library: library);
    final sortOptions = StructuredImportSortOptions.fromSettings(
      SettingsService(),
    );
    final titleSource = displayName.trim().isNotEmpty
        ? displayName
        : archivePath;
    final task = _newTask(
      PortableTransferKind.import,
      LibraryService.archiveRootCollectionName(titleSource),
      '正在准备解压…',
    );
    task.filePath = archivePath;
    final archiveFile = File(archivePath);
    if (await archiveFile.exists()) {
      task.totalBytes = await archiveFile.length();
    }
    _retrySpecs[task.id] = _PortableRetrySpec.archive(
      importPlacement: placement,
      archivePath: archivePath,
      displayName: displayName,
      sortOptions: sortOptions,
      deleteArchiveWhenDone: deleteArchiveWhenDone,
      libraryFolderId: libraryFolderId,
    );
    await _persistStateNow();
    unawaited(
      _runArchiveImport(
        task,
        library,
        archivePath,
        sortOptions: sortOptions,
        deleteArchiveWhenDone: deleteArchiveWhenDone,
        libraryFolderId: libraryFolderId,
      ),
    );
    return task;
  }

  Future<void> _runArchiveImport(
    PortableTransferTask task,
    LibraryService library,
    String archivePath, {
    required StructuredImportSortOptions sortOptions,
    bool deleteArchiveWhenDone = false,
    String? libraryFolderId,
  }) async {
    VoidCallback? progressListener;
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    var delegated = false;
    try {
      if (task.cancelRequested) throw const _TransferCancelled();
      final metadata = await _inspectArchiveReferencesInBackground(archivePath);
      if (metadata?['portablePackage'] == true) {
        // A renamed FluentPack is still a portable package. Preserve its card
        // metadata and cache registry instead of importing only its media files.
        delegated = true;
        await _runImport(
          task,
          library,
          archivePath,
          deletePackageWhenDone: deleteArchiveWhenDone,
          libraryFolderId: libraryFolderId,
        );
        return;
      }
      task
        ..status = PortableTransferStatus.preparing
        ..progress = 0.4;
      notifyListeners();
      progressListener = () {
        final status = library.importStatus.value.trim();
        final extracting = status.contains('准备解压') || status.contains('后台解压');
        task.status = extracting
            ? PortableTransferStatus.preparing
            : PortableTransferStatus.running;
        task.progress = extracting
            ? 0.4
            : 0.4 + library.importProgress.value * 0.6;
        task.subtitle = status.isEmpty ? '正在解压并导入…' : status;
        notifyListeners();
      };
      library.importProgress.addListener(progressListener);
      library.importStatus.addListener(progressListener);
      var imported = 0;
      String? archiveRootId;
      if (metadata == null || metadata['hasMedia'] == true) {
        final result = await library.importArchiveSelection(
          archivePath,
          libraryFolderId,
          sortOptions: sortOptions,
          importPlacement: _retrySpecs[task.id]?.importPlacement,
        );
        imported = result.affectedMediaCount;
        archiveRootId = result.rootCollectionId;
      }
      if (metadata?['snapshot'] case final Map snapshot) {
        final temporary = await getTemporaryDirectory();
        final referenceRoot = await Directory(
          p.join(temporary.path, 'fluent_transfer', '${task.id}_references'),
        ).create(recursive: true);
        try {
          var archiveRoot = archiveRootId == null
              ? await library.createCollection(
                  task.title,
                  await library.resolveImportCardParentId(
                    feature: ImportCardFeature.archive,
                    openedFromFolderId: libraryFolderId,
                    request: _retrySpecs[task.id]?.importPlacement,
                  ),
                )
              : library.getCollection(archiveRootId)!;
          final directory = metadata?['referenceDirectory'] as String? ?? '';
          for (final segment
              in directory.split('/').where((s) => s.isNotEmpty && s != '.')) {
            final matching = library
                .getContents(archiveRoot.id)
                .whereType<VideoCollection>()
                .where((folder) => !folder.isRecycled && folder.name == segment)
                .firstOrNull;
            archiveRoot =
                matching ??
                await library.createCollection(segment, archiveRoot.id);
          }
          imported += await _importSnapshot(
            library: library,
            extraction: referenceRoot,
            packageName: task.title,
            snapshot: Map<String, dynamic>.from(snapshot),
            task: task,
            openedFromFolderId: libraryFolderId,
            importPlacement: _retrySpecs[task.id]?.importPlacement,
            archiveRoot: archiveRoot,
            podcastReferencesOnly: true,
          );
          imported += (snapshot['collections'] as List? ?? [])
              .where((record) => record is Map && record['podcastRef'] != null)
              .length;
        } finally {
          await referenceRoot.delete(recursive: true);
        }
      }
      task.progress = 1;
      task.itemCount = imported;
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle = '已导入 $imported 个媒体';
      _retrySpecs.remove(task.id);
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导入失败';
    } finally {
      if (!delegated) {
        if (progressListener != null) {
          library.importProgress.removeListener(progressListener);
          library.importStatus.removeListener(progressListener);
        }
        if (deleteArchiveWhenDone &&
            terminalStatus == PortableTransferStatus.completed) {
          final materializedArchive = File(archivePath);
          if (await materializedArchive.exists()) {
            try {
              await materializedArchive.delete();
            } catch (_) {}
          }
        }
        await _finishTask(
          task,
          terminalStatus ?? PortableTransferStatus.failed,
          terminalSubtitle ?? '导入失败',
          terminalError,
        );
      }
    }
  }

  Future<void> _runImport(
    PortableTransferTask task,
    LibraryService library,
    String packagePath, {
    bool deletePackageWhenDone = false,
    String? libraryFolderId,
  }) async {
    Directory? extractDir;
    VoidCallback? progressListener;
    PortableTransferStatus? terminalStatus;
    String? terminalSubtitle;
    String? terminalError;
    try {
      task.status = PortableTransferStatus.preparing;
      notifyListeners();
      final temp = await getTemporaryDirectory();
      extractDir = await Directory(
        p.join(temp.path, 'fluent_transfer', task.id),
      ).create(recursive: true);
      final manifest = await _runWorker(
        task: task,
        entryPoint: _portableImportWorker,
        payload: <String, dynamic>{
          'packagePath': packagePath,
          'extractionPath': extractDir.path,
          'supportedVersion': formatVersion,
        },
      );
      if (task.cancelRequested) throw const _TransferCancelled();
      final snapshot = manifest['snapshot'];
      if (snapshot is Map) {
        final imported = await _importSnapshot(
          library: library,
          extraction: extractDir,
          packageName: task.title,
          snapshot: Map<String, dynamic>.from(snapshot),
          task: task,
          openedFromFolderId: libraryFolderId,
          importPlacement: _retrySpecs[task.id]?.importPlacement,
        );
        task.progress = 1;
        task.itemCount = imported;
        terminalStatus = PortableTransferStatus.completed;
        terminalSubtitle = '已导入 $imported 个媒体';
        _retrySpecs.remove(task.id);
        return;
      }
      final contentRoot = await _locateContentRoot(extractDir);
      progressListener = () {
        task.status = PortableTransferStatus.running;
        task.progress = 0.4 + library.importProgress.value * 0.6;
        task.subtitle = library.importStatus.value.isEmpty
            ? '正在写入媒体库…'
            : library.importStatus.value;
        notifyListeners();
      };
      library.importProgress.addListener(progressListener);
      library.importStatus.addListener(progressListener);
      final result = await library.importPortablePackageDirectory(
        contentRoot.path,
        rootCollectionName: task.title,
        mediaEntriesHint: task.itemCount,
        openedFromFolderId: libraryFolderId,
        importPlacement: _retrySpecs[task.id]?.importPlacement,
        sortOptions: const StructuredImportSortOptions(
          field: StructuredImportSortField.fileName,
          direction: StructuredImportSortDirection.ascending,
        ),
      );
      final rawMetadata = manifest['mediaMetadata'];
      if (rawMetadata is List && rawMetadata.isNotEmpty) {
        await library.applyPortableMediaMetadata(
          result.importedVideoIds,
          rawMetadata.whereType<Map>().map(
            (record) => Map<String, dynamic>.from(record),
          ),
        );
      }
      task.progress = 1;
      task.itemCount = result.affectedMediaCount;
      terminalStatus = PortableTransferStatus.completed;
      terminalSubtitle = '已导入 ${result.affectedMediaCount} 个媒体';
      _retrySpecs.remove(task.id);
    } on _TransferCancelled {
      terminalStatus = PortableTransferStatus.cancelled;
      terminalSubtitle = '已取消';
    } catch (error) {
      terminalStatus = PortableTransferStatus.failed;
      terminalError = error.toString();
      terminalSubtitle = '导入失败';
    } finally {
      if (progressListener != null) {
        library.importProgress.removeListener(progressListener);
        library.importStatus.removeListener(progressListener);
      }
      if (extractDir != null && await extractDir.exists()) {
        try {
          await extractDir.delete(recursive: true);
        } catch (_) {}
      }
      if (deletePackageWhenDone &&
          terminalStatus == PortableTransferStatus.completed) {
        final materializedPackage = File(packagePath);
        if (await materializedPackage.exists()) {
          try {
            await materializedPackage.delete();
          } catch (_) {}
        }
      }
      await _finishTask(
        task,
        terminalStatus ?? PortableTransferStatus.failed,
        terminalSubtitle ?? '导入失败',
        terminalError,
      );
    }
  }

  Future<int> _importSnapshot({
    required LibraryService library,
    required Directory extraction,
    required String packageName,
    required Map<String, dynamic> snapshot,
    required PortableTransferTask task,
    String? openedFromFolderId,
    ImportPlacementRequest? importPlacement,
    _FolderImportContext? network,
    VideoCollection? archiveRoot,
    bool podcastReferencesOnly = false,
  }) async {
    final rawCollections =
        (snapshot['collections'] as List? ?? const <dynamic>[])
            .whereType<Map>()
            .map((value) => Map<String, dynamic>.from(value))
            .toList();
    final rawVideos = (snapshot['videos'] as List? ?? const <dynamic>[])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    // Retain archived source metadata, but never activate live subscriptions
    // or media transports while restoring a local media package.
    final podcastBundles = <Map<String, dynamic>>[];
    rawVideos.removeWhere((record) {
      if (record['isOnline'] != true) return false;
      final video = record['video'];
      if (video is! Map) return true;
      final cachedCloud = record['cachedCloudMedia'];
      final cachedBilibili = record['cachedBilibiliMedia'];
      final path = video['path'];
      final asset = path is String && path.startsWith('@asset:')
          ? path
          : cachedCloud is Map
          ? cachedCloud['path']
          : cachedBilibili is Map
          ? cachedBilibili['path']
          : null;
      if (asset is! String || !asset.startsWith('@asset:')) return true;
      record['isOnline'] = false;
      record['video'] = {...video, 'path': asset};
      record.remove('cachedCloudMedia');
      record.remove('cachedBilibiliMedia');
      record.remove('cloudDownloadQuality');
      record.remove('bilibiliDownloadQuality');
      return false;
    });
    if (podcastBundles.isNotEmpty) {
      await PodcastRuntime.instance.initialize(library: library);
      final store = PodcastRuntime.instance.store;
      if (podcastReferencesOnly) {
        store.transaction(() {
          for (final bundle in podcastBundles) {
            final channel = PodcastChannel.fromJson(
              Map<String, dynamic>.from(bundle['channel']),
            );
            final existing = store.channel(channel.id);
            if (existing != null && existing.feedUrl != channel.feedUrl) {
              throw const FormatException('播客频道身份与订阅地址不一致');
            }
            for (final raw in bundle['episodes'] as List? ?? []) {
              final episode = PodcastEpisode.fromJson(
                Map<String, dynamic>.from(raw),
              );
              final old = store.episode(episode.id);
              if (old != null &&
                  (old.channelId != channel.id ||
                      !old.media.any(
                        (m) => m.url == episode.media.single.url,
                      ))) {
                throw const FormatException('播客节目身份与播放地址不一致');
              }
            }
          }
          for (final bundle in podcastBundles) {
            final channel = PodcastChannel.fromJson(
              Map<String, dynamic>.from(bundle['channel']),
            );
            if (store.channel(channel.id) == null) {
              store.write('channel', channel.id, channel.toJson());
            }
            for (final raw in bundle['episodes'] as List? ?? []) {
              final episode = PodcastEpisode.fromJson(
                Map<String, dynamic>.from(raw),
              );
              if (store.episode(episode.id) == null) {
                store.write(
                  'episode',
                  episode.id,
                  episode.toJson(),
                  channel: channel.id,
                );
              }
            }
          }
        });
      } else {
        for (final bundle in podcastBundles) {
          store.importChannel(bundle);
        }
      }
    }
    if (rawCollections.isEmpty && rawVideos.isEmpty) {
      throw const FormatException('导出包快照为空');
    }

    if (network != null) {
      _validateReceivedFolderSnapshot(rawCollections, rawVideos, network);
      final children = <String, List<String>>{};
      for (final record in [...rawCollections, ...rawVideos]) {
        final id = record['exportId'] as String;
        final parent = record['parentExportId'];
        if (parent is String) {
          (children[parent] ??= []).add(id);
        }
        final stableId = network.stableIds[id];
        if (network.suppressedNodeIds.contains(stableId) ||
            network.protectedNodeIds.contains(stableId)) {
          network.blockedSourceIds.add(id);
        }
      }
      // Removed and conflicted folders protect future descendants too,
      // including nodes that have never had a local mapping.
      final pendingBlocked = network.blockedSourceIds.toList();
      for (var index = 0; index < pendingBlocked.length; index++) {
        for (final child in children[pendingBlocked[index]] ?? <String>[]) {
          if (network.blockedSourceIds.add(child)) {
            pendingBlocked.add(child);
          }
        }
      }
    }

    final destinationParentId = network == null
        ? await library.resolveImportCardParentId(
            feature: ImportCardFeature.fluentPack,
            openedFromFolderId: openedFromFolderId,
            request: importPlacement,
          )
        : null;
    final snapshotBatchId = library.beginImportBatch(
      title: packageName,
      sourceKind: LibraryImportSourceKind.fluentPack,
      targetCollectionId: destinationParentId,
    );

    final dataRoot = await SettingsService().resolveLargeDataRootDir();
    final retrySpec = _retrySpecs[task.id];
    final createdAssetPaths = <String>{};
    Future<String?> copyTrackedAsset({
      required Object? reference,
      required Directory destinationDirectory,
      required String destinationStem,
    }) async {
      final copied = await _copyAssetToManagedStorage(
        extraction: extraction,
        reference: reference,
        destinationDirectory: destinationDirectory,
        destinationStem: destinationStem,
      );
      if (copied != null) {
        createdAssetPaths.add(copied);
        retrySpec?.createdAssetPaths.add(copied);
        if (retrySpec != null) await _persistStateNow();
      }
      return copied;
    }

    Future<File> copyCloudReuse(
      File source,
      String id,
      String expectedKey,
    ) async {
      final directory = await AppStorageService.instance.downloadFiles(
        'cloud_drive',
      );
      final extension = p.extension(source.path).toLowerCase();
      final safeExtension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
          ? extension
          : '.mp4';
      final target = File(p.join(directory.path, 'received_$id$safeExtension'));
      final partial = File('${target.path}.partial');
      final digests = <Digest>[];
      final digest = sha256.startChunkedConversion(_FolderDigestSink(digests));
      var bytes = 0;
      try {
        await target.parent.create(recursive: true);
        final output = partial.openWrite();
        try {
          await output.addStream(
            source.openRead().map((chunk) {
              if (task.cancelRequested ||
                  network?.isCancelled?.call() == true) {
                throw const _TransferCancelled();
              }
              digest.add(chunk);
              bytes += chunk.length;
              return chunk;
            }),
          );
          await output.flush();
        } finally {
          await output.close();
          digest.close();
        }
        if ('sha256:$bytes:${digests.single}' != expectedKey) {
          throw const FormatException('复用的本机媒体发生变化，请重新接收');
        }
        await partial.rename(target.path);
        createdAssetPaths.add(target.path);
        retrySpec?.createdAssetPaths.add(target.path);
        if (retrySpec != null) await _persistStateNow();
        return target;
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }

    VideoCollection? existingRoot = archiveRoot;
    if (network != null) {
      final claimedLocalIds = <String>{};
      for (final entry in network.stableIds.entries) {
        final local =
            network.existingLocalIds[entry.value] ?? network.idMap[entry.key];
        if (local != null && claimedLocalIds.add(local)) {
          network.idMap[entry.key] = local;
        } else {
          // Different stable nodes never alias the same logical card, even if
          // an old content-based import once merged their local IDs.
          network.idMap.remove(entry.key);
        }
      }
      final requested = network.requestedTargetId;
      final knownId = network.idMap[network.sourceCollectionId];
      existingRoot = library.getCollection(requested ?? knownId ?? '');
      final rootBlocked = network.blockedSourceIds.contains(
        network.sourceCollectionId,
      );
      if (existingRoot?.isRecycled == true && !rootBlocked) {
        existingRoot = null;
      }
      if (rootBlocked && existingRoot == null) {
        if (snapshotBatchId != null) {
          library.abortImportBatch(snapshotBatchId);
        }
        throw FormatException(
          network.suppressedNodeIds.contains(
                network.stableIds[network.sourceCollectionId],
              )
              ? '此文件夹已在本机移除'
              : '此文件夹存在同步冲突，暂不能接收',
        );
      }
      if (requested != null && existingRoot == null) {
        throw const FormatException('接收目标文件夹已不存在');
      }
    }
    final sourceRootRecord = network == null
        ? null
        : rawCollections.firstWhere(
            (item) => item['exportId'] == network.sourceCollectionId,
          );
    String? plannedRootId;
    if (network != null && existingRoot == null) {
      plannedRootId =
          network.idMap[network.sourceCollectionId] ?? const Uuid().v4();
      network.idMap[network.sourceCollectionId] = plannedRootId;
      await network.persistMapping();
    }
    final packageRoot =
        existingRoot ??
        await library.createCollection(
          sourceRootRecord?['name']?.toString() ?? packageName,
          destinationParentId,
          id: plannedRootId,
          coverLabel: sourceRootRecord?['coverLabel'] is String
              ? sourceRootRecord!['coverLabel'] as String
              : null,
          sourceRef: MediaSourceRef.fromJsonOrNull(
            sourceRootRecord?['sourceRef'],
          ),
          podcastRef: PodcastChannelRef.fromJsonOrNull(
            sourceRootRecord?['podcastRef'],
          ),
        );
    final ownsRoot = existingRoot == null;
    final createdIds = <String>[];
    if (ownsRoot) {
      library.noteImportedCollection(packageRoot.id, batchId: snapshotBatchId);
    }
    if (retrySpec != null && ownsRoot) {
      retrySpec.transactionRootId = packageRoot.id;
      await _persistStateNow();
    }
    final idMap = network?.idMap ?? <String, String>{};
    if (network != null) {
      network.rootId = packageRoot.id;
      idMap[network.sourceCollectionId] = packageRoot.id;
    }
    var importedCount = 0;
    var importedCollectionCount = 0;
    try {
      if (network != null) {
        // Commit the destination before adding content. A retry can resume this
        // root even when the manager never received the completed result.
        await network.persistMapping();
        if (network.reconcileStructure &&
            existingRoot != null &&
            !network.blockedSourceIds.contains(network.sourceCollectionId)) {
          network.metadataChanges.add(
            _SyncMetadataChange(
              packageRoot.id,
              sourceRootRecord?['name']?.toString() ?? packageName,
              packageRoot.parentId,
              preserveRootParent: true,
            ),
          );
        }
        if (ownsRoot && sourceRootRecord?['thumbnailPath'] != null) {
          final cover = await copyTrackedAsset(
            reference: sourceRootRecord!['thumbnailPath'],
            destinationDirectory: Directory(
              p.join(dataRoot.path, 'thumbnails'),
            ),
            destinationStem: packageRoot.id,
          );
          if (cover != null) {
            await library.updateCollectionThumbnail(packageRoot.id, cover);
          }
        }
      }
      final pending = List<Map<String, dynamic>>.from(rawCollections)
        ..removeWhere(
          (item) =>
              network != null &&
              (item['exportId'] == network.sourceCollectionId ||
                  network.blockedSourceIds.contains(item['exportId'])),
        );
      final resolvedFolders = <String>{
        if (network != null) network.sourceCollectionId,
      };
      while (pending.isNotEmpty) {
        var progressed = false;
        for (final record in List<Map<String, dynamic>>.from(pending)) {
          if (task.cancelRequested || network?.isCancelled?.call() == true) {
            throw const _TransferCancelled();
          }
          final exportId = record['exportId']?.toString() ?? '';
          if (exportId.isEmpty) {
            pending.remove(record);
            continue;
          }
          final parentExportId = record['parentExportId']?.toString();
          if (parentExportId != null &&
              parentExportId.isNotEmpty &&
              (network == null
                  ? !idMap.containsKey(parentExportId)
                  : !resolvedFolders.contains(parentExportId))) {
            continue;
          }
          final mappedId = network == null ? null : idMap[exportId];
          if (archiveRoot != null && record['podcastRef'] == null) {
            final parentId = idMap[parentExportId] ?? packageRoot.id;
            final name = record['archiveName'] ?? record['name'];
            final existing = library
                .getContents(parentId)
                .whereType<VideoCollection>()
                .where(
                  (folder) =>
                      !folder.isRecycled &&
                      !folder.isPodcast &&
                      folder.name == name,
                )
                .firstOrNull;
            if (existing != null) {
              idMap[exportId] = existing.id;
              resolvedFolders.add(exportId);
              pending.remove(record);
              progressed = true;
              continue;
            }
          }
          final newId =
              mappedId != null &&
                  library.getCollection(mappedId) == null &&
                  library.getVideo(mappedId) == null
              ? mappedId
              : const Uuid().v4();
          if (network != null) {
            final parentId = idMap[parentExportId] ?? packageRoot.id;
            final known = library.getCollection(idMap[exportId] ?? '');
            final named = library
                .getContents(parentId)
                .whereType<VideoCollection>()
                .where(
                  (item) =>
                      !item.isRecycled &&
                      item.name == record['name'] &&
                      !idMap.entries.any(
                        (entry) =>
                            entry.key != exportId && entry.value == item.id,
                      ),
                )
                .toList();
            final reusable =
                known != null &&
                    !known.isRecycled &&
                    _isInReceivedTree(library, known.id, packageRoot.id)
                ? known
                : network.stableIds.isEmpty && named.length == 1
                ? named.single
                : null;
            if (reusable != null) {
              idMap[exportId] = reusable.id;
              if (network.reconcileStructure) {
                network.metadataChanges.add(
                  _SyncMetadataChange(
                    reusable.id,
                    record['name']?.toString() ?? reusable.name,
                    parentId,
                  ),
                );
              }
              resolvedFolders.add(exportId);
              pending.remove(record);
              progressed = true;
              continue;
            }
            idMap[exportId] = newId;
            await network.persistMapping();
          }
          final thumbnail = await copyTrackedAsset(
            reference: record['thumbnailPath'],
            destinationDirectory: Directory(
              p.join(dataRoot.path, 'thumbnails'),
            ),
            destinationStem: newId,
          );
          final collection = await library.createCollection(
            record['name']?.toString().trim().isNotEmpty == true
                ? record['name'].toString().trim()
                : '未命名文件夹',
            parentExportId == null || parentExportId.isEmpty
                ? packageRoot.id
                : idMap[parentExportId],
            id: network == null ? null : newId,
            thumbnailPath: thumbnail,
            coverLabel: record['coverLabel'] is String
                ? record['coverLabel'] as String
                : null,
            sourceRef: MediaSourceRef.fromJsonOrNull(record['sourceRef']),
            podcastRef: PodcastChannelRef.fromJsonOrNull(record['podcastRef']),
          );
          idMap[exportId] = collection.id;
          resolvedFolders.add(exportId);
          createdIds.add(collection.id);
          if (network != null) await network.persistMapping();
          library.noteImportedCollection(
            collection.id,
            batchId: snapshotBatchId,
          );
          pending.remove(record);
          progressed = true;
          importedCollectionCount++;
          if (importedCollectionCount % 16 == 0) {
            task
              ..status = PortableTransferStatus.running
              ..subtitle =
                  '正在恢复文件夹 $importedCollectionCount/${rawCollections.length}';
            notifyListeners();
            await Future<void>.delayed(Duration.zero);
          }
        }
        if (!progressed) {
          throw const FormatException('文件夹层级损坏或存在循环引用');
        }
      }

      for (var index = 0; index < rawVideos.length; index++) {
        if (task.cancelRequested || network?.isCancelled?.call() == true) {
          throw const _TransferCancelled();
        }
        final record = rawVideos[index];
        if (network?.blockedSourceIds.contains(record['exportId']) == true) {
          network!.skipped++;
          continue;
        }
        final rawVideo = record['video'];
        if (rawVideo is! Map) {
          throw const FormatException('媒体卡片数据损坏');
        }
        final videoJson = Map<String, dynamic>.from(rawVideo);
        final newId = const Uuid().v4();
        final parentExportId = record['parentExportId']?.toString();
        videoJson['id'] = newId;
        videoJson['parentId'] = parentExportId == null || parentExportId.isEmpty
            ? packageRoot.id
            : idMap[parentExportId] ?? packageRoot.id;
        videoJson['isRecycled'] = false;
        videoJson['recycleTime'] = null;
        videoJson['playbackPath'] = null;
        videoJson['bilibiliDownloadPath'] = null;

        final isOnline = record['isOnline'] == true;
        VideoItem? physicalReuse;
        VideoItem? revisionTarget;
        File? ownedCloudReuse;
        if (network != null) {
          final matching = await _findReceivedMedia(
            library,
            extraction,
            videoJson,
            record,
            network,
            task,
          );
          final known = library.getVideo(idMap[record['exportId']] ?? '');
          final desiredKey = network.incomingContentKeys[record['exportId']];
          final stableMatch =
              known != null &&
                  !known.isRecycled &&
                  _isInReceivedTree(library, known.id, packageRoot.id)
              ? known
              : null;
          final sameStableContent =
              stableMatch != null &&
              network.contentByLocalId[stableMatch.id] == desiredKey;
          final reuseCandidate = sameStableContent
              ? stableMatch
              : stableMatch == null && network.stableIds.isEmpty
              ? matching
              : null;
          final incomingCloud = MediaSourceRef.fromJsonOrNull(
            videoJson['sourceRef'],
          )?.cloudDrive;
          // Equal bytes can be shared without replacing a cloud card's stable
          // remote identity with an unrelated local card's identity/progress.
          final reusableCard =
              incomingCloud != null &&
                  reuseCandidate?.sourceRef?.cloudDrive?.sourceKey !=
                      incomingCloud.sourceKey
              ? null
              : reuseCandidate;
          if (reusableCard != null) {
            if (!communityMediaIsLocal(reusableCard.path) &&
                !isOnline &&
                record['cloudDownloadQuality'] is Map) {
              await _registerReceivedCloudFile(
                reusableCard,
                record['cloudDownloadQuality'] as Map,
                extraction,
              );
            }
            idMap[record['exportId'].toString()] = reusableCard.id;
            if (network.reconcileStructure) {
              network.metadataChanges.add(
                _SyncMetadataChange(
                  reusableCard.id,
                  videoJson['title']?.toString() ?? reusableCard.title,
                  videoJson['parentId'] as String?,
                ),
              );
            }
            network.skipped++;
            task.progress = (index + 1) / rawVideos.length;
            task.subtitle = '正在导入 ${index + 1}/${rawVideos.length}';
            notifyListeners();
            continue;
          }
          revisionTarget = stableMatch;
          physicalReuse = network.mediaByContent[desiredKey];
          if (record['reuseContent'] == true && physicalReuse == null) {
            throw const FormatException('接收端已有文件发生变化，请重新发送资源');
          }
          if (incomingCloud != null &&
              physicalReuse != null &&
              physicalReuse.sourceRef?.cloudDrive?.sourceKey !=
                  incomingCloud.sourceKey) {
            // Cache deletion must never delete an unrelated local card's file.
            // Reuse its verified bytes locally, but give the cloud cache its
            // own permanent copy and independently check those copied bytes.
            final reusedFile = File(
              physicalReuse.bilibiliDownloadPath ?? physicalReuse.path,
            );
            await network.beforeExtraLocalCopy?.call(await reusedFile.length());
            ownedCloudReuse = await copyCloudReuse(
              reusedFile,
              newId,
              desiredKey!,
            );
          }
          // Sync applies causally tracked playback state after this import.
          videoJson['lastPositionMs'] = 0;
          videoJson['isTransient'] = false;
        }
        if (!isOnline) {
          final primary =
              ownedCloudReuse ??
              (physicalReuse == null
                  ? _resolveAssetReference(extraction, videoJson['path'])
                  : File(
                      physicalReuse.bilibiliDownloadPath ?? physicalReuse.path,
                    ));
          if (primary == null || !await primary.exists()) {
            throw FormatException('媒体文件缺失：${videoJson['title'] ?? newId}');
          }
          videoJson['path'] = primary.path;
          videoJson['sourceFingerprint'] = null;
        } else {
          final source = MediaSourceRef.fromJsonOrNull(videoJson['sourceRef']);
          if (source?.kind == MediaSourceKind.podcastEpisode &&
              source?.podcast != null) {
            videoJson['path'] = 'podcast:${source!.podcast!.episodeId}';
          } else if (source?.kind == MediaSourceKind.cloudDrive &&
              source?.cloudDrive != null) {
            videoJson['path'] = source!.cloudDrive!.logicalUri;
            videoJson['sourceFingerprint'] = null;
          } else if (source?.kind != MediaSourceKind.bilibiliStream ||
              source?.bvid?.isNotEmpty != true ||
              source?.cid == null) {
            throw FormatException('在线卡片缺少播放来源：${videoJson['title'] ?? newId}');
          } else {
            videoJson['path'] =
                'bilibili://stream/${source!.bvid}?cid=${source.cid}';
            videoJson['sourceFingerprint'] = 'bilibili-stream-card:$newId';
          }
        }

        videoJson['thumbnailPath'] = await copyTrackedAsset(
          reference: videoJson['thumbnailPath'],
          destinationDirectory: Directory(p.join(dataRoot.path, 'thumbnails')),
          destinationStem: newId,
        );
        videoJson['danmakuPath'] = await copyTrackedAsset(
          reference: videoJson['danmakuPath'],
          destinationDirectory: Directory(p.join(dataRoot.path, 'danmaku')),
          destinationStem: '${newId}_danmaku',
        );

        // Restore directly into the new card's permanent subtitle directory.
        // Later adoption must not move files away from their timing companions
        // or leave any selected track pointing into the extraction directory.
        final subtitleDirectory = Directory(
          p.join(dataRoot.path, 'subtitles', 'tasks', newId),
        );
        final restoredSubtitles = <String, String>{};
        Future<String?> restoreSubtitle(Object? reference) async {
          final source = _resolveAssetReference(extraction, reference);
          if (source == null || !await source.exists()) return null;
          final existing = restoredSubtitles[source.path];
          if (existing != null) return existing;
          final copied = await copyTrackedAsset(
            reference: reference,
            destinationDirectory: subtitleDirectory,
            destinationStem: p.basenameWithoutExtension(source.path),
          );
          if (copied == null) return null;
          restoredSubtitles[source.path] = copied;
          await copyTrackedAsset(
            reference: '$reference${SubtitleWordTimingStore.suffix}',
            destinationDirectory: subtitleDirectory,
            destinationStem: '${p.basename(copied)}.wordtiming',
          );
          return copied;
        }

        Future<Map<String, String>> restoreSubtitleMap(Object? raw) async {
          final result = <String, String>{};
          if (raw is Map) {
            for (final entry in raw.entries) {
              final copied = await restoreSubtitle(entry.value);
              if (copied != null) result[entry.key.toString()] = copied;
            }
          }
          return result;
        }

        final additional = await restoreSubtitleMap(
          videoJson['extraSubtitles'],
        );
        final local = await restoreSubtitleMap(videoJson['localSubtitles']);
        final rawManagedAssets = videoJson['managedSubtitleAssets'];
        if (rawManagedAssets is List) {
          final kept = <Map<String, dynamic>>[];
          final assetIds = <String, String>{
            for (final asset in rawManagedAssets.whereType<Map>())
              if (asset['assetId'] is String)
                asset['assetId'] as String: const Uuid().v4(),
          };
          for (final rawAsset in rawManagedAssets.whereType<Map>()) {
            final asset = Map<String, dynamic>.from(rawAsset);
            final copied = await restoreSubtitle(asset['path']);
            if (copied == null) continue;
            asset['path'] = copied;
            asset['assetId'] = assetIds[asset['assetId']] ?? const Uuid().v4();
            asset['sourceAssetId'] = assetIds[asset['sourceAssetId']];
            final timing = await copyTrackedAsset(
              reference: asset['wordTimingPath'],
              destinationDirectory: subtitleDirectory,
              destinationStem: '${p.basename(copied)}.wordtiming',
            );
            asset['wordTimingPath'] =
                timing ??
                (await File(SubtitleWordTimingStore.pathFor(copied)).exists()
                    ? SubtitleWordTimingStore.pathFor(copied)
                    : null);
            kept.add(asset);
            final label = asset['displayName']?.toString().trim() ?? '';
            _rememberSubtitlePath(
              local,
              label.isNotEmpty ? label : p.basenameWithoutExtension(copied),
              copied,
            );
          }
          videoJson['managedSubtitleAssets'] = kept;
        }
        final primarySubtitle = await restoreSubtitle(
          videoJson['subtitlePath'],
        );
        final secondarySubtitle = await restoreSubtitle(
          videoJson['secondarySubtitlePath'],
        );
        if (primarySubtitle != null) {
          _rememberSubtitlePath(
            additional,
            p.basenameWithoutExtension(primarySubtitle),
            primarySubtitle,
          );
          videoJson['subtitlePath'] = primarySubtitle;
        } else {
          videoJson['subtitlePath'] = null;
        }
        if (secondarySubtitle != null) {
          _rememberSubtitlePath(
            local,
            p.basenameWithoutExtension(secondarySubtitle),
            secondarySubtitle,
          );
          videoJson['secondarySubtitlePath'] = secondarySubtitle;
        } else {
          videoJson['secondarySubtitlePath'] = null;
        }
        videoJson['extraSubtitles'] = additional.isEmpty ? null : additional;
        videoJson['localSubtitles'] = local.isEmpty ? null : local;

        final rawShot = videoJson['bilibiliVideoShot'];
        if (rawShot is Map) {
          final shotJson = Map<String, dynamic>.from(rawShot);
          final spriteRefs = shotJson['spritePaths'];
          final copiedSprites = <String>[];
          if (spriteRefs is List) {
            final shotDir = Directory(
              p.join(
                dataRoot.path,
                BilibiliVideoShotService.directoryName,
                newId,
              ),
            );
            for (
              var spriteIndex = 0;
              spriteIndex < spriteRefs.length;
              spriteIndex++
            ) {
              if (task.cancelRequested) throw const _TransferCancelled();
              final copied = await copyTrackedAsset(
                reference: spriteRefs[spriteIndex],
                destinationDirectory: shotDir,
                destinationStem:
                    'sprite_${spriteIndex.toString().padLeft(3, '0')}',
              );
              if (copied != null) copiedSprites.add(copied);
            }
          }
          shotJson['spritePaths'] = copiedSprites;
          videoJson['bilibiliVideoShot'] = copiedSprites.isEmpty
              ? null
              : shotJson;
        }

        final item = VideoItem.fromJson(videoJson);
        final cachedCloud = record['cachedCloudMedia'];
        if (cachedCloud is Map) {
          final source = CacheSource.fromItem(item);
          if (!isOnline ||
              source == null ||
              source.ref.cloudDrive == null ||
              cachedCloud['quality'] is! Map) {
            throw const FormatException('网盘缓存记录缺少来源或画质');
          }
          final quality = CacheQuality.fromJson(
            Map<String, dynamic>.from(cachedCloud['quality'] as Map),
          );
          final revision = source.ref.cloudDrive!.revision;
          if (revision != null &&
              revision.isNotEmpty &&
              quality.revision != revision) {
            throw const FormatException('网盘缓存版本与卡片来源不一致');
          }
          final copied = await copyTrackedAsset(
            reference: cachedCloud['path'],
            destinationDirectory: await AppStorageService.instance
                .downloadFiles('cloud_drive'),
            destinationStem: 'imported_$newId',
          );
          if (copied == null || await File(copied).length() <= 0) {
            throw const FormatException('导出包缺少完整网盘缓存文件');
          }
          final cache = MediaCacheService.instance;
          if (cache == null) throw StateError('媒体缓存服务尚未初始化');
          await cache.registerLegacy(
            CacheVariant(
              source: source,
              quality: quality,
              path: copied,
              bytes: await File(copied).length(),
              createdAt: item.lastUpdated,
              managed: false,
              assetId: 'portable_$newId',
            ),
          );
          if (cache.persistenceError != null) await cache.flush();
        }
        final cachedMedia = record['cachedBilibiliMedia'];
        if (cachedMedia is Map) {
          if (!isOnline ||
              CacheSource.fromItem(item)?.isBilibili != true ||
              cachedMedia['quality'] is! Map) {
            throw const FormatException('B 站缓存记录缺少来源或画质');
          }
          final copied = await copyTrackedAsset(
            reference: cachedMedia['path'],
            destinationDirectory: await AppStorageService.instance
                .downloadFiles('bilibili'),
            destinationStem: 'imported_$newId',
          );
          if (copied == null) throw const FormatException('导出包缺少 B 站缓存文件');
          final cache = MediaCacheService.instance;
          if (cache == null) throw StateError('媒体缓存服务尚未初始化');
          await registerBilibiliDownload(
            cache,
            item,
            path: copied,
            cacheQuality: CacheQuality.fromJson(
              Map<String, dynamic>.from(cachedMedia['quality'] as Map),
            ),
          );
          if (cachedMedia['downloadOrigin'] == true) {
            item.bilibiliDownloadPath = copied;
          }
        }
        createdIds.add(item.id);
        if (network != null) {
          final exportId = record['exportId'] as String;
          if (revisionTarget == null) {
            idMap[exportId] = item.id;
          } else {
            idMap[exportId] = revisionTarget.id;
            network.stagedMedia[exportId] = _FolderStagedMedia(
              existingId: revisionTarget.id,
              stagedId: item.id,
            );
          }
          // The intent must reach durable storage before addSingleVideo can
          // publish/save the new card. A process exit cannot orphan its ID.
          await network.persistMapping();
        }
        final insertedId =
            !communityMediaIsLocal(item.path) && item.sourceRef?.podcast != null
            ? (await library.upsertPodcastEpisode(item)).id
            : await library.addSingleVideo(
                item,
                useOriginalPath: false,
                reuseExistingItem: false,
                activityBatchId: snapshotBatchId,
                sourceKind: LibraryImportSourceKind.fluentPack,
                retainSharedMediaPath: physicalReuse != null,
                persistReceivedFile: network != null,
              );
        if (insertedId == null) {
          throw StateError('无法创建媒体卡片：${item.title}');
        }
        final cloudQuality = record['cloudDownloadQuality'];
        if (!communityMediaIsLocal(item.path) &&
            !isOnline &&
            cloudQuality is Map) {
          await _registerReceivedCloudFile(item, cloudQuality, extraction);
        }
        final downloadedQuality = record['bilibiliDownloadQuality'];
        if (!communityMediaIsLocal(item.path) &&
            !isOnline &&
            downloadedQuality is Map &&
            item.isBilibiliExported &&
            CacheSource.fromItem(item)?.isBilibili == true) {
          final cache = MediaCacheService.instance;
          if (cache == null) throw StateError('媒体缓存服务尚未初始化');
          await registerBilibiliDownload(
            cache,
            item,
            path: item.path,
            cacheQuality: CacheQuality.fromJson(
              Map<String, dynamic>.from(downloadedQuality),
            ),
          );
          await library.promoteBilibiliDownloadCards([item.id]);
        }
        if (network != null) {
          if (library.hasPersistenceFailure) {
            throw const FormatException('媒体库保存失败，请稍后继续');
          }
          var localId = insertedId;
          if (revisionTarget != null) {
            network.revisions.add((
              exportId: record['exportId'] as String,
              existingId: revisionTarget.id,
              importedId: insertedId,
            ));
            localId = revisionTarget.id;
          }
          final actual = library.getVideo(insertedId)!;
          final retainedPath = actual.bilibiliDownloadPath ?? actual.path;
          if (!isOnline &&
              (!await File(retainedPath).exists() ||
                  p.isWithin(extraction.path, retainedPath))) {
            throw const FormatException('视频尚未保存到本机，请重试');
          }
          idMap[record['exportId'].toString()] = localId;
          if (network.reconcileStructure) {
            network.metadataChanges.add(
              _SyncMetadataChange(
                localId,
                videoJson['title']?.toString() ?? actual.title,
                videoJson['parentId'] as String?,
              ),
            );
          }
          network.imported++;
          network.mediaByIdentity[_receivedMediaIdentity(
                videoJson,
                record,
                network,
              )] =
              actual;
          final contentKey = network.incomingContentKeys[record['exportId']]!;
          network.mediaByContent[contentKey] = actual;
          network.contentByLocalId[localId] = contentKey;
          if (!isOnline) {
            final stat = await File(retainedPath).stat();
            network.fingerprints[localId] = PortableFolderFingerprint(
              path: retainedPath,
              size: stat.size,
              modifiedMs: stat.modified.millisecondsSinceEpoch,
              sha256: contentKey.split(':').last,
            );
          }
          await network.persistMapping();
        }
        importedCount++;
        task.status = PortableTransferStatus.running;
        task.progress = network == null
            ? 0.4 + ((index + 1) / rawVideos.length * 0.6)
            : (index + 1) / rawVideos.length;
        task.subtitle = '正在恢复卡片 ${index + 1}/${rawVideos.length}';
        notifyListeners();
        if ((index + 1) % 8 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (network?.isCancelled?.call() == true) {
        throw const _TransferCancelled();
      }
      if (network != null) {
        for (final revision in network.revisions) {
          await library.commitSyncMediaRevision(
            existingId: revision.existingId,
            importedId: revision.importedId,
          );
          if (library.hasPersistenceFailure) {
            throw const FormatException('媒体库保存失败，请稍后继续');
          }
          network.stagedMedia.remove(revision.exportId);
          await network.persistMapping();
        }
        for (final change in network.metadataChanges) {
          await library.applySyncItemMetadata(
            change.id,
            name: change.name,
            parentId: change.parentId,
            preserveRootParent: change.preserveRootParent,
          );
        }
      }
      if (retrySpec != null) {
        retrySpec
          ..transactionRootId = null
          ..createdAssetPaths.clear();
      }
      if (snapshotBatchId != null) {
        await library.completeImportBatch(snapshotBatchId);
      }
      for (final bundle in podcastBundles) {
        for (final raw in bundle['downloads'] as List? ?? []) {
          final descriptor = Map<String, dynamic>.from(raw);
          final file = _resolveAssetReference(extraction, descriptor['path']);
          final runtime = PodcastRuntime.instance,
              episode = PodcastRuntime.instance.store.episode(
                descriptor['episodeId'],
              );
          if (file == null || episode == null || !await file.exists()) continue;
          final media = episode.media
              .where((m) => m.url == descriptor['mediaUrl'])
              .firstOrNull;
          if (media != null) {
            await runtime.controller.mediaStore.importFile(
              episode,
              media,
              file,
            );
          }
        }
      }
      if (podcastBundles.isNotEmpty) {
        PodcastRuntime.instance.controller.reload();
      }
      return importedCount;
    } catch (_) {
      if (snapshotBatchId != null) {
        library.abortImportBatch(snapshotBatchId);
      }
      await _deleteTransferStaging(
        library,
        ownsRoot ? <String>[packageRoot.id] : createdIds.reversed.toList(),
      );
      if (network != null) {
        if (library.hasPersistenceFailure) {
          throw const FormatException('媒体库保存失败，请稍后继续');
        }
        network.stagedMedia.removeWhere(
          (_, item) => createdIds.contains(item.stagedId),
        );
        await network.persistMapping();
      }
      for (final assetPath in createdAssetPaths) {
        final file = File(assetPath);
        if (await file.exists() &&
            !_receivedAssetReferenced(library, assetPath)) {
          try {
            await file.delete();
            await MediaCacheService.instance?.forgetDeletedFiles([assetPath]);
          } catch (_) {}
        }
      }
      if (retrySpec != null) {
        retrySpec
          ..transactionRootId = null
          ..createdAssetPaths.clear();
        await _persistStateNow();
      }
      rethrow;
    }
  }

  Future<void> _registerReceivedCloudFile(
    VideoItem item,
    Map rawQuality,
    Directory extraction,
  ) async {
    final cache = MediaCacheService.instance;
    final source = CacheSource.fromItem(item);
    if (cache == null || source?.ref.cloudDrive == null) {
      throw const FormatException('网盘媒体缺少缓存服务或来源');
    }
    final quality = CacheQuality.fromJson(
      Map<String, dynamic>.from(rawQuality),
    );
    final revision = source!.ref.cloudDrive!.revision;
    if (revision != null &&
        revision.isNotEmpty &&
        quality.revision != revision) {
      throw const FormatException('网盘缓存版本与媒体来源不一致');
    }
    final file = File(item.path);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size <= 0 ||
        p.isWithin(extraction.path, item.path)) {
      throw const FormatException('网盘媒体尚未保存到本机');
    }
    await cache.registerLegacy(
      CacheVariant(
        source: source,
        quality: quality,
        path: file.path,
        bytes: stat.size,
        createdAt: item.lastUpdated,
        managed: false,
        assetId: 'portable_${item.id}',
      ),
    );
    if (cache.persistenceError != null) await cache.flush();
  }

  Future<void> _cleanupAfterPortableWorker(
    PortableTransferTask task,
    Future<void> Function() cleanup,
  ) async {
    final control = _workers[task.id];
    Future<void> complete() async {
      try {
        await cleanup();
      } finally {
        if (identical(_workers[task.id], control)) _workers.remove(task.id);
      }
    }

    if (control != null && control.cooperative && !control.hasExited) {
      unawaited(
        control.exited.then((_) => complete()).catchError((Object error) {
          debugPrint('Portable deferred cleanup failed: $error');
        }),
      );
      return;
    }
    await complete();
  }

  Future<Map<String, dynamic>> _runWorker({
    required PortableTransferTask task,
    required void Function(Map<String, dynamic>) entryPoint,
    required Map<String, dynamic> payload,
    bool useNetworkProgress = false,
    ZipExportHandle? outputOwnership,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    final exited = Completer<void>();
    final completer = Completer<Map<String, dynamic>>();
    Directory? markerDirectory;
    File? marker;
    if (outputOwnership != null) {
      final temp = await getTemporaryDirectory();
      final base = await Directory(
        p.join(temp.path, zipExportScratchDirectoryName),
      ).create(recursive: true);
      markerDirectory = await base.createTemp('portable_${task.id}_');
      marker = File(p.join(markerDirectory.path, '.cancel'));
    }
    late final StreamSubscription<dynamic> messageSubscription;
    late final StreamSubscription<dynamic> errorSubscription;
    final exitSubscription = exits.listen((_) {
      if (!exited.isCompleted) exited.complete();
      Timer.run(() {
        if (!completer.isCompleted) {
          completer.completeError(
            task.cancelRequested
                ? const _TransferCancelled()
                : StateError('后台处理已退出'),
          );
        }
      });
    });
    late final Isolate isolate;
    try {
      isolate = await Isolate.spawn<Map<String, dynamic>>(
        entryPoint,
        <String, dynamic>{
          ...payload,
          'sendPort': messages.sendPort,
          if (marker != null) 'cancelPath': marker.path,
        },
        onError: errors.sendPort,
        onExit: exits.sendPort,
        errorsAreFatal: true,
        debugName: 'portable-${task.kind.name}-${task.id}',
      );
    } catch (_) {
      await exitSubscription.cancel();
      messages.close();
      errors.close();
      exits.close();
      if (markerDirectory != null) {
        await markerDirectory.delete(recursive: true);
      }
      rethrow;
    }
    final control = _PortableWorkerControl(
      isolate,
      completer,
      marker: marker,
      exitSignal: exited,
    );
    if (outputOwnership != null) outputOwnership.cancelSession = control.cancel;
    _workers[task.id] = control;
    messageSubscription = messages.listen((dynamic raw) {
      if (raw is! Map) return;
      final message = Map<String, dynamic>.from(raw);
      switch (message['type']) {
        case 'progress':
          if (completer.isCompleted) return;
          task.status = PortableTransferStatus.running;
          task.progress =
              ((message[useNetworkProgress ? 'networkProgress' : 'progress']
                              as num?)
                          ?.toDouble() ??
                      0)
                  .clamp(0, 0.99);
          task.processedBytes =
              (message['processedBytes'] as num?)?.toInt() ??
              task.processedBytes;
          task.subtitle = message['subtitle']?.toString() ?? task.subtitle;
          notifyListeners();
        case 'done':
          if (!completer.isCompleted) {
            final result = message['result'];
            completer.complete(
              result is Map
                  ? Map<String, dynamic>.from(result)
                  : <String, dynamic>{},
            );
          }
        case 'error':
          if (!completer.isCompleted) {
            final text = message['message']?.toString() ?? '后台处理失败';
            completer.completeError(
              message['format'] == true
                  ? FormatException(text)
                  : StateError(text),
            );
          }
      }
    });
    errorSubscription = errors.listen((dynamic raw) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('后台处理异常：$raw'));
      }
    });
    if (task.cancelRequested || outputOwnership?.isCancelled == true) {
      control.cancel();
    }
    Future<void> closeChannels() async {
      await messageSubscription.cancel();
      await errorSubscription.cancel();
      await exitSubscription.cancel();
      messages.close();
      errors.close();
      exits.close();
      final directory = markerDirectory;
      if (directory != null) {
        try {
          await directory.delete(recursive: true);
          final parent = directory.parent;
          if (await parent.exists() &&
              await parent.list(followLinks: false).isEmpty) {
            await parent.delete();
          }
        } catch (_) {}
      }
    }

    try {
      return await completer.future;
    } finally {
      if (control.cooperative) {
        if (await control.waitForExit()) {
          await closeChannels();
        } else {
          unawaited(control.exited.then((_) => closeChannels()));
          throw StateError('导出写入尚未退出，临时文件和源文件保护已保留，退出后会继续清理');
        }
      } else {
        if (identical(_workers[task.id], control)) _workers.remove(task.id);
        isolate.kill(priority: Isolate.immediate);
        await closeChannels();
      }
    }
  }

  void _validateReceivedFolderSnapshot(
    List<Map<String, dynamic>> folders,
    List<Map<String, dynamic>> videos,
    _FolderImportContext context,
  ) {
    final folderIds = <String>{};
    final allIds = <String>{};
    for (final folder in folders) {
      final id = folder['exportId'];
      if (id is! String || id.isEmpty || !allIds.add(id)) {
        throw const FormatException('文件夹标识损坏');
      }
      folderIds.add(id);
    }
    if (!folderIds.contains(context.sourceCollectionId)) {
      throw const FormatException('接收的文件夹与发送请求不符');
    }
    final parents = <String, String?>{};
    for (final folder in folders) {
      final id = folder['exportId'] as String;
      final parent = folder['parentExportId'];
      if (id == context.sourceCollectionId) {
        if (parent != null && parent != '') {
          throw const FormatException('来源文件夹层级损坏');
        }
        parents[id] = null;
      } else {
        if (parent is! String || !folderIds.contains(parent)) {
          throw const FormatException('来源文件夹层级损坏');
        }
        parents[id] = parent;
      }
    }
    for (final id in folderIds) {
      final visited = <String>{};
      String? current = id;
      while (current != null) {
        if (!visited.add(current)) throw const FormatException('文件夹存在循环引用');
        current = parents[current];
      }
    }
    for (final record in videos) {
      final id = record['exportId'];
      final video = record['video'];
      if (id is! String ||
          id.isEmpty ||
          !allIds.add(id) ||
          video is! Map ||
          !folderIds.contains(record['parentExportId'])) {
        throw const FormatException('媒体卡片或所属文件夹损坏');
      }
      if (record['isOnline'] != true) {
        final ref = video['path'];
        if (record['reuseContent'] == true) {
          final key = record['contentKey'];
          if (key is! String || !_isContentKey(key) || ref != '@content:$key') {
            throw const FormatException('媒体复用标识损坏');
          }
          continue;
        }
        final hash = ref is String && ref.startsWith('@asset:')
            ? context.checksums[ref.substring(7)]
            : null;
        if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
          throw const FormatException('媒体文件缺少完整性校验');
        }
      }
    }
  }

  String _receivedMediaIdentity(
    Map<String, dynamic> video,
    Map<String, dynamic> record,
    _FolderImportContext context,
  ) {
    final parent = context.idMap[record['parentExportId']] ?? context.rootId;
    return '$parent|${context.incomingContentKeys[record['exportId']]}';
  }

  Future<VideoItem?> _findReceivedMedia(
    LibraryService library,
    Directory extraction,
    Map<String, dynamic> video,
    Map<String, dynamic> record,
    _FolderImportContext context,
    PortableTransferTask task,
  ) async {
    String wanted;
    if (record['isOnline'] == true) {
      final source = MediaSourceRef.fromJsonOrNull(video['sourceRef']);
      if (source?.podcast != null) {
        wanted = 'podcast:${source!.podcast!.episodeId}';
      } else if (source?.kind == MediaSourceKind.cloudDrive &&
          source?.cloudDrive != null) {
        wanted = 'cloud:${source!.cloudDrive!.sourceKey}';
      } else if (source?.kind != MediaSourceKind.bilibiliStream ||
          source?.bvid?.isNotEmpty != true ||
          source?.cid == null) {
        throw const FormatException('在线卡片缺少播放来源');
      } else {
        wanted = 'bilibili:${source!.bvid}:${source.cid}';
      }
    } else if (record['reuseContent'] == true) {
      wanted = record['contentKey'] as String;
    } else {
      final primary = _resolveAssetReference(
        extraction,
        (record['video'] as Map)['path'],
      );
      if (primary == null || !await primary.exists()) {
        throw const FormatException('媒体资源缺失');
      }
      final ref = ((record['video'] as Map)['path'] as String).substring(7);
      wanted = 'sha256:${await primary.length()}:${context.checksums[ref]}';
      if (record['contentKey'] != null && record['contentKey'] != wanted) {
        throw const FormatException('媒体内容标识与校验不符');
      }
    }
    context.incomingContentKeys[record['exportId'] as String] = wanted;
    if (!context.indexed) {
      final existing = library.mediaInFolderTree(context.rootId!);
      for (var i = 0; i < existing.length; i++) {
        if (task.cancelRequested) throw const _TransferCancelled();
        final item = existing[i];
        if (item.isRecycled || item.isTransient) continue;
        final source = item.sourceRef;
        final origin = await classifySyncMediaOrigin(
          path: item.path,
          playbackPath: item.playbackPath ?? item.bilibiliDownloadPath,
          sourceKind: source?.kind,
        );
        String? identity;
        if (origin.placement == SyncMediaPlacement.localFile) {
          final file = File(origin.localPath!);
          if (await file.exists()) {
            task.subtitle = '正在识别已有文件 ${i + 1}/${existing.length}';
            task.progress = (i + 1) / existing.length;
            notifyListeners();
            // Full content digests prevent equal names or sampled fingerprints
            // from causing a different file to be skipped.
            final before = await file.stat();
            final cached = context.existingFingerprints[item.id];
            final digest =
                cached != null &&
                    cached.path == file.path &&
                    cached.size == before.size &&
                    cached.modifiedMs == before.modified.millisecondsSinceEpoch
                ? cached.sha256
                : await _hashFolderMedia(file, task);
            final after = await file.stat();
            if (before.size != after.size ||
                before.modified != after.modified) {
              throw const FormatException('识别期间文件发生变化，请重试');
            }
            identity = 'sha256:${after.size}:$digest';
            context.fingerprints[item.id] = PortableFolderFingerprint(
              path: file.path,
              size: after.size,
              modifiedMs: after.modified.millisecondsSinceEpoch,
              sha256: digest,
            );
          }
        } else if (origin.placement == SyncMediaPlacement.onlineReference &&
            source?.podcast != null) {
          identity = 'podcast:${source!.podcast!.episodeId}';
        } else if (origin.placement == SyncMediaPlacement.onlineReference &&
            source?.kind == MediaSourceKind.bilibiliStream &&
            source?.bvid?.isNotEmpty == true &&
            source?.cid != null) {
          identity = 'bilibili:${source!.bvid}:${source.cid}';
        } else if (origin.placement == SyncMediaPlacement.onlineReference &&
            source?.kind == MediaSourceKind.cloudDrive &&
            source?.cloudDrive != null) {
          identity = 'cloud:${source!.cloudDrive!.sourceKey}';
        }
        if (identity != null) {
          context.mediaByIdentity['${item.parentId}|$identity'] = item;
          context.mediaByContent.putIfAbsent(identity, () => item);
          context.contentByLocalId[item.id] = identity;
        }
      }
      context.indexed = true;
    }
    return context.mediaByIdentity[_receivedMediaIdentity(
      video,
      record,
      context,
    )];
  }

  bool _isContentKey(String key) =>
      RegExp(r'^sha256:[0-9]{1,16}:[0-9a-f]{64}$').hasMatch(key);

  bool _isInReceivedTree(LibraryService library, String id, String rootId) {
    final visited = <String>{};
    String? current = id;
    while (current != null && visited.add(current)) {
      if (current == rootId) return true;
      current =
          library.getCollection(current)?.parentId ??
          library.getVideo(current)?.parentId;
    }
    return false;
  }

  bool _receivedAssetReferenced(LibraryService library, String path) {
    bool contains(Object? value) {
      if (value is String) {
        return p.equals(p.normalize(value), p.normalize(path));
      }
      if (value is Map) return value.values.any(contains);
      if (value is List) return value.any(contains);
      return false;
    }

    return library.storageVideos.any((item) => contains(item.toJson())) ||
        library.storageCollections.any((item) => item.thumbnailPath == path);
  }

  Future<String> _hashFolderMedia(File file, PortableTransferTask task) async {
    final result = <Digest>[];
    final sink = sha256.startChunkedConversion(_FolderDigestSink(result));
    await for (final chunk in file.openRead()) {
      if (task.cancelRequested) throw const _TransferCancelled();
      sink.add(chunk);
    }
    sink.close();
    return result.single.toString();
  }

  File? _resolveAssetReference(Directory extraction, Object? reference) {
    final value = reference?.toString() ?? '';
    if (!value.startsWith('@asset:')) return null;
    final relative = value.substring('@asset:'.length).replaceAll('\\', '/');
    final candidate = File(
      p.normalize(p.join(extraction.path, p.joinAll(relative.split('/')))),
    );
    if (!p.isWithin(extraction.path, candidate.path)) {
      throw const FormatException('资产路径越界');
    }
    return candidate;
  }

  Future<String?> _copyAssetToManagedStorage({
    required Directory extraction,
    required Object? reference,
    required Directory destinationDirectory,
    required String destinationStem,
  }) async {
    final source = _resolveAssetReference(extraction, reference);
    if (source == null || !await source.exists()) return null;
    await destinationDirectory.create(recursive: true);
    final extension = p.extension(source.path);
    final destination = File(
      p.join(destinationDirectory.path, '$destinationStem$extension'),
    );
    final partial = File('${destination.path}.partial');
    try {
      if (await partial.exists()) await partial.delete();
      await source.copy(partial.path);
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      return destination.path;
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<Directory> _locateContentRoot(Directory extraction) async {
    final children = await extraction.list(followLinks: false).toList();
    final dirs = children.whereType<Directory>().toList();
    final mediaAtRoot = children.whereType<File>().any(
      (file) => LibraryService.isSupportedMediaPath(file.path),
    );
    if (!mediaAtRoot && dirs.length == 1) return dirs.single;
    return extraction;
  }

  static String _safeName(String input) {
    final cleaned = input
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return cleaned.isEmpty ? '未命名' : cleaned;
  }

  static String _safeRelativePath(String value) => value
      .split(RegExp(r'[/\\]+'))
      .where((segment) => segment.isNotEmpty && segment != '..')
      .map(_safeName)
      .join('/');

  static String _uniqueArchivePath(String wanted, Set<String> used) {
    var candidate = wanted;
    var index = 2;
    while (!used.add(candidate.toLowerCase())) {
      final ext = p.posix.extension(wanted);
      final stem = wanted.substring(0, wanted.length - ext.length);
      candidate = '$stem ($index)$ext';
      index++;
    }
    return candidate;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }
}

class _FolderImportContext {
  final String sourceCollectionId;
  final Map<String, String> idMap;
  final Map<String, _FolderStagedMedia> stagedMedia;
  final String? requestedTargetId;
  final Map<String, dynamic> checksums;
  final Map<String, PortableFolderFingerprint> existingFingerprints;
  final Future<void> Function(int bytes)? beforeExtraLocalCopy;
  final Future<void> Function() persistMapping;
  final bool Function()? isCancelled;
  final Map<String, String> stableIds;
  final Map<String, String> existingLocalIds;
  final Set<String> suppressedNodeIds;
  final Set<String> protectedNodeIds;
  final Set<String> blockedSourceIds = {};
  final bool reconcileStructure;
  final Map<String, VideoItem> mediaByIdentity = {};
  final Map<String, VideoItem> mediaByContent = {};
  final Map<String, String> contentByLocalId = {};
  final Map<String, String> incomingContentKeys = {};
  final List<_SyncMetadataChange> metadataChanges = [];
  final List<({String exportId, String existingId, String importedId})>
  revisions = [];
  final Map<String, PortableFolderFingerprint> fingerprints = {};
  String? rootId;
  bool indexed = false;
  int imported = 0;
  int skipped = 0;

  _FolderImportContext({
    required this.sourceCollectionId,
    required this.idMap,
    required this.stagedMedia,
    required this.requestedTargetId,
    required this.checksums,
    this.existingFingerprints = const {},
    this.beforeExtraLocalCopy,
    required this.persistMapping,
    this.isCancelled,
    this.stableIds = const {},
    this.existingLocalIds = const {},
    this.suppressedNodeIds = const {},
    this.protectedNodeIds = const {},
    this.reconcileStructure = false,
  });
}

class _FolderStagedMedia {
  const _FolderStagedMedia({required this.existingId, required this.stagedId});
  final String existingId, stagedId;
}

class _SyncMetadataChange {
  final String id, name;
  final String? parentId;
  final bool preserveRootParent;
  _SyncMetadataChange(
    this.id,
    this.name,
    this.parentId, {
    this.preserveRootParent = false,
  });
}

class _FolderDigestSink implements Sink<Digest> {
  final List<Digest> values;
  _FolderDigestSink(this.values);
  @override
  void add(Digest data) => values.add(data);
  @override
  void close() {}
}

class _PackageFile {
  final File file;
  final String archivePath;
  final int size;
  const _PackageFile(this.file, this.archivePath, this.size);
}

class _ExportPlan {
  final List<_PackageFile> files;
  final Map<String, dynamic> manifest;
  final String manifestPath;
  final int mediaCount;
  final int totalBytes;
  const _ExportPlan({
    required this.files,
    required this.manifest,
    required this.manifestPath,
    required this.mediaCount,
    required this.totalBytes,
  });
}

class _TransferCancelled implements Exception {
  const _TransferCancelled();
}

class _PortableWorkerControl {
  final Isolate isolate;
  final Completer<Map<String, dynamic>> completer;

  final File? marker;
  final Completer<void> exitSignal;
  bool _cancelled = false;
  bool get cooperative => marker != null;
  bool get hasExited => exitSignal.isCompleted;
  Future<void> get exited => exitSignal.future;

  _PortableWorkerControl(
    this.isolate,
    this.completer, {
    this.marker,
    required this.exitSignal,
  });

  Future<bool> waitForExit() async {
    try {
      await exited.timeout(const Duration(seconds: 5));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final signal = marker;
    if (signal != null) {
      try {
        signal.writeAsStringSync('cancel', flush: true);
      } catch (_) {}
    } else {
      isolate.kill(priority: Isolate.immediate);
    }
    if (!completer.isCompleted) {
      completer.completeError(const _TransferCancelled());
    }
  }
}

class _PortableRetrySpec {
  final PortableTransferKind kind;
  final List<String>? rootIds;
  final String? outputPath;
  final PortableExportOptions? options;
  final String? packagePath;
  final PortablePackagePreview? preview;
  final bool deletePackageWhenDone;
  final String? libraryFolderId;
  final ImportPlacementRequest? importPlacement;
  final bool isArchive;
  final String? importDisplayName;
  final String? archiveSortField;
  final String? archiveSortDirection;
  final Set<String> createdAssetPaths;
  String? transactionRootId;

  _PortableRetrySpec._({
    required this.kind,
    this.rootIds,
    this.outputPath,
    this.options,
    this.packagePath,
    this.preview,
    this.deletePackageWhenDone = false,
    this.libraryFolderId,
    this.importPlacement,
    this.isArchive = false,
    this.importDisplayName,
    this.archiveSortField,
    this.archiveSortDirection,
    Set<String>? createdAssetPaths,
    this.transactionRootId,
  }) : createdAssetPaths = createdAssetPaths ?? <String>{};

  factory _PortableRetrySpec.export({
    required List<String> rootIds,
    required String outputPath,
    required PortableExportOptions options,
  }) => _PortableRetrySpec._(
    kind: PortableTransferKind.export,
    rootIds: List<String>.unmodifiable(rootIds),
    outputPath: outputPath,
    options: options,
  );

  factory _PortableRetrySpec.import({
    required String packagePath,
    required PortablePackagePreview preview,
    required bool deletePackageWhenDone,
    String? libraryFolderId,
    ImportPlacementRequest? importPlacement,
  }) => _PortableRetrySpec._(
    kind: PortableTransferKind.import,
    packagePath: packagePath,
    preview: preview,
    deletePackageWhenDone: deletePackageWhenDone,
    libraryFolderId: libraryFolderId,
    importPlacement: importPlacement,
  );

  factory _PortableRetrySpec.archive({
    required String archivePath,
    required String displayName,
    required StructuredImportSortOptions sortOptions,
    required bool deleteArchiveWhenDone,
    String? libraryFolderId,
    ImportPlacementRequest? importPlacement,
  }) => _PortableRetrySpec._(
    kind: PortableTransferKind.import,
    packagePath: archivePath,
    importDisplayName: displayName,
    isArchive: true,
    archiveSortField: sortOptions.fieldStorageValue,
    archiveSortDirection: sortOptions.directionStorageValue,
    deletePackageWhenDone: deleteArchiveWhenDone,
    libraryFolderId: libraryFolderId,
    importPlacement: importPlacement,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'rootIds': rootIds,
    'outputPath': outputPath,
    'options': options?.toJson(),
    'packagePath': packagePath,
    'preview': preview?.toJson(),
    'deletePackageWhenDone': deletePackageWhenDone,
    'libraryFolderId': libraryFolderId,
    'importPlacement': importPlacement?.toJson(),
    'isArchive': isArchive,
    'importDisplayName': importDisplayName,
    'archiveSortField': archiveSortField,
    'archiveSortDirection': archiveSortDirection,
    'createdAssetPaths': createdAssetPaths.toList(growable: false),
    'transactionRootId': transactionRootId,
  };

  factory _PortableRetrySpec.fromJson(Map<String, dynamic> json) {
    final kind = PortableTransferKind.values.firstWhere(
      (value) => value.name == json['kind'],
      orElse: () => PortableTransferKind.export,
    );
    final rawOptions = json['options'];
    final rawPreview = json['preview'];
    return _PortableRetrySpec._(
      kind: kind,
      rootIds: (json['rootIds'] as List?)
          ?.map((value) => value.toString())
          .toList(growable: false),
      outputPath: json['outputPath']?.toString(),
      options: rawOptions is Map
          ? PortableExportOptions.fromJson(
              Map<String, dynamic>.from(rawOptions),
            )
          : null,
      packagePath: json['packagePath']?.toString(),
      preview: rawPreview is Map
          ? PortablePackagePreview.fromJson(
              Map<String, dynamic>.from(rawPreview),
            )
          : null,
      deletePackageWhenDone: json['deletePackageWhenDone'] == true,
      libraryFolderId: json['libraryFolderId']?.toString(),
      importPlacement: ImportPlacementRequest.fromJson(json['importPlacement']),
      isArchive: json['isArchive'] == true,
      importDisplayName: json['importDisplayName']?.toString(),
      archiveSortField: json['archiveSortField']?.toString(),
      archiveSortDirection: json['archiveSortDirection']?.toString(),
      createdAssetPaths: (json['createdAssetPaths'] as List?)
          ?.map((value) => value.toString())
          .toSet(),
      transactionRootId: json['transactionRootId']?.toString(),
    );
  }
}

Future<Map<String, dynamic>?> _inspectArchiveReferencesInBackground(
  String path,
) => Isolate.run(() => _inspectArchiveReferences(path));

Map<String, dynamic>? _inspectArchiveReferences(String archivePath) {
  if (p.extension(archivePath).toLowerCase() != '.zip') return null;
  final input = InputFileStream(archivePath);
  Archive? archive;
  try {
    archive = ZipDecoder().decodeStream(input);
    final references = archive.files
        .where(
          (entry) =>
              entry.isFile &&
              p.posix.basename(entry.name) == 'fluent-podcast-references.json',
        )
        .toList();
    for (final entry in archive.files.where(
      (entry) =>
          entry.isFile && p.posix.basename(entry.name) == 'manifest.json',
    )) {
      if (entry.size > _maxPortableManifestBytes) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(entry.content));
      } on FormatException {
        continue;
      }
      if (decoded is Map &&
          decoded['format'] == 'fluent-player-portable-package') {
        _validatePortableManifest(
          Map<String, dynamic>.from(decoded),
          PortableTransferService.formatVersion,
        );
        return {'portablePackage': true};
      }
    }
    if (references.isEmpty) return null;
    if (references.length != 1 ||
        references.single.size > _maxPortableManifestBytes) {
      throw const FormatException('播客卡片清单过大或存在重复清单');
    }
    final decoded = jsonDecode(utf8.decode(references.single.content));
    if (decoded is! Map ||
        decoded['format'] != 'fluent-podcast-references' ||
        decoded['formatVersion'] != 1 ||
        decoded['snapshot'] is! Map) {
      throw const FormatException('播客卡片清单格式不受支持');
    }
    final raw = decoded['snapshot'] as Map;
    bool validLink(String value) {
      final uri = Uri.tryParse(value);
      return uri != null &&
          const {'http', 'https'}.contains(uri.scheme) &&
          uri.host.isNotEmpty &&
          !value.contains(RegExp(r'[\r\n]'));
    }

    bool validIdentity(String value) =>
        RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(value);
    final identities = <String>{};
    String recordId(Map record) {
      final value = record['exportId'];
      if (value is! String || !validIdentity(value) || !identities.add(value)) {
        throw const FormatException('播客卡片身份缺失或重复');
      }
      final parent = record['parentExportId'];
      if (parent != null && (parent is! String || !validIdentity(parent))) {
        throw const FormatException('播客卡片上级文件夹无效');
      }
      return value;
    }

    final channels = <String, PodcastChannel>{};
    final episodes = <String, List<PodcastEpisode>>{};
    final episodeSources = <String, (String, String)>{};
    void rememberChannel(String id, String feed, String title) {
      if (!validIdentity(id) || !validLink(feed)) {
        throw const FormatException('播客频道缺少有效订阅地址');
      }
      final existing = channels[id];
      if (existing != null && existing.feedUrl != feed) {
        throw const FormatException('播客频道身份与订阅地址冲突');
      }
      channels[id] ??= PodcastChannel(id: id, feedUrl: feed, title: title);
    }

    final collections = <Map<String, dynamic>>[];
    for (final record in (raw['collections'] as List? ?? []).whereType<Map>()) {
      final id = recordId(record);
      final ref = PodcastChannelRef.fromJsonOrNull(record['podcastRef']);
      if (record['podcastRef'] != null && ref == null) {
        throw const FormatException('播客频道卡片损坏');
      }
      if (ref != null) {
        rememberChannel(
          ref.channelId,
          ref.feedUrl,
          record['name']?.toString() ?? '播客',
        );
      }
      final directory = record['archiveDirectory'];
      String? archiveName;
      if (directory != null) {
        if (directory is! String ||
            p.posix.isAbsolute(directory) ||
            p.windows.isAbsolute(directory) ||
            directory
                .replaceAll('\\', '/')
                .split('/')
                .any((part) => part == '..')) {
          throw const FormatException('播客卡片文件夹路径无效');
        }
        archiveName = p.posix.basename(directory.replaceAll('\\', '/'));
      }
      collections.add({
        'exportId': id,
        'parentExportId': record['parentExportId'],
        'name': record['name']?.toString() ?? '播客',
        'archiveName': ?archiveName,
        if (ref != null) 'podcastRef': ref.toJson(),
      });
    }
    final videos = <Map<String, dynamic>>[];
    for (final record in (raw['videos'] as List? ?? []).whereType<Map>()) {
      final id = recordId(record);
      final video = record['video'];
      if (video is! Map) throw const FormatException('播客节目卡片损坏');
      final source = MediaSourceRef.fromJsonOrNull(video['sourceRef']);
      final ref = source?.podcast;
      if (source?.kind != MediaSourceKind.podcastEpisode ||
          ref == null ||
          !validIdentity(ref.episodeId) ||
          !validLink(ref.mediaUrl)) {
        throw const FormatException('播客节目缺少有效播放链接');
      }
      rememberChannel(ref.channelId, ref.feedUrl, '播客');
      final identity = (ref.channelId, ref.mediaUrl);
      final known = episodeSources[ref.episodeId];
      if (known != null && known != identity) {
        throw const FormatException('播客节目身份与频道或播放地址冲突');
      }
      episodeSources[ref.episodeId] = identity;
      final canonical = MediaSourceRef(
        value: ref.mediaUrl,
        kind: MediaSourceKind.podcastEpisode,
        podcast: ref,
      );
      final duration = (video['durationMs'] as num?)?.toInt() ?? 0;
      final title = video['title']?.toString() ?? '播客节目';
      final isVideo = video['type'] == 'video';
      // These are links, not backup instructions: no local file, cache,
      // settings, playback state or unrelated channel payload may be imported.
      final item = VideoItem(
        id: id,
        path: 'podcast:${ref.episodeId}',
        title: title,
        sourceRef: canonical,
        durationMs: duration,
        type: isVideo ? MediaType.video : MediaType.audio,
        lastUpdated: 0,
        hasProbedChapters: true,
      );
      videos.add({
        'exportId': id,
        'parentExportId': record['parentExportId'],
        'isOnline': true,
        'video': item.toJson(),
      });
      (episodes[ref.channelId] ??= []).add(
        PodcastEpisode(
          id: ref.episodeId,
          channelId: ref.channelId,
          title: title,
          durationMs: duration,
          media: [
            PodcastMedia(
              url: ref.mediaUrl,
              mimeType: isVideo ? 'video/mp4' : 'audio/mpeg',
            ),
          ],
        ),
      );
    }
    final collectionIds = collections
        .map((row) => row['exportId'] as String)
        .toSet();
    final parents = <String, String?>{
      for (final row in [...collections, ...videos])
        row['exportId'] as String: row['parentExportId'] as String?,
    };
    for (final id in parents.keys) {
      final seen = <String>{id};
      var parent = parents[id];
      while (parent != null) {
        if (!collectionIds.contains(parent) || !seen.add(parent)) {
          throw const FormatException('播客卡片文件夹缺失或存在循环引用');
        }
        parent = parents[parent];
      }
    }
    // Channel names and artwork can improve a link card. Everything else in
    // the raw bundle (settings, states, downloads, descriptions) is ignored.
    for (final bundle in (raw['podcasts'] as List? ?? []).whereType<Map>()) {
      final channel = bundle['channel'];
      if (channel is! Map) continue;
      final selected = channels[channel['id']];
      if (selected == null || selected.feedUrl != channel['feedUrl']) continue;
      if (channel['title'] is String) selected.title = channel['title'];
      if (channel['author'] is String) selected.author = channel['author'];
      if (channel['imageUrl'] is String && validLink(channel['imageUrl'])) {
        selected.imageUrl = channel['imageUrl'];
      }
      if (channel['link'] is String && validLink(channel['link'])) {
        selected.link = channel['link'];
      }
    }
    if (channels.isEmpty) throw const FormatException('播客卡片清单为空');
    return {
      'hasMedia': archive.files.any(
        (entry) =>
            entry.isFile && LibraryService.isSupportedMediaPath(entry.name),
      ),
      'referenceDirectory': p.posix.dirname(references.single.name),
      'snapshot': {
        'collections': collections,
        'videos': videos,
        'podcasts': [
          for (final channel in channels.values)
            {
              'channel': channel.toJson(),
              'episodes': (episodes[channel.id] ?? [])
                  .map((episode) => episode.toJson())
                  .toList(),
            },
        ],
      },
    };
  } finally {
    archive?.clear();
    input.closeSync();
  }
}

Future<Map<String, dynamic>> _inspectPortablePackageWorker(
  Map<String, dynamic> arguments,
) async {
  final packagePath = arguments['packagePath'] as String;
  final supportedVersion = arguments['supportedVersion'] as int;
  final input = InputFileStream(packagePath);
  Archive? archive;
  try {
    archive = ZipDecoder().decodeStream(input, verify: true);
    final manifests = archive.files.where(
      (entry) => p.posix.basename(entry.name) == 'manifest.json',
    );
    if (manifests.isEmpty) {
      throw const FormatException('这不是 Fluent Player 导出包：缺少清单');
    }
    if (manifests.first.size > _maxPortableManifestBytes) {
      throw const FormatException('导出包清单过大');
    }
    final decoded = jsonDecode(utf8.decode(manifests.first.content));
    if (decoded is! Map) throw const FormatException('导出包清单损坏');
    final manifest = Map<String, dynamic>.from(decoded);
    _validatePortableManifest(manifest, supportedVersion);
    final version = manifest['formatVersion'] as int? ?? 0;
    return <String, dynamic>{
      'packageName':
          manifest['packageName']?.toString() ??
          p.basenameWithoutExtension(packagePath),
      'createdAt':
          (DateTime.tryParse(manifest['createdAt']?.toString() ?? '') ??
                  DateTime.now())
              .toIso8601String(),
      'mediaCount': manifest['mediaCount'] as int? ?? 0,
      'folderCount': manifest['folderCount'] as int? ?? 0,
      'fileCount': manifest['fileCount'] as int? ?? 0,
      'totalBytes': manifest['totalBytes'] as int? ?? 0,
      'hasChecksums': (manifest['checksums'] as Map?)?.isNotEmpty == true,
      'formatVersion': version,
    };
  } finally {
    archive?.clear();
    await input.close();
  }
}

Future<String> _hashPortableFile(
  File file,
  void Function(int bytes) onProgress,
) async {
  final result = <Digest>[];
  final sink = sha256.startChunkedConversion(_FolderDigestSink(result));
  final timer = Stopwatch()..start();
  var last = 0;
  var bytes = 0;
  await for (final chunk in file.openRead()) {
    sink.add(chunk);
    bytes += chunk.length;
    if (timer.elapsedMilliseconds - last >= 200) {
      last = timer.elapsedMilliseconds;
      onProgress(bytes);
    }
  }
  sink.close();
  onProgress(bytes);
  return result.single.toString();
}

Future<void> _portableExportWorker(Map<String, dynamic> arguments) async {
  final sendPort = arguments['sendPort'] as SendPort;
  ZipFileEncoder? encoder;
  PortableArchiveFileHandle? outputHandle;
  final cancelPath = arguments['cancelPath'] as String?;
  final marker = cancelPath == null ? null : File(cancelPath);
  void checkCancelled() {
    if (marker?.existsSync() == true) throw const _TransferCancelled();
  }

  try {
    checkCancelled();
    final files = (arguments['files'] as List)
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList(growable: false);
    final totalBytes = arguments['totalBytes'] as int? ?? 0;
    final verifyChecksums = arguments['verifyChecksums'] == true;
    final network = arguments['networkTransfer'] == true;
    final known = arguments['knownFingerprints'] as Map? ?? {};
    final manifest = Map<String, dynamic>.from(arguments['manifest'] as Map);
    final checksums = <String, String>{};
    final sourceStats = <String, Map<String, dynamic>>{};
    var processed = 0;
    if (verifyChecksums) {
      for (var index = 0; index < files.length; index++) {
        checkCancelled();
        final record = files[index];
        final source = File(record['sourcePath'] as String);
        if (!await source.exists()) {
          throw StateError('导出源文件已不存在：${source.path}');
        }
        final before = await source.stat();
        final cached = known[record['archivePath']];
        final validCached =
            network &&
            cached is Map &&
            cached['path'] == source.path &&
            cached['size'] == before.size &&
            cached['modified'] == before.modified.millisecondsSinceEpoch &&
            cached['sha256'] is String &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(cached['sha256'] as String);
        checksums[record['archivePath'] as String] = validCached
            ? cached['sha256'] as String
            : network
            ? await _hashPortableFile(source, (bytes) {
                checkCancelled();
                sendPort.send({
                  'type': 'progress',
                  'networkProgress': totalBytes == 0
                      ? (index + 1) / files.length
                      : (processed + bytes) / totalBytes,
                  'subtitle': '正在校验 ${index + 1}/${files.length}',
                });
              })
            : (await sha256
                      .bind(
                        source.openRead().map((bytes) {
                          checkCancelled();
                          return bytes;
                        }),
                      )
                      .first)
                  .toString();
        checkCancelled();
        final after = await source.stat();
        if (before.size != after.size ||
            before.modified != after.modified ||
            before.size != record['size']) {
          throw const FormatException('准备期间文件发生变化，请重试');
        }
        sourceStats[record['archivePath'] as String] = {
          'path': source.path,
          'size': after.size,
          'modified': after.modified.millisecondsSinceEpoch,
        };
        processed += record['size'] as int? ?? 0;
        if (index == 0 || (index + 1) % 16 == 0 || index + 1 == files.length) {
          sendPort.send(<String, dynamic>{
            'type': 'progress',
            'progress': totalBytes == 0 ? 0.2 : processed / totalBytes * 0.2,
            'networkProgress': totalBytes == 0 ? 1 : processed / totalBytes,
            'processedBytes': processed,
            'subtitle': '正在校验 ${index + 1}/${files.length}',
          });
        }
      }
    }
    manifest['checksums'] = checksums;
    if (network && manifest['snapshot'] is Map) {
      final snapshot = manifest['snapshot'] as Map;
      for (final raw in snapshot['videos'] as List? ?? []) {
        if (raw is! Map ||
            raw['isOnline'] == true ||
            raw['reuseContent'] == true) {
          continue;
        }
        final video = raw['video'];
        final path = video is Map ? video['path'] : null;
        if (path is String && path.startsWith('@asset:')) {
          final ref = path.substring(7);
          raw['contentKey'] =
              'sha256:${sourceStats[ref]?['size']}:${checksums[ref]}';
        }
      }
    }

    final partialPath = arguments['partialPath'] as String;
    final level = arguments['level'] as int;
    checkCancelled();
    if (marker != null) {
      outputHandle = PortableArchiveFileHandle(
        partialPath,
        marker,
        mode: FileAccess.write,
      );
      encoder = ZipFileEncoder()
        ..createWithStream(
          OutputFileStream.withFileHandle(outputHandle),
          level: level,
        );
    } else {
      encoder = ZipFileEncoder()..create(partialPath, level: level);
    }
    final encodedManifest = jsonEncode(manifest);
    if (utf8.encode(encodedManifest).length > _maxPortableManifestBytes) {
      throw const FormatException('导出包清单过大');
    }
    encoder.addArchiveFile(
      ArchiveFile.string(arguments['manifestPath'] as String, encodedManifest),
    );
    processed = 0;
    for (var index = 0; index < files.length; index++) {
      checkCancelled();
      final record = files[index];
      final source = File(record['sourcePath'] as String);
      if (!await source.exists()) {
        throw StateError('导出源文件已不存在：${source.path}');
      }
      final beforeWrite = await source.stat();
      final checked = sourceStats[record['archivePath']];
      if (beforeWrite.size != record['size'] ||
          checked != null &&
              (beforeWrite.size != checked['size'] ||
                  beforeWrite.modified.millisecondsSinceEpoch !=
                      checked['modified'])) {
        throw const FormatException('打包前文件发生变化，请重试');
      }
      checkCancelled();
      if (marker != null) {
        final inputHandle = PortableArchiveFileHandle(source.path, marker);
        try {
          final entry = ArchiveFile.stream(
            record['archivePath'] as String,
            InputFileStream.withFileHandle(inputHandle),
          );
          if (network) {
            entry.compression = CompressionType.none;
          } else {
            entry.mode = beforeWrite.mode;
            entry.lastModTime =
                beforeWrite.modified.millisecondsSinceEpoch ~/ 1000;
          }
          encoder.addArchiveFile(entry);
        } finally {
          inputHandle.closeSync();
        }
      } else if (network) {
        // level=0 alone still selects DEFLATE in archive 4.x and buffers its
        // output. Explicit STORE keeps large videos streamed and uncompressed.
        final entry = ArchiveFile.stream(
          record['archivePath'] as String,
          InputFileStream(source.path),
        )..compression = CompressionType.none;
        encoder.addArchiveFile(entry);
      } else {
        await encoder.addFile(source, record['archivePath'] as String, level);
      }
      checkCancelled();
      final afterWrite = await source.stat();
      if (afterWrite.size != beforeWrite.size ||
          afterWrite.modified != beforeWrite.modified) {
        throw const FormatException('打包期间文件发生变化，请重试');
      }
      processed += record['size'] as int? ?? 0;
      final ratio = totalBytes == 0
          ? (index + 1) / files.length
          : processed / totalBytes;
      if (index == 0 || (index + 1) % 8 == 0 || index + 1 == files.length) {
        sendPort.send(<String, dynamic>{
          'type': 'progress',
          'progress':
              (verifyChecksums ? 0.2 : 0.02) +
              ratio * (verifyChecksums ? 0.78 : 0.96),
          'processedBytes': processed,
          'networkProgress': (index + 1) / files.length,
          'subtitle': '正在打包 ${index + 1}/${files.length}',
        });
      }
    }
    checkCancelled();
    await encoder.close();
    encoder = null;
    sendPort.send(<String, dynamic>{
      'type': 'done',
      'result': <String, dynamic>{'checksums': checksums, 'stats': sourceStats},
    });
  } catch (error) {
    try {
      await encoder?.close();
    } catch (_) {}
    sendPort.send(<String, dynamic>{
      'type': 'error',
      'message': error.toString(),
      'format': error is FormatException,
    });
  } finally {
    try {
      await encoder?.close();
    } catch (_) {}
    outputHandle?.closeSync();
  }
}

Future<void> _portableImportWorker(Map<String, dynamic> arguments) async {
  final sendPort = arguments['sendPort'] as SendPort;
  final packagePath = arguments['packagePath'] as String;
  final extractionPath = arguments['extractionPath'] as String;
  final supportedVersion = arguments['supportedVersion'] as int;
  final network = arguments['networkTransfer'] == true;
  final extractedHashes = <String, String>{};
  InputFileStream? input;
  Archive? archive;
  try {
    input = InputFileStream(packagePath);
    var entries = 0;
    archive = ZipDecoder().decodeStream(
      input,
      verify: true,
      callback: (_) {
        entries++;
        if (entries == 1 || entries % 16 == 0) {
          sendPort.send(<String, dynamic>{
            'type': 'progress',
            'progress': 0.02 + (entries / (entries + 200)) * 0.12,
            'subtitle': '正在读取 · $entries 个文件',
          });
        }
      },
    );
    if (archive.length > 20000) {
      throw const FormatException('导出包文件数量过多，已拒绝解包');
    }
    var declaredBytes = 0;
    for (final entry in archive) {
      if (entry.isSymbolicLink) {
        throw const FormatException('导出包不应包含符号链接');
      }
      if (p.posix.basename(entry.name.replaceAll('\\', '/')) ==
              'manifest.json' &&
          entry.size > _maxPortableManifestBytes) {
        throw const FormatException('导出包清单过大');
      }
      declaredBytes += entry.size;
      if (declaredBytes > 500 * 1024 * 1024 * 1024) {
        throw const FormatException('导出包解压后体积过大');
      }
      final relative = entry.name.replaceAll('\\', '/');
      final candidate = p.normalize(
        p.join(extractionPath, p.joinAll(relative.split('/'))),
      );
      if (p.equals(candidate, extractionPath) ||
          !p.isWithin(extractionPath, candidate)) {
        throw FormatException('导出包包含不安全路径：${entry.name}');
      }
    }
    sendPort.send(<String, dynamic>{
      'type': 'progress',
      'progress': 0.16,
      'subtitle': '正在解包，请稍候…',
    });
    if (network) {
      var processed = 0;
      var filesDone = 0;
      final filesTotal = archive.files.where((entry) => entry.isFile).length;
      final clock = Stopwatch()..start();
      var lastReport = 0;
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final relative = entry.name.replaceAll('\\', '/');
        final path = p.normalize(
          p.join(extractionPath, p.joinAll(relative.split('/'))),
        );
        await Directory(p.dirname(path)).create(recursive: true);
        final output = OutputFileStream(path);
        try {
          if (entry.compression == CompressionType.none) {
            final digests = <Digest>[];
            final hasher = sha256.startChunkedConversion(
              _FolderDigestSink(digests),
            );
            final stream = entry.rawContent!.getStream(decompress: false);
            stream.reset();
            var remaining = entry.size;
            while (remaining > 0) {
              final bytes = stream
                  .readBytes(remaining > 1024 * 1024 ? 1024 * 1024 : remaining)
                  .toUint8List();
              if (bytes.isEmpty) throw const FormatException('接收的文件被截断');
              output.writeBytes(bytes);
              hasher.add(bytes);
              remaining -= bytes.length;
              processed += bytes.length;
              if (clock.elapsedMilliseconds - lastReport >= 200) {
                lastReport = clock.elapsedMilliseconds;
                sendPort.send({
                  'type': 'progress',
                  'networkProgress': declaredBytes == 0
                      ? 0
                      : processed / declaredBytes,
                  'subtitle': '正在校验并解包 ${filesDone + 1}/$filesTotal',
                });
              }
            }
            hasher.close();
            extractedHashes[relative] = digests.single.toString();
          } else {
            entry.writeContent(output);
            processed += entry.size;
          }
        } finally {
          await output.close();
        }
        filesDone++;
        sendPort.send({
          'type': 'progress',
          'networkProgress': declaredBytes == 0 ? 1 : processed / declaredBytes,
          'subtitle': '正在校验并解包 $filesDone/$filesTotal',
        });
      }
    } else {
      await extractArchiveToDisk(archive, extractionPath);
    }
    archive.clear();
    archive = null;
    await input.close();
    input = null;

    final extraction = Directory(extractionPath);
    final manifests = extraction
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => p.basename(file.path) == 'manifest.json')
        .toList(growable: false);
    if (manifests.isEmpty) throw const FormatException('导出包缺少清单');
    final decoded = jsonDecode(await manifests.first.readAsString());
    if (decoded is! Map) throw const FormatException('导出包清单损坏');
    final manifest = Map<String, dynamic>.from(decoded);
    _validatePortableManifest(manifest, supportedVersion);

    final rawChecksums = manifest['checksums'];
    if (rawChecksums is Map && rawChecksums.isNotEmpty) {
      var checked = 0;
      for (final entry in rawChecksums.entries) {
        final relative = entry.key.toString().replaceAll('\\', '/');
        final candidate = File(
          p.normalize(p.join(extractionPath, p.joinAll(relative.split('/')))),
        );
        if (!p.isWithin(extractionPath, candidate.path) ||
            !await candidate.exists()) {
          throw FormatException('导出包缺少文件：$relative');
        }
        final digest =
            extractedHashes[relative] ??
            (network
                ? await _hashPortableFile(candidate, (bytes) {
                    sendPort.send({
                      'type': 'progress',
                      'networkProgress': candidate.lengthSync() == 0
                          ? 1
                          : bytes / candidate.lengthSync(),
                      'subtitle': '正在校验 ${checked + 1}/${rawChecksums.length}',
                    });
                  })
                : (await sha256.bind(candidate.openRead()).first).toString());
        if (digest != entry.value.toString()) {
          throw FormatException('文件校验失败：$relative');
        }
        checked++;
        if (checked == 1 ||
            checked % 16 == 0 ||
            checked == rawChecksums.length) {
          sendPort.send(<String, dynamic>{
            'type': 'progress',
            'progress': 0.22 + checked / rawChecksums.length * 0.18,
            'networkProgress': checked / rawChecksums.length,
            'subtitle': '正在校验 $checked/${rawChecksums.length}',
          });
        }
      }
    }
    sendPort.send(<String, dynamic>{'type': 'done', 'result': manifest});
  } catch (error) {
    sendPort.send(<String, dynamic>{
      'type': 'error',
      'message': error.toString(),
      'format': error is FormatException,
    });
  } finally {
    archive?.clear();
    if (input != null) {
      try {
        await input.close();
      } catch (_) {}
    }
  }
}

void _validatePortableManifest(
  Map<String, dynamic> manifest,
  int supportedVersion,
) {
  if (manifest['format'] != 'fluent-player-portable-package') {
    throw const FormatException('无法识别的导出包格式');
  }
  final version = manifest['formatVersion'] as int? ?? 0;
  if (version > supportedVersion) {
    throw FormatException('该文件来自更新版本（格式版本 $version）');
  }
}
