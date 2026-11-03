import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final library = LibraryService();
  late Directory root;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('library_local_import_s02_');
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 1000;
    await library.init();
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    PathProviderPlatform.instance = originalPathProvider;
    SettingsService().resetForTest();
    try {
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    } on FileSystemException {
      // Archive extract/import can keep a Windows handle until the isolate drops.
    }
  });

  test('multi-file import is one batch and singles stay projectable', () async {
    final first = await _media(root, 'a.mp4', 1);
    final second = await _media(root, 'b.mp4', 2);

    final result = await library.importVideosBackground(
      [first.path, second.path],
      null,
      useOriginalPath: true,
    );

    expect(result.createdVideoIds, hasLength(2));
    expect(library.importBatches, hasLength(1));
    expect(
      library.importBatches.single.createdMediaIds,
      result.createdVideoIds,
    );
    expect(
      library.importBatches.single.sourceKind,
      LibraryImportSourceKind.localFile,
    );
    final recent = library.activityProjection.recentAddedMediaIds();
    expect(recent.datedIds.toSet(), result.createdVideoIds.toSet());
  });

  test('folder import keeps name order and rollback drops the batch', () async {
    final folder = Directory(p.join(root.path, 'course'))..createSync();
    await _media(folder, 'ep1.mp4', 1);
    await _media(folder, 'ep2.mp4', 2);

    final ok = await library.importFolderSelection(
      folder.path,
      null,
      sortOptions: const StructuredImportSortOptions(
        field: StructuredImportSortField.fileName,
        direction: StructuredImportSortDirection.ascending,
      ),
    );
    expect(ok.importedVideoIds, hasLength(2));
    expect(library.importBatches, hasLength(1));
    expect(library.importBatches.single.createdMediaIds, ok.importedVideoIds);
    final titles = ok.importedVideoIds
        .map((id) => library.getVideo(id)!.title)
        .toList();
    expect(titles.first.toLowerCase(), contains('ep1'));
    expect(titles.last.toLowerCase(), contains('ep2'));

    library.structuredImportFailAfterCountForTesting = 1;
    final nested = Directory(p.join(root.path, 'broken'))..createSync();
    await _media(nested, 'one.mp4', 3);
    await _media(nested, 'two.mp4', 4);
    await expectLater(
      library.importFolderSelection(
        nested.path,
        null,
        sortOptions: const StructuredImportSortOptions(
          field: StructuredImportSortField.fileName,
          direction: StructuredImportSortDirection.ascending,
        ),
      ),
      throwsA(isA<StateError>()),
    );
    expect(library.importBatches, hasLength(1));
    expect(
      library.getContents(null).whereType<VideoCollection>().map((c) => c.name),
      isNot(contains('broken')),
    );
  });

  test('archive import publishes one batch in archive order', () async {
    final archiveFile = File(p.join(root.path, 'pack.zip'));
    final archive = Archive()
      ..addFile(ArchiveFile('lesson/c1.mp4', 3, <int>[1, 2, 3]))
      ..addFile(ArchiveFile('lesson/c2.mp4', 4, <int>[4, 5, 6, 7]));
    archiveFile.writeAsBytesSync(ZipEncoder().encode(archive), flush: true);

    final result = await library.importArchiveSelection(
      archiveFile.path,
      null,
      sortOptions: const StructuredImportSortOptions(
        field: StructuredImportSortField.fileName,
        direction: StructuredImportSortDirection.ascending,
      ),
    );
    expect(result.importedVideoIds, hasLength(2));
    expect(
      library.importBatches.single.sourceKind,
      LibraryImportSourceKind.archive,
    );
    expect(
      library.importBatches.single.createdMediaIds,
      result.importedVideoIds,
    );
  });

  test('reuse keeps addedAt and does not open an empty batch', () async {
    final file = await _media(root, 'same.mp4', 9);
    final first = await library.importVideosBackground(
      [file.path],
      null,
      useOriginalPath: true,
    );
    final addedAt = library
        .mediaActivity(first.createdVideoIds.single)!
        .addedAtMs;
    final second = await library.importVideosBackground(
      [file.path],
      null,
      useOriginalPath: true,
      reuseExistingItem: true,
    );
    expect(second.createdVideoIds, isEmpty);
    expect(second.reusedVideoIds, [first.createdVideoIds.single]);
    expect(library.importBatches, hasLength(1));
    expect(
      library.mediaActivity(first.createdVideoIds.single)!.addedAtMs,
      addedAt,
    );
  });

  test('busy exclusive import does not create a batch', () async {
    library.importOperationActiveForTesting = true;
    final file = await _media(root, 'busy.mp4', 5);
    final result = await library.importVideosBackground(
      [file.path],
      null,
      useOriginalPath: true,
    );
    expect(result.ignoredBecauseBusy, isTrue);
    expect(library.importBatches, isEmpty);
    library.importOperationActiveForTesting = false;
  });

  test('noting the same media twice stays a single batch member', () async {
    final item = VideoItem(
      id: 'clip',
      path: (await _media(root, 'clip.mp4', 8)).path,
      title: 'clip',
      durationMs: 1000,
      lastUpdated: 1,
      hasProbedChapters: true,
    );
    await library.addSingleVideo(item, useOriginalPath: true);
    final batchId = library.importBatches.single.id;
    library.noteImportedMedia('clip', addedAtMs: 1, batchId: batchId);
    expect(library.importBatches.single.createdMediaIds, ['clip']);
  });

  test('subtitle merge records once and undo clears activity', () async {
    final file = await _media(root, 'merge.mp4', 6);
    final item = VideoItem(
      id: 'merge-id',
      path: file.path,
      title: 'merge',
      durationMs: 1000,
      lastUpdated: 1,
      hasProbedChapters: true,
    );
    final created = await library.addSingleVideo(item, useOriginalPath: true);
    expect(created, 'merge-id');
    expect(library.importBatches.single.createdMediaIds, ['merge-id']);
    await library.removeSingleVideo('merge-id', keepFile: true);
    expect(library.mediaActivity('merge-id'), isNull);
    expect(library.importBatches, isEmpty);
  });

  test('post-processing save does not invent a second batch', () async {
    final file = await _media(root, 'post.mp4', 7);
    await library.importVideosBackground(
      [file.path],
      null,
      useOriginalPath: true,
    );
    expect(library.importBatches, hasLength(1));
    await library.saveLibraryForTesting();
    expect(library.importBatches, hasLength(1));
    final saved =
        jsonDecode(await File(p.join(root.path, 'library.json')).readAsString())
            as Map<String, dynamic>;
    expect((saved['activity']['batches'] as List), hasLength(1));
  });
}

Future<File> _media(FileSystemEntity parent, String name, int seed) {
  final file = File(p.join(parent.path, name));
  return file.writeAsBytes(
    List<int>.generate(32, (index) => (index + seed) & 0xff),
  );
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
