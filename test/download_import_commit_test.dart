import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/download_import_context.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform previous;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('download_import_commit_');
    previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
  });
  tearDown(() async {
    await library.saveLibraryForTesting();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = previous;
    for (var attempt = 0; await root.exists(); attempt++) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }
  });

  Future<ImportReceipt> commit(
    DownloadImportContext context, {
    String? parent,
  }) => library.commitDownloadImport(
    _item(context, parent: parent),
    context: context,
    sourceKind: LibraryImportSourceKind.bilibili,
  );

  test(
    'later completion is usable immediately and earlier member returns to its slot',
    () async {
      final batch = DownloadImportContext.freeze(
        memberIds: ['a', 'b'],
        title: '课程',
      );
      final other = DownloadImportContext.single(
        memberId: 'other',
        title: '其他',
      );
      void cacheVisibleContents() => library.browseContents(null);
      library.addListener(cacheVisibleContents);
      addTearDown(() => library.removeListener(cacheVisibleContents));
      await commit(batch[1]);
      expect(library.getVideo(batch[1].mediaId), isNotNull);
      await commit(other);
      await commit(batch[0]);
      expect(library.getVideosInFolder(null).map((v) => v.id), [
        batch[0].mediaId,
        other.mediaId,
        batch[1].mediaId,
      ]);
      expect(library.browseContents(null).map((v) => (v as VideoItem).id), [
        batch[0].mediaId,
        other.mediaId,
        batch[1].mediaId,
      ]);
      final saved = library.importBatches.firstWhere(
        (b) => b.id == batch[0].batchId,
      );
      expect(saved.createdMediaIds, batch.map((c) => c.mediaId));
      expect(
        library.mediaActivity(batch[0].mediaId)!.addedAtMs!,
        greaterThanOrEqualTo(batch[0].startedAtMs),
      );
    },
  );

  test(
    'duplicate concurrent completions commit one card and one activity batch',
    () async {
      final context = DownloadImportContext.single(memberId: 'a', title: '课程');
      final receipts = await Future.wait([
        commit(context),
        commit(context),
        commit(context),
      ]);
      expect(receipts.map((r) => r.mediaId).toSet(), {context.mediaId});
      expect(library.getVideosInFolder(null), hasLength(1));
      expect(library.importBatches, hasLength(1));
    },
  );

  test(
    'failed persistence cannot issue receipt and retry reuses inserted card',
    () async {
      final context = DownloadImportContext.single(memberId: 'a', title: '课程');
      library.writeLibrarySnapshotOverrideForTesting = () async =>
          throw const FileSystemException('disk full');
      await expectLater(commit(context), throwsStateError);
      expect(library.getVideosInFolder(null), hasLength(1));
      library.writeLibrarySnapshotOverrideForTesting = null;
      await commit(context);
      expect(library.hasPersistenceFailure, isFalse);
      expect(library.getVideosInFolder(null), hasLength(1));
    },
  );

  test(
    'interrupted insertion is retried without adding a second card',
    () async {
      final context = DownloadImportContext.single(memberId: 'a', title: '课程');
      library.failAddSingleVideoAfterInsertForTesting = true;
      await expectLater(commit(context), throwsStateError);
      library.failAddSingleVideoAfterInsertForTesting = false;
      await commit(context);
      expect(library.getVideosInFolder(null), hasLength(1));
      expect(library.importBatches.single.createdMediaIds, [context.mediaId]);
    },
  );

  test(
    'durable order survives restart and removal of queue-side records',
    () async {
      final contexts = DownloadImportContext.freeze(
        memberIds: ['a', 'b'],
        title: '课程',
      );
      await commit(contexts[1]);
      library.resetLibraryForTesting();
      SettingsService().largeDataRootPath = root.path;
      await library.init();
      final restored = DownloadImportContext.fromJson(contexts[0].toJson())!;
      await commit(restored);
      await commit(contexts[1]);
      expect(
        library.getVideosInFolder(null).map((v) => v.id),
        contexts.map((c) => c.mediaId),
      );
      expect(
        library.importBatches.single.createdMediaIds,
        contexts.map((c) => c.mediaId),
      );
    },
  );

  test(
    'concurrent folder creation shares one persistent source folder',
    () async {
      final contexts = DownloadImportContext.freeze(
        memberIds: ['a', 'b'],
        title: '课程',
      );
      final folders = await Future.wait([
        for (final c in contexts)
          library.ensureDownloadImportCollection(
            context: c,
            sourceKey: 'playlist:1',
            name: '课程',
          ),
      ]);
      expect(folders.map((f) => f.id).toSet(), hasLength(1));
      await commit(contexts[1], parent: folders.first.id);
      await commit(contexts[0], parent: folders.first.id);
      expect(
        library.getVideosInFolder(folders.first.id).map((v) => v.id),
        contexts.map((c) => c.mediaId),
      );
      expect(
        library.importBatches.single.sourceKind,
        LibraryImportSourceKind.bilibili,
      );
    },
  );

  test(
    'manual ordering opts this parent out of later batch rearrangement',
    () async {
      final contexts = DownloadImportContext.freeze(
        memberIds: ['a', 'b', 'c'],
        title: '课程',
      );
      await commit(contexts[1]);
      await commit(contexts[0]);
      await library.reorderItems(null, 0, 1);
      await commit(contexts[2]);
      expect(library.getVideosInFolder(null).map((v) => v.id), [
        contexts[1].mediaId,
        contexts[0].mediaId,
        contexts[2].mediaId,
      ]);
      expect(
        library.importBatches.single.manualOrderParents,
        contains('@root'),
      );
    },
  );

  test(
    'browser background importer keeps preprocessing and uses stable member identity',
    () async {
      library.probeMediaDurationOverrideForTesting = (_) => 1000;
      final contexts = DownloadImportContext.freeze(
        memberIds: ['a', 'b'],
        title: '网页',
      );
      final file = await File(
        '${root.path}/sample.wav',
      ).writeAsBytes(List.filled(4096, 0));
      for (final c in contexts.reversed) {
        final result = await library.importVideosBackground(
          [file.path],
          null,
          downloadContext: c,
          originalTitles: [c.memberId],
          reuseExistingItem: false,
          sourceKind: LibraryImportSourceKind.ytDlp,
        );
        expect(result.createdVideoIds, [c.mediaId]);
      }
      expect(
        library.getVideosInFolder(null).map((v) => v.id),
        contexts.map((c) => c.mediaId),
      );
      final retry = await library.importVideosBackground(
        [file.path],
        null,
        downloadContext: contexts[0],
      );
      expect(retry.reusedVideoIds, [contexts[0].mediaId]);
      expect(library.getVideosInFolder(null), hasLength(2));
    },
  );

  test(
    'a removed task cannot publish after asynchronous import preparation',
    () async {
      final context = DownloadImportContext.single(
        memberId: 'cancelled',
        title: '下载',
      );
      final file = await File(
        '${root.path}/cancelled.wav',
      ).writeAsBytes(List.filled(4096, 0));
      library.probeMediaDurationOverrideForTesting = (_) => 1000;
      var live = true;
      final operation = library.commitDownloadImport(
        VideoItem(
          id: context.mediaId,
          path: file.path,
          title: 'cancelled',
          durationMs: 0,
          lastUpdated: 1,
          type: MediaType.audio,
          hasProbedChapters: true,
        ),
        context: context,
        useOriginalPath: true,
        shouldContinue: () => live,
      );
      live = false;
      await expectLater(operation, throwsStateError);
      expect(library.getVideo(context.mediaId), isNull);
      expect(library.mediaActivity(context.mediaId), isNull);
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'reused source cards retain their original order and durable receipts',
    () async {
      library.probeMediaDurationOverrideForTesting = (_) => 1000;
      final file = await File(
        '${root.path}/reused.wav',
      ).writeAsBytes(List.filled(4096, 0));
      final prefix = DownloadImportContext.single(
        memberId: 'prefix',
        title: '前项',
      );
      final suffix = DownloadImportContext.single(
        memberId: 'suffix',
        title: '后项',
      );
      await commit(prefix);
      final initial = await library.importVideosBackground([file.path], null);
      final id = initial.createdVideoIds.single;
      await commit(suffix);
      final addedAt = library.mediaActivity(id)!.addedAtMs;
      final first = DownloadImportContext.single(
        memberId: 'reuse-a',
        title: '下载',
      );
      final second = DownloadImportContext.single(
        memberId: 'reuse-b',
        title: '下载',
      );
      for (final context in [first, second]) {
        final result = await library.importVideosBackground(
          [file.path],
          null,
          downloadContext: context,
          reuseExistingItem: true,
        );
        expect(result.reusedVideoIds, [id]);
      }
      expect(library.getVideosInFolder(null).map((v) => v.id), [
        prefix.mediaId,
        id,
        suffix.mediaId,
      ]);
      expect(library.mediaActivity(id)!.addedAtMs, addedAt);
      expect(library.mediaActivity(id)!.downloadImport, isNull);
      library.resetLibraryForTesting();
      SettingsService().largeDataRootPath = root.path;
      await library.init();
      expect(library.importedDownloadMedia(first)?.id, id);
      expect(library.importedDownloadMedia(second)?.id, id);
    },
  );

  for (final background in [false, true]) {
    test(
      'cancel during deduplication cannot move an existing card (background=$background)',
      () async {
        library.probeMediaDurationOverrideForTesting = (_) => 1000;
        final file = await File(
          '${root.path}/cancel-reuse.wav',
        ).writeAsBytes(List.filled(4096, 0));
        final original = await library.importVideosBackground([
          file.path,
        ], null);
        final id = original.createdVideoIds.single;
        final target = await library.createCollection('目标', null);
        final context = DownloadImportContext.single(
          memberId: 'cancel-reuse',
          title: '下载',
        );
        var live = true;
        var scheduled = false;
        bool current() {
          if (!scheduled) {
            scheduled = true;
            scheduleMicrotask(() => live = false);
          }
          return live;
        }

        final Future<Object?> operation = background
            ? library.importVideosBackground(
                [file.path],
                target.id,
                downloadContext: context,
                reuseExistingItem: true,
                shouldContinue: current,
              )
            : library.commitDownloadImport(
                VideoItem(
                  id: context.mediaId,
                  path: file.path,
                  title: 'cancel-reuse',
                  durationMs: 1000,
                  lastUpdated: 1,
                  parentId: target.id,
                  type: MediaType.audio,
                  hasProbedChapters: true,
                ),
                context: context,
                useOriginalPath: true,
                reuseExistingItem: true,
                shouldContinue: current,
              );
        await expectLater(operation, throwsStateError);
        expect(library.getVideo(id)!.parentId, isNull);
        expect(library.importedDownloadMedia(context), isNull);
      },
    );
  }

  test(
    'recent added orders batches by real library arrival instead of download start',
    () async {
      const early = DownloadImportContext(
        batchId: 'early',
        memberId: 'a',
        order: [0],
        operationId: 'early-operation',
        startedAtMs: 1,
        title: '很早开始的下载',
      );
      const later = DownloadImportContext(
        batchId: 'later',
        memberId: 'b',
        order: [0],
        operationId: 'later-operation',
        startedAtMs: 2,
        title: '稍后开始的下载',
      );
      await commit(later);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      await commit(early);
      expect(
        library.activityProjection.recentAddedEntries().first.mediaId,
        early.mediaId,
      );
      expect(
        library.importBatches
            .firstWhere((b) => b.id == early.batchId)
            .startedAtMs,
        library.mediaActivity(early.mediaId)!.addedAtMs,
      );
    },
  );
}

VideoItem _item(DownloadImportContext context, {String? parent}) => VideoItem(
  id: context.mediaId,
  path: 'bilibili://stream/BV1test?cid=${context.memberId}',
  title: context.memberId,
  durationMs: 1000,
  lastUpdated: DateTime.now().millisecondsSinceEpoch,
  parentId: parent,
  hasProbedChapters: true,
  sourceRef: const MediaSourceRef(
    kind: MediaSourceKind.bilibiliStream,
    value: 'BV1test',
    bvid: 'BV1test',
    cid: 1,
  ),
);

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}
