part of 'library_service.dart';

/// Download providers share a durable commit, not a scheduler or downloader.
extension DownloadLibraryImport on LibraryService {
  Future<void> _restoreCancelledDownloadFile(
    VideoItem item,
    String originalPath,
  ) async {
    if (_samePath(item.path, originalPath) || !await File(item.path).exists()) {
      return;
    }
    if (_videos.values.any(
      (other) =>
          _samePath(other.path, item.path) ||
          other.playbackPath != null &&
              _samePath(other.playbackPath!, item.path),
    )) {
      return;
    }
    final prepared = File(item.path);
    final original = File(originalPath);
    if (await original.exists()) {
      await prepared.delete();
    } else {
      await original.parent.create(recursive: true);
      try {
        await prepared.rename(originalPath);
      } on FileSystemException {
        await prepared.copy(originalPath);
        if (await original.length() != await prepared.length()) {
          throw FileSystemException('取消入库后恢复下载文件未完成，成品仍保留', prepared.path);
        }
        await prepared.delete();
      }
    }
    item.path = originalPath;
  }

  VideoItem? importedDownloadMedia(DownloadImportContext context) {
    final direct = getVideo(context.mediaId);
    if (direct != null) return direct;
    for (final batch in importBatches) {
      if (batch.id != context.batchId) continue;
      final id = batch.downloadReceipts[context.operationId];
      return id == null ? null : getVideo(id);
    }
    return null;
  }

  Future<ImportReceipt> commitDownloadImport(
    VideoItem item, {
    required DownloadImportContext context,
    LibraryImportSourceKind sourceKind = LibraryImportSourceKind.localFile,
    bool useOriginalPath = false,
    bool reuseExistingItem = false,
    bool retainSharedMediaPath = false,
    bool persistReceivedFile = false,
    bool Function()? shouldContinue,
    List<String> createdCollectionIds = const [],
  }) {
    final running = _downloadImportInflight[context.operationId];
    if (running != null) return running;
    final operation = _commitDownloadImport(
      item,
      context: context,
      sourceKind: sourceKind,
      useOriginalPath: useOriginalPath,
      reuseExistingItem: reuseExistingItem,
      retainSharedMediaPath: retainSharedMediaPath,
      persistReceivedFile: persistReceivedFile,
      shouldContinue: shouldContinue,
      createdCollectionIds: createdCollectionIds,
    );
    _downloadImportInflight[context.operationId] = operation;
    return operation.whenComplete(() {
      if (identical(_downloadImportInflight[context.operationId], operation)) {
        _downloadImportInflight.remove(context.operationId);
      }
    });
  }

  Future<ImportReceipt> _commitDownloadImport(
    VideoItem item, {
    required DownloadImportContext context,
    required LibraryImportSourceKind sourceKind,
    required bool useOriginalPath,
    required bool reuseExistingItem,
    required bool retainSharedMediaPath,
    required bool persistReceivedFile,
    required bool Function()? shouldContinue,
    required List<String> createdCollectionIds,
  }) async {
    if (shouldContinue?.call() == false) throw StateError('入库已取消');
    if (_storageSealed || !_canMutateActivity) {
      throw StateError('媒体库暂时无法保存，请稍后重试入库');
    }
    final existing = importedDownloadMedia(context);
    String mediaId;
    if (existing != null) {
      if (existing.isRecycled) throw StateError('已入库媒体已移入回收站，请恢复后重试');
      mediaId = existing.id;
    } else {
      if (item.id != context.mediaId) {
        throw ArgumentError('下载卡片必须使用 context.mediaId');
      }
      // This identity is included in the same snapshot as the inserted card.
      // A crash between that snapshot and the queue journal cannot duplicate it.
      _activity.ensureMedia(item.id).downloadImport = context;
      String? id;
      try {
        id = await addSingleVideo(
          item,
          useOriginalPath: useOriginalPath,
          reuseExistingItem: reuseExistingItem,
          retainSharedMediaPath: retainSharedMediaPath,
          persistReceivedFile: persistReceivedFile,
          activityBatchId: context.batchId,
          sourceKind: sourceKind,
          shouldContinue: shouldContinue,
        );
      } finally {
        if (!_videos.containsKey(item.id)) _activity.media.remove(item.id);
      }
      if (id == null) throw StateError('未能添加媒体，请重试入库');
      mediaId = id;
    }
    _recordDownloadImport(
      mediaId,
      context,
      sourceKind,
      createdCollectionIds,
      reusedExisting: mediaId != context.mediaId,
    );
    await _saveLibrary();
    _requireDurableDownloadImport();
    _bumpActivity(notifyLibrary: false);
    notifyListeners();
    return ImportReceipt(mediaId: mediaId, context: context);
  }

  void _requireDurableDownloadImport() {
    if (_storageSealed || hasPersistenceFailure) {
      throw StateError('媒体库尚未保存，请重试入库');
    }
  }

  ImportBatchRecord _downloadBatch(
    DownloadImportContext context,
    LibraryImportSourceKind sourceKind,
  ) {
    final existing = _activity.batches
        .where((b) => b.id == context.batchId)
        .firstOrNull;
    if (existing != null) {
      if (sourceKind != LibraryImportSourceKind.localFile) {
        existing.sourceKind = sourceKind;
      }
      return existing;
    }
    final batch = ImportBatchRecord(
      id: context.batchId,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      title: context.title,
      sourceKind: sourceKind,
    );
    _activity.batches.insert(0, batch);
    return batch;
  }

  void _recordDownloadImport(
    String mediaId,
    DownloadImportContext context,
    LibraryImportSourceKind sourceKind,
    List<String> createdCollectionIds, {
    bool reusedExisting = false,
  }) {
    final batch = _downloadBatch(context, sourceKind);
    batch.downloadReceipts[context.operationId] = mediaId;
    // Path deduplication reuses a pre-existing card without taking ownership
    // of its original order, activity clock, or earlier import operation.
    if (reusedExisting) return;
    final record = _activity.ensureMedia(mediaId);
    record.downloadImport = context;
    record.addedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    if (batch.createdMediaIds.isEmpty) batch.startedAtMs = record.addedAtMs!;
    if (!batch.createdMediaIds.contains(mediaId)) {
      batch.createdMediaIds.add(mediaId);
    }
    for (final id in createdCollectionIds) {
      if (_collections.containsKey(id) &&
          !batch.createdCollectionIds.contains(id)) {
        batch.createdCollectionIds.add(id);
      }
    }
    batch.createdMediaIds.sort((a, b) {
      final ac = _activity.media[a]?.downloadImport,
          bc = _activity.media[b]?.downloadImport;
      return ac == null || bc == null
          ? 0
          : DownloadImportContext.compareOrder(ac, bc);
    });
    _arrangeDownloadBatch(batch);
  }

  Map<String, DownloadImportContext> _downloadOrderKeys(
    ImportBatchRecord batch,
  ) {
    final keys = <String, DownloadImportContext>{};
    for (final id in batch.createdMediaIds) {
      final context = _activity.media[id]?.downloadImport;
      final item = _videos[id];
      if (context == null || item == null || item.isRecycled) continue;
      keys[id] = context;
      var parent = item.parentId;
      final seen = <String>{};
      while (parent != null &&
          seen.add(parent) &&
          batch.createdCollectionIds.contains(parent)) {
        final current = keys[parent];
        if (current == null ||
            DownloadImportContext.compareOrder(context, current) < 0) {
          keys[parent] = context;
        }
        parent = _collections[parent]?.parentId;
      }
    }
    return keys;
  }

  void _arrangeDownloadBatch(ImportBatchRecord batch) {
    final keys = _downloadOrderKeys(batch);
    final parents = <String?>{};
    for (final id in keys.keys) {
      parents.add(_videos[id]?.parentId ?? _collections[id]?.parentId);
    }
    for (final parent in parents) {
      if (batch.manualOrderParents.contains(parent ?? '@root')) continue;
      final children = parent == null
          ? _rootChildrenIds
          : _collections[parent]?.childrenIds;
      if (children == null) continue;
      final slots = <int>[
        for (var i = 0; i < children.length; i++)
          if (keys.containsKey(children[i])) i,
      ];
      final members = [
        for (final slot in slots) children[slot],
      ]..sort((a, b) => DownloadImportContext.compareOrder(keys[a]!, keys[b]!));
      for (var i = 0; i < slots.length; i++) {
        children[slots[i]] = members[i];
      }
    }
    batch.createdCollectionIds.sort(
      (a, b) => keys[a] == null || keys[b] == null
          ? 0
          : DownloadImportContext.compareOrder(keys[a]!, keys[b]!),
    );
  }

  void _markDownloadOrderManual(String? parentId, Iterable<String> movedIds) {
    final moved = movedIds.toSet();
    for (final batch in _activity.batches) {
      final keys = _downloadOrderKeys(batch);
      if (moved.any(keys.containsKey)) {
        batch.manualOrderParents.add(parentId ?? '@root');
      }
    }
  }

  Future<VideoCollection> ensureDownloadImportCollection({
    required DownloadImportContext context,
    required String sourceKey,
    required String name,
    String? parentId,
  }) {
    final key = '${context.batchId}:${parentId ?? '@root'}:$sourceKey';
    final running = _downloadFolderInflight[key];
    if (running != null) return running;
    final operation = _ensureDownloadImportCollection(
      context,
      sourceKey,
      name,
      parentId,
    );
    _downloadFolderInflight[key] = operation;
    return operation.whenComplete(() => _downloadFolderInflight.remove(key));
  }

  Future<VideoCollection> _ensureDownloadImportCollection(
    DownloadImportContext context,
    String sourceKey,
    String name,
    String? parentId,
  ) async {
    final batch = _downloadBatch(context, LibraryImportSourceKind.localFile);
    final key = '${parentId ?? '@root'}:$sourceKey';
    final id =
        batch.downloadFolders[key] ??
        const Uuid().v5(Namespace.url.value, '${context.batchId}:$key');
    final folder =
        _collections[id] ?? await createCollection(name, parentId, id: id);
    if (folder.isRecycled) throw StateError('入库文件夹已移入回收站，请恢复后重试');
    batch.downloadFolders[key] = id;
    if (!batch.createdCollectionIds.contains(id)) {
      batch.createdCollectionIds.add(id);
    }
    await _saveLibrary();
    _requireDurableDownloadImport();
    return folder;
  }
}
