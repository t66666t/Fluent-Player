import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../models/video_item.dart';
import '../../models/media_source_ref.dart';
import '../../services/library_service.dart';
import '../../services/community_media_input.dart';
import '../portable_transfer/legacy_download_export_policy.dart';
import '../media_cache/media_cache_service.dart';
import '../media_cache/media_cache_models.dart';
import 'folder_sync_models.dart';
import 'folder_sync_state.dart';

/// Local paths stay here. The causal catalogue contains logical identities only.
/// Missing files are availability failures, never evidence of a remote deletion.
class FolderSyncCoordinator {
  FolderSyncCoordinator({
    required this.library,
    required this.deviceId,
    required this.deviceName,
    required this.contentKey,
    this.rootImportBlocked,
  });
  final LibraryService library;
  final String deviceId, deviceName;
  final Future<String?> Function(VideoItem item) contentKey;

  /// Blocks capture/apply for one root that is mid-import. Other folders keep
  /// syncing; a process-wide temporary-directory set is too coarse.
  final bool Function(String rootId)? rootImportBlocked;
  final Map<String, FolderSyncState> _states = {};
  final Map<String, Set<String>> _missing = {};
  final Map<String, Set<String>> _unavailable = {}, _deleteBlocks = {};
  final Map<String, DateTime> _relocatedAt = {};
  final Set<String> _applying = {};

  Future<File?> _cloudFile(VideoItem item) async {
    if (!isCloudDriveMedia(source: item.sourceRef, path: item.path)) {
      return null;
    }
    final cache = MediaCacheService.instance;
    if (cache != null) await cache.initialize();
    if (!item.path.contains('://')) {
      final local = File(item.path);
      try {
        final stat = await local.stat();
        if (stat.type == FileSystemEntityType.file && stat.size > 0) {
          if (cache == null) return local;
          final source = CacheSource.fromItem(item);
          if (source == null || source.ref.cloudDrive == null) return null;
          final registered = cache.variants.where(
            (variant) =>
                variant.source.key == source.key &&
                p.equals(p.normalize(variant.path), p.normalize(local.path)),
          );
          if (registered.isEmpty) {
            // Repair previously received local cloud originals. Only the
            // card's explicit complete file qualifies, never playbackPath or
            // an isolated/incomplete rendition already in the cache catalog.
            await cache.registerLegacy(
              CacheVariant(
                source: source,
                quality: CacheQuality(
                  id: 'original',
                  label: '原文件',
                  revision: item.sourceRef!.cloudDrive!.revision ?? '',
                ),
                path: local.path,
                bytes: stat.size,
                createdAt: item.lastUpdated,
                managed: false,
                assetId:
                    'sync_legacy_${cacheDigest('${source.key}|${p.normalize(local.path)}')}',
              ),
            );
            if (cache.persistenceError != null) await cache.flush();
          } else {
            await cache.refreshAvailability(mediaKey: source.key);
          }
          final complete = cache.completeExportVariant(item);
          if (complete != null) return File(complete.path);
        }
      } on FileSystemException {
        // Detached storage is unavailable, never a logical deletion.
      }
    }
    final variant = cache?.completeExportVariant(item);
    return variant == null ? null : File(variant.path);
  }

  /// The rendition selected for transfer may differ from the logical node's
  /// remembered size (e.g. another device already has a lower cached quality).
  Future<int?> cloudTransferBytes(VideoItem item) async {
    final file = await _cloudFile(item);
    if (file == null) return null;
    try {
      final stat = await file.stat();
      return stat.type == FileSystemEntityType.file && stat.size > 0
          ? stat.size
          : null;
    } on FileSystemException {
      return null;
    }
  }

  FolderSyncState state(String groupId, {FolderSyncSettings? settings}) {
    final result = _states.putIfAbsent(
      groupId,
      () => FolderSyncState(
        groupId: groupId,
        deviceId: deviceId,
        deviceName: deviceName,
      ),
    );
    if (settings != null) result.updateSettings(settings);
    return result;
  }

  int missingCount(String groupId) => _missing[groupId]?.length ?? 0;
  Set<String> missing(String groupId) => Set.of(_missing[groupId] ?? {});
  List<FolderSyncIssue> localIssues(String groupId) {
    final catalog = state(groupId);
    return [
      for (final localId in _unavailable[groupId] ?? <String>{})
        if (catalog.nodeIdForLocal(localId) case final nodeId?)
          FolderSyncIssue(
            groupId: groupId,
            nodeId: nodeId,
            title: library.getVideo(localId)?.title ?? '本机文件',
            reason: library.getVideo(localId)?.sourceRef?.cloudDrive != null
                ? 'cloudNeedsCache'
                : 'missingLocalFile',
            choices: const [],
          ),
      for (final nodeId in _deleteBlocks[groupId] ?? <String>{})
        FolderSyncIssue(
          groupId: groupId,
          nodeId: nodeId,
          title: catalog.heads(nodeId).first.node.name,
          reason: 'deleteHasLiveDescendants',
          choices: catalog.heads(nodeId),
        ),
    ];
  }

  Map<String, dynamic> toJson() {
    for (final state in _states.values) {
      state.compact();
    }
    return {
      for (final entry in _states.entries) entry.key: entry.value.toJson(),
    };
  }

  void restore(Map<String, dynamic> json) {
    if (json.length > 200) throw const FormatException('关联文件夹过多');
    for (final entry in json.entries) {
      final saved = Map<String, dynamic>.from(entry.value as Map);
      if (saved['deviceId'] != deviceId) {
        final imported = state(entry.key);
        for (final raw in saved['events'] as List? ?? []) {
          imported.merge(
            FolderSyncEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
          );
        }
        continue;
      }
      _states[entry.key] = FolderSyncState.fromJson(
        saved,
        deviceId: deviceId,
        deviceName: deviceName,
      );
    }
  }

  void remove(String groupId) {
    _states.remove(groupId);
    _missing.remove(groupId);
    _unavailable.remove(groupId);
    _deleteBlocks.remove(groupId);
  }

  bool allowed(
    FolderSyncSettings settings,
    String path, {
    bool folder = false,
    String? extension,
  }) {
    if (!folder &&
        settings.excludedExtensions.any(
          (excluded) =>
              (extension ?? p.extension(path)).toLowerCase() ==
              '.${excluded.replaceFirst(RegExp(r'^\.'), '').toLowerCase()}',
        )) {
      return false;
    }
    for (final pattern in settings.excludedPatterns) {
      if (pattern.isEmpty) continue;
      final expression = StringBuffer('^');
      for (var i = 0; i < pattern.length; i++) {
        final char = pattern[i];
        if (char == '*') {
          if (i + 1 < pattern.length && pattern[i + 1] == '*') {
            i++;
            expression.write('.*');
          } else {
            expression.write('[^/]*');
          }
        } else if (char == '?') {
          expression.write('[^/]');
        } else {
          expression.write(RegExp.escape(char));
        }
      }
      expression.write(r'$');
      if (RegExp(expression.toString(), caseSensitive: false).hasMatch(path)) {
        return false;
      }
    }
    return true;
  }

  Future<void> capture(
    String groupId,
    String rootId,
    FolderSyncSettings settings, {
    bool beforeImport = false,
  }) async {
    if (_applying.contains(groupId) ||
        !library.isInitialized ||
        (!beforeImport && rootImportBlocked?.call(rootId) == true)) {
      return;
    }
    final catalog = state(groupId, settings: settings);
    final root = library.getCollection(rootId);
    if (root == null || root.isRecycled) return;
    final claimExisting = catalog.localBindings.isEmpty;
    final rootNode = catalog.rootNodeId;
    if (rootNode != null && catalog.nodeIdForLocal(rootId) == null) {
      catalog.bindLocal(rootId, rootNode);
      final node = catalog.safeNodes[rootNode];
      if (node != null) {
        catalog.markApplied(rootNode, localId: rootId, appliedNode: node);
      }
    }
    final entries = <FolderSyncLocalEntry>[];
    final unavailable = <String>{};
    final visited = <String>{};
    Future<void> walk(String id, String? parent, String relative) async {
      if (!visited.add(id)) return;
      final folder = library.getCollection(id);
      if (folder != null) {
        if (folder.isRecycled ||
            (id != rootId && !allowed(settings, relative, folder: true))) {
          return;
        }
        if (claimExisting) {
          _claim(
            catalog,
            id,
            parent,
            FolderSyncNodeKind.folder,
            folder.name,
            null,
          );
        }
        // The bound root is a local alias, like its external parent. Only
        // descendant names are shared; preserve the existing logical root.
        final sharedName = id == rootId && rootNode != null
            ? catalog.safeNodes[rootNode]?.name ?? folder.name
            : folder.name;
        entries.add(
          FolderSyncLocalEntry(
            localId: id,
            parentLocalId: parent,
            kind: FolderSyncNodeKind.folder,
            name: sharedName,
          ),
        );
        for (final child in List<String>.of(folder.childrenIds)) {
          final name =
              library.getCollection(child)?.name ??
              library.getVideo(child)?.title ??
              '';
          await walk(child, id, relative.isEmpty ? name : '$relative/$name');
        }
        return;
      }
      final item = library.getVideo(id);
      if (item == null ||
          item.isRecycled ||
          item.isTransient ||
          !communityMediaIsPlayable(item.path, source: item.sourceRef) ||
          omitLegacyWebDownload(item, library) ||
          !allowed(settings, relative, extension: p.extension(item.path))) {
        return;
      }
      var key = await contentKey(item);
      final cloud = isCloudDriveMedia(source: item.sourceRef, path: item.path);
      final cloudFile = cloud ? await _cloudFile(item) : null;
      if (cloud && cloudFile == null) unavailable.add(id);
      if (key == null && !item.path.contains('://')) {
        final nodeId = catalog.nodeIdForLocal(id);
        final previous = nodeId == null ? null : catalog.appliedNode(nodeId);
        try {
          if (previous != null && await _relocate(item, previous)) {
            key = await contentKey(item);
          }
        } on FileSystemException catch (_) {
          /* An unavailable directory is not a deletion. */
        }
      }
      if (key == null && item.path.contains('://')) return;
      if (key == null) {
        unavailable.add(id);
        final mapped = catalog.nodeIdForLocal(id);
        if (mapped != null) key = catalog.appliedNode(mapped)?.contentKey;
      }
      if (claimExisting) {
        _claim(catalog, id, parent, FolderSyncNodeKind.media, item.title, key);
      }
      final mappedNode = catalog.nodeIdForLocal(id);
      final appliedNode = mappedNode == null
          ? null
          : catalog.appliedNode(mappedNode);
      final knownCloudNode = cloud && appliedNode?.contentKey == key
          ? appliedNode
          : null;
      final physicalExtension = p
          .extension(cloudFile?.path ?? item.path)
          .toLowerCase();
      entries.add(
        FolderSyncLocalEntry(
          localId: id,
          parentLocalId: parent,
          kind: FolderSyncNodeKind.media,
          name: item.title,
          contentKey: key,
          size: key?.startsWith('sha256:') == true
              ? int.tryParse(key!.split(':')[1]) ?? 0
              : (knownCloudNode?.size ?? 0) > 0
              ? knownCloudNode!.size
              : cloudFile == null
              ? 0
              : await cloudFile.length(),
          extension:
              appliedNode != null &&
                  appliedNode.contentKey == key &&
                  (!cloud || appliedNode.extension.isNotEmpty)
              ? appliedNode.extension
              : (RegExp(r'^\.[a-z0-9]{1,20}$').hasMatch(physicalExtension)
                    ? physicalExtension
                    : ''),
        ),
      );
    }

    await walk(rootId, null, '');
    final removed = <String>{}, deleted = <String>{};
    for (final entry in catalog.localBindings.entries) {
      if (entry.key == rootId || visited.contains(entry.key)) continue;
      if (catalog.isSuppressed(entry.value)) continue;
      final folder = library.getCollection(entry.key);
      final media = library.getVideo(entry.key);
      // An existing inaccessible media card is NOT a removal. Moving a card out
      // of the scope or deliberately recycling it is a local suppression.
      if (folder?.isRecycled == true || media?.isRecycled == true) {
        if (catalog.heads(entry.value).every((event) => event.deleted)) {
          continue;
        }
        if (settings.syncDeletes) {
          deleted.add(entry.key);
        } else {
          removed.add(entry.key);
        }
      } else if ((folder != null || media != null) &&
          !_inside(entry.key, rootId)) {
        removed.add(entry.key);
      } else if (folder == null && media == null) {
        removed.add(entry.key);
      }
    }
    catalog.capture(
      entries,
      explicitlyDeletedLocalIds: deleted,
      suppressedLocalIds: removed,
    );
    _unavailable[groupId] = unavailable;
  }

  void _claim(
    FolderSyncState catalog,
    String localId,
    String? parentLocalId,
    FolderSyncNodeKind kind,
    String name,
    String? key,
  ) {
    if (catalog.nodeIdForLocal(localId) != null) return;
    final parentNode = parentLocalId == null
        ? null
        : catalog.nodeIdForLocal(parentLocalId);
    var candidates = catalog.safeNodes.values
        .where(
          (node) =>
              node.kind == kind &&
              node.parentId == parentNode &&
              node.name == name &&
              (kind == FolderSyncNodeKind.folder || node.contentKey == key) &&
              catalog.localIdForNode(node.id) == null,
        )
        .toList();
    if (candidates.isEmpty && kind == FolderSyncNodeKind.media && key != null) {
      candidates = catalog.safeNodes.values
          .where(
            (node) =>
                node.kind == kind &&
                node.contentKey == key &&
                catalog.localIdForNode(node.id) == null,
          )
          .toList();
    }
    if (candidates.length == 1) {
      final node = candidates.single;
      catalog.bindLocal(localId, node.id);
      catalog.markApplied(node.id, localId: localId, appliedNode: node);
    }
  }

  bool _inside(String id, String rootId) {
    final seen = <String>{};
    String? current = id;
    while (current != null && seen.add(current)) {
      if (current == rootId) return true;
      current =
          library.getCollection(current)?.parentId ??
          library.getVideo(current)?.parentId;
    }
    return false;
  }

  Future<bool> _relocate(VideoItem item, FolderSyncNode previous) async {
    if (item.path.contains('://') ||
        previous.contentKey == null ||
        !previous.contentKey!.startsWith('sha256:')) {
      return false;
    }
    final last = _relocatedAt[item.id];
    if (last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 1)) {
      return false;
    }
    _relocatedAt[item.id] = DateTime.now();
    // Bounded search near the recorded path; never crawl arbitrary disks or
    // mistake a same-named file for the original.
    var directory = File(item.path).parent;
    if (!await directory.exists()) directory = directory.parent;
    if (!await directory.exists()) return false;
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    var scanned = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (++scanned > 1000 || DateTime.now().isAfter(deadline)) break;
      if (entity is! File) continue;
      final stat = await entity.stat();
      if (stat.size != previous.size) continue;
      final probe = VideoItem.fromJson({...item.toJson(), 'path': entity.path});
      if (await contentKey(probe) == previous.contentKey) {
        item.path = entity.path;
        await library.renameItem(item.id, item.title);
        return true;
      }
    }
    return false;
  }

  Future<void> apply(
    String groupId,
    String rootId,
    FolderSyncSettings settings,
  ) async {
    final catalog = state(groupId, settings: settings);
    if (_applying.contains(groupId) ||
        rootImportBlocked?.call(rootId) == true) {
      return;
    }
    if (settings.mode == FolderSyncMode.progressOnly) {
      _missing[groupId] = {};
      return;
    }
    final root = library.getCollection(rootId);
    if (root == null || root.isRecycled) return;
    _applying.add(groupId);
    try {
      final rootNode = catalog.rootNodeId;
      if (rootNode != null && catalog.localIdForNode(rootNode) == null) {
        catalog.bindLocal(rootId, rootNode);
      }
      final pending = catalog.safeNodes.values.toList();
      final needed = <String>{};
      final completed = <String>{};
      Map<String, VideoItem>? reusable;
      Future<VideoItem?> existingContent(String? key) async {
        if (key == null) return null;
        if (reusable == null) {
          final index = <String, VideoItem>{};
          for (final item in library.storageVideos.where(
            (item) => !item.isTransient && _inside(item.id, rootId),
          )) {
            final actual = await contentKey(item);
            if (isCloudDriveMedia(source: item.sourceRef, path: item.path) &&
                await _cloudFile(item) == null) {
              continue;
            }
            if (actual != null) index.putIfAbsent(actual, () => item);
          }
          reusable = index;
        }
        return reusable![key];
      }

      final maximumPasses = pending.length + 1;
      for (var pass = 0; pending.isNotEmpty && pass < maximumPasses; pass++) {
        var madeProgress = false;
        for (final node in List<FolderSyncNode>.of(pending)) {
          if (catalog.isSuppressed(node.id)) {
            pending.remove(node);
            continue;
          }
          final logical = <String>[node.name];
          var ancestor = node.parentId;
          final ancestry = <String>{};
          while (ancestor != null && ancestry.add(ancestor)) {
            final parentNode = catalog.safeNodes[ancestor];
            if (parentNode == null || parentNode.parentId == null) break;
            logical.insert(0, parentNode.name);
            ancestor = parentNode.parentId;
          }
          if (!allowed(
            settings,
            logical.join('/'),
            folder: node.kind == FolderSyncNodeKind.folder,
            extension: node.extension,
          )) {
            pending.remove(node);
            continue;
          }
          final parent = node.parentId == null
              ? null
              : catalog.localIdForNode(node.parentId!);
          if (node.parentId != null &&
              (parent == null || !completed.contains(node.parentId))) {
            continue;
          }
          var id = catalog.localIdForNode(node.id);
          if (node.kind == FolderSyncNodeKind.folder) {
            if (id == null || library.getCollection(id) == null) {
              final created = await library.createCollection(node.name, parent);
              id = created.id;
              catalog.bindLocal(id, node.id, replace: true);
            }
            final folder = library.getCollection(id)!;
            if (folder.isRecycled) await library.restoreFromRecycleBin([id]);
            if (!folder.isRecycled) {
              await library.applySyncItemMetadata(
                id,
                name: node.parentId == null ? folder.name : node.name,
                parentId: parent,
                preserveRootParent: node.parentId == null,
              );
              catalog.markApplied(
                node.id,
                localId: id,
                appliedNode: node,
                clock: node.parentId == null
                    ? folderSyncMergeClocks(
                        catalog.heads(node.id).map((event) => event.clock),
                      )
                    : null,
              );
            }
          } else {
            var item = id == null ? null : library.getVideo(id);
            if (item?.isRecycled == true) {
              await library.restoreFromRecycleBin([item!.id]);
            }
            var key = item == null || item.isRecycled
                ? null
                : await contentKey(item);
            if (key != node.contentKey) {
              final existing = await existingContent(node.contentKey);
              if (existing != null) {
                final alias = VideoItem.fromJson({
                  ...existing.toJson(),
                  'id': const Uuid().v4(),
                  'parentId': parent,
                  'title': node.name,
                  'lastPositionMs': 0,
                  'isRecycled': false,
                  'recycleTime': null,
                  'sourceFingerprint': null,
                });
                await library.addSingleVideo(alias, useOriginalPath: true);
                if (item != null) {
                  await library.commitSyncMediaRevision(
                    existingId: item.id,
                    importedId: alias.id,
                  );
                  item = library.getVideo(item.id);
                } else {
                  item = alias;
                }
                id = item!.id;
                catalog.bindLocal(id, node.id, replace: true);
                key = await contentKey(item);
              }
            }
            if (item != null &&
                !item.isRecycled &&
                key != null &&
                key == node.contentKey &&
                (!isCloudDriveMedia(source: item.sourceRef, path: item.path) ||
                    await _cloudFile(item) != null)) {
              await library.applySyncItemMetadata(
                item.id,
                name: node.name,
                parentId: parent,
              );
              catalog.markApplied(node.id, localId: item.id, appliedNode: node);
            } else {
              needed.add(node.id);
            }
          }
          completed.add(node.id);
          pending.remove(node);
          madeProgress = true;
        }
        if (!madeProgress) break;
      }
      // A parent's safe deletion is blocked by live/concurrent descendants in
      // the reducer. Physical files are never removed by this operation.
      final safeDeletes = catalog.safeDeletedNodeIds;
      final blockedDeletes = <String>{};
      for (final nodeId in safeDeletes) {
        if (nodeId == rootNode || catalog.isSuppressed(nodeId)) continue;
        final id = catalog.localIdForNode(nodeId);
        if (id != null && id != rootId) {
          final descendants = <String>[
            ...?library.getCollection(id)?.childrenIds,
          ];
          final checked = <String>{};
          var safe = true;
          while (descendants.isNotEmpty) {
            final child = descendants.removeLast();
            if (!checked.add(child)) {
              safe = false;
              break;
            }
            final identity = catalog.nodeIdForLocal(child);
            if (identity == null ||
                !safeDeletes.contains(identity) ||
                catalog.isSuppressed(identity)) {
              safe = false;
              break;
            }
            descendants.addAll(library.getCollection(child)?.childrenIds ?? []);
          }
          if (!safe) {
            blockedDeletes.add(nodeId);
            continue;
          }
          await library.recycleSyncItem(id);
          final head = catalog.heads(nodeId);
          if (head.isNotEmpty) {
            catalog.markApplied(
              nodeId,
              localId: id,
              appliedNode: head.first.node,
            );
          }
        }
      }
      _deleteBlocks[groupId] = blockedDeletes;
      _missing[groupId] = needed;
    } finally {
      _applying.remove(groupId);
    }
  }

  Future<void> adopt(
    String groupId,
    String rootId,
    Map<String, String> mappings,
    Map<String, dynamic> metadata,
    FolderSyncSettings settings,
  ) async {
    final catalog = state(groupId, settings: settings);
    final rawEvents = metadata['events'] as List? ?? [];
    if (rawEvents.length > 100000) throw const FormatException('目录记录过多');
    final packageEvents = <String, List<FolderSyncEvent>>{};
    for (final raw in rawEvents) {
      final event = FolderSyncEvent.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      if (event.groupId != groupId) throw const FormatException('目录不属于此关联');
      catalog.merge(event);
      packageEvents.putIfAbsent(event.node.id, () => []).add(event);
    }
    for (final entry in mappings.entries) {
      if (library.getVideo(entry.value) != null ||
          library.getCollection(entry.value) != null) {
        catalog.bindLocal(entry.value, entry.key, replace: true);
      }
    }
    for (final entry in mappings.entries) {
      final item = library.getVideo(entry.value);
      final folder = library.getCollection(entry.value);
      if (item == null && folder == null) continue;
      final heads = catalog.heads(entry.key);
      if (heads.isEmpty) continue;
      catalog.bindLocal(entry.value, entry.key, replace: true);
      final actualKey = item == null ? null : await contentKey(item);
      final candidates = packageEvents[entry.key] ?? const <FolderSyncEvent>[];
      final packageHeads = candidates.where(
        (event) => !candidates.any(
          (other) => other.id != event.id && other.descendsFrom(event),
        ),
      );
      final actualParent = item?.parentId ?? folder?.parentId;
      final parentNode = actualParent == null
          ? null
          : catalog.nodeIdForLocal(actualParent);
      final matching = packageHeads
          .where(
            (event) =>
                !event.deleted &&
                (item == null || event.node.contentKey == actualKey) &&
                (entry.value == rootId || event.node.parentId == parentNode) &&
                event.node.name == (item?.title ?? folder!.name),
          )
          .toList();
      // Only acknowledge the exact imported version. A local rename/move may
      // deliberately be preserved by the adapter while the package introduces
      // a concurrent branch; it must retain its previous causal baseline.
      if (matching.isNotEmpty &&
          matching.map((e) => e.semanticSignature).toSet().length == 1) {
        catalog.markApplied(
          entry.key,
          localId: entry.value,
          appliedNode: matching.first.node,
          clock: folderSyncMergeClocks(matching.map((event) => event.clock)),
        );
      }
    }
    if (catalog.rootNodeId case final root?) {
      catalog.bindLocal(rootId, root, replace: true);
    }
    await apply(groupId, rootId, settings);
  }
}
