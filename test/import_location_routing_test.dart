import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/web_media/web_media_download_queue.dart';
import 'package:video_player_app/features/web_media/web_media_queue_store.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  late Directory root;
  late PathProviderPlatform originalPaths;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    originalPaths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('import_location_');
    PathProviderPlatform.instance = _Paths(root.path);
    await settings.init();
    settings.largeDataRootPath = root.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 1000;
    library.importPlacementPicker = null;
    await library.init();
  });

  tearDown(() async {
    library.importPlacementPicker = null;
    library.resetLibraryForTesting();
    settings.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // The archive worker may retain a Windows handle until its isolate exits.
    }
  });

  Future<File> media(String name, [int seed = 1]) async {
    final file = File(p.join(root.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.generate(64, (i) => (seed + i) % 256));
    return file;
  }

  Future<String?> resolve(
    ImportCardFeature feature,
    String? context, {
    ImportPlacementRequest? request,
  }) => library.resolveImportCardParentId(
    feature: feature,
    openedFromFolderId: context,
    request: request,
  );

  test(
    'manual imports follow the folder and download entries default to root',
    () async {
      final folder = await library.createCollection('project', null);
      for (final feature in ImportCardFeature.values) {
        expect(
          await resolve(feature, folder.id),
          feature.usesPlacementRules ? isNull : folder.id,
          reason: feature.label,
        );
      }
      expect(
        library.getContents(null).whereType<VideoCollection>(),
        hasLength(1),
      );
    },
  );

  test(
    'specific entry overrides source group, which overrides the preset',
    () async {
      final project = await library.createCollection('project', null);
      final course = await library.createCollection('course', project.id);
      final rules = ImportPlacementRules(
        overrides: {
          ImportCardGroup.bilibili.ruleKey: ImportPlacementRule(
            ImportCardPlacement.fixedFolder,
            folderId: course.id,
          ),
          ImportCardFeature.bilibiliOnline.storageValue:
              const ImportPlacementRule(ImportCardPlacement.libraryRoot),
        },
      );
      await settings.saveImportPlacement(
        ImportCardPlacement.currentFolder,
        rules,
      );
      expect(
        await resolve(ImportCardFeature.bilibiliDownload, project.id),
        course.id,
      );
      expect(await resolve(ImportCardFeature.bilibiliPage, null), course.id);
      expect(
        await resolve(ImportCardFeature.bilibiliOnline, project.id),
        isNull,
      );
      expect(await resolve(ImportCardFeature.webMedia, project.id), project.id);
      await settings.saveImportPlacement(
        ImportCardPlacement.sourceFolder,
        rules,
      );
      expect(
        await resolve(ImportCardFeature.bilibiliOnline, course.id),
        isNull,
      );
    },
  );

  test(
    'serialized queued targets stay stable when the preset and context change',
    () async {
      final folder = await library.createCollection('project', null);
      await settings.updateSetting('importCardPlacement', 'currentFolder');
      final queued = ImportPlacementRequest.fromJson(
        settings
            .captureImportPlacement(
              ImportCardFeature.ytDlp,
              openedFromFolderId: folder.id,
            )
            .toJson(),
      )!;
      await settings.updateSetting('importCardPlacement', 'libraryRoot');
      expect(
        await resolve(ImportCardFeature.ytDlp, null, request: queued),
        folder.id,
      );
      final queuedRoot = settings.captureImportPlacement(
        ImportCardFeature.webMedia,
      );
      await settings.updateSetting('importCardPlacement', 'sourceFolder');
      expect(
        await resolve(
          ImportCardFeature.webMedia,
          folder.id,
          request: queuedRoot,
        ),
        isNull,
      );
    },
  );

  test(
    'retired browser discoveries stay inactive and retain their saved placement',
    () async {
      final folder = await library.createCollection('original-context', null);
      await settings.updateSetting('importCardPlacement', 'currentFolder');
      final request = settings.captureImportPlacement(
        ImportCardFeature.webMedia,
        openedFromFolderId: folder.id,
      );
      await WebMediaQueueStore(root).write({
        'tasks': [],
        'discoveries': [
          {
            'id': 'saved-discovery',
            'sourcePage': 'https://example.com/watch',
            'identity': 'saved-page',
            'targetFolderId': folder.id,
            'importPlacement': request.toJson(),
          },
        ],
      });
      await settings.updateSetting('importCardPlacement', 'libraryRoot');
      final queue = WebMediaDownloadQueue(
        Object(),
        directoryProvider: () async => root,
      );
      try {
        await queue.loadSettings();
        expect(queue.nativeTasks, isEmpty);
        final saved = await WebMediaQueueStore(root).read();
        final discovery = (saved!['discoveries'] as List).single as Map;
        final restored = ImportPlacementRequest.fromJson(
          discovery['importPlacement'],
        )!;
        expect(restored.folderId, folder.id);
        expect(
          await resolve(ImportCardFeature.webMedia, null, request: restored),
          folder.id,
        );
      } finally {
        await queue.shutdown();
      }
    },
  );

  test(
    'browser and Douyin imports do not inherit local-file exceptions',
    () async {
      final folder = await library.createCollection('local-only', null);
      await settings.saveImportPlacement(
        ImportCardPlacement.libraryRoot,
        ImportPlacementRules(
          overrides: {
            ImportCardGroup.local.ruleKey: ImportPlacementRule(
              ImportCardPlacement.fixedFolder,
              folderId: folder.id,
            ),
          },
        ),
      );
      for (final feature in [
        ImportCardFeature.webMedia,
        ImportCardFeature.douyin,
      ]) {
        final file = await media('${feature.storageValue}.mp4');
        final result = await library.importVideosBackground(
          [file.path],
          folder.id,
          useOriginalPath: true,
          importFeature: feature,
        );
        expect(
          library.getVideo(result.createdVideoIds.single)!.parentId,
          isNull,
        );
      }
    },
  );

  test(
    'explicit folder and explicit root both beat all configured overrides',
    () async {
      final target = await library.createCollection('drop-target', null);
      await settings.updateSetting('importCardPlacement', 'sourceFolder');
      for (final id in [target.id, null]) {
        final file = await media('drop-${id ?? 'root'}.mp4');
        final result = await library.importVideosBackground(
          [file.path],
          id,
          useOriginalPath: true,
          explicitPlacement: true,
        );
        expect(library.getVideo(result.createdVideoIds.single)!.parentId, id);
      }
      expect(
        library.getContents(null).whereType<VideoCollection>(),
        hasLength(1),
      );
    },
  );

  test(
    'folder and archive drops keep both target and internal hierarchy',
    () async {
      final target = await library.createCollection('drop-target', null);
      await settings.updateSetting('importCardPlacement', 'sourceFolder');
      await media('course/chapter/lesson.mp4');
      const sort = StructuredImportSortOptions(
        field: StructuredImportSortField.fileName,
        direction: StructuredImportSortDirection.ascending,
      );
      final folder = await library.importFolderSelection(
        p.join(root.path, 'course'),
        target.id,
        sortOptions: sort,
        explicitPlacement: true,
      );
      expect(
        library.relativeFolderPath(
          target.id,
          library.getVideo(folder.importedVideoIds.single)!.parentId,
        ),
        contains('chapter'),
      );
      final zip = File(p.join(root.path, 'bundle.zip'));
      await zip.writeAsBytes(
        ZipEncoder().encode(
          Archive()..addFile(ArchiveFile('chapter/lesson.mp4', 3, [1, 2, 3])),
        ),
      );
      final archive = await library.importArchiveSelection(
        zip.path,
        target.id,
        sortOptions: sort,
        explicitPlacement: true,
      );
      expect(
        library.relativeFolderPath(
          target.id,
          library.getVideo(archive.importedVideoIds.single)!.parentId,
        ),
        contains('chapter'),
      );
    },
  );

  test(
    'missing explicit target fails without moving content or consuming the source',
    () async {
      final file = await media('keep.mp4');
      await expectLater(
        library.importVideosBackground(
          [file.path],
          'deleted-target',
          useOriginalPath: true,
          explicitPlacement: true,
        ),
        throwsA(isA<ImportPlacementException>()),
      );
      expect(await file.exists(), isTrue);
      expect(library.getContents(null), isEmpty);
      expect(library.hasActiveImport, isFalse);
    },
  );

  test(
    'an explicit ask request chooses once per batch and cancellation keeps files',
    () async {
      final target = await library.createCollection('chosen', null);
      ImportPlacementRequest request() => ImportPlacementRequest(
        feature: ImportCardFeature.localFile,
        placement: ImportCardPlacement.askEveryTime,
      );
      var prompts = 0;
      library.importPlacementPicker = (feature, initial) async {
        prompts++;
        return ImportPlacementRequest.explicit(feature, target.id);
      };
      final first = await media('first.mp4');
      final second = await media('second.mp4', 2);
      final result = await library.importVideosBackground(
        [first.path, second.path],
        null,
        useOriginalPath: true,
        importPlacement: request(),
      );
      expect(prompts, 1);
      expect(
        result.createdVideoIds
            .map((id) => library.getVideo(id)!.parentId)
            .toSet(),
        {target.id},
      );
      library.importPlacementPicker = (_, _) async => null;
      final cancelled = await media('cancelled.mp4', 3);
      await expectLater(
        library.importVideosBackground(
          [cancelled.path],
          null,
          useOriginalPath: true,
          importPlacement: request(),
        ),
        throwsA(isA<ImportPlacementException>()),
      );
      expect(await cancelled.exists(), isTrue);
      expect(library.hasActiveImport, isFalse);
    },
  );

  test(
    'an unavailable queued target can be explicitly replaced on retry',
    () async {
      final request = ImportPlacementRequest.explicit(
        ImportCardFeature.douyin,
        'gone',
      );
      var prompts = 0;
      library.importPlacementPicker = (feature, initial) async {
        expect(initial, 'gone');
        prompts++;
        return ImportPlacementRequest.explicit(feature, null);
      };
      expect(
        await resolve(ImportCardFeature.douyin, null, request: request),
        isNull,
      );
      expect(prompts, 1);
      expect(request.isResolved, isTrue);
      expect(request.folderId, isNull);
      expect(
        await resolve(ImportCardFeature.douyin, null, request: request),
        isNull,
      );
      expect(prompts, 1);
    },
  );

  test(
    'concurrent Bilibili entries share one lazily created source folder',
    () async {
      await settings.updateSetting('importCardPlacement', 'sourceFolder');
      expect(library.getContents(null), isEmpty);
      final ids = await Future.wait([
        resolve(ImportCardFeature.bilibiliDownload, null),
        resolve(ImportCardFeature.bilibiliOnline, null),
        resolve(ImportCardFeature.bilibiliPage, null),
      ]);
      expect(ids.toSet(), hasLength(1));
      expect(
        library.getContents(null).whereType<VideoCollection>(),
        hasLength(1),
      );
    },
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => p.join(root, 'tmp');
  @override
  Future<String?> getApplicationCachePath() async => p.join(root, 'cache');
}
