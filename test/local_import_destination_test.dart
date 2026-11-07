import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  const localFeatures = [
    ImportCardFeature.localFile,
    ImportCardFeature.folder,
    ImportCardFeature.archive,
    ImportCardFeature.fluentPack,
  ];
  const sort = StructuredImportSortOptions(
    field: StructuredImportSortField.fileName,
    direction: StructuredImportSortDirection.ascending,
  );
  late Directory root;
  late PathProviderPlatform originalPaths;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    originalPaths = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('local_import_destination_');
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
      await root.delete(recursive: true);
    } on FileSystemException {
      // Archive workers may briefly retain file handles on Windows.
    }
  });

  Future<File> media(String name) async {
    final file = File(p.join(root.path, name));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(List.generate(64, (index) => index));
  }

  for (final mode in ImportCardPlacement.values) {
    test(
      'manual imports ignore the $mode preset and legacy overrides',
      () async {
        final parent = await library.createCollection('course', null);
        final target = await library.createCollection('chapter', parent.id);
        final inbox = await library.createCollection('old-inbox', null);
        await settings.saveImportPlacement(
          mode,
          ImportPlacementRules(
            fixedFolderId: inbox.id,
            overrides: {
              ImportCardGroup.local.ruleKey: ImportPlacementRule(
                ImportCardPlacement.fixedFolder,
                folderId: inbox.id,
              ),
              ImportCardGroup.portable.ruleKey: const ImportPlacementRule(
                ImportCardPlacement.sourceFolder,
              ),
              ImportCardFeature.localFile.storageValue:
                  const ImportPlacementRule(ImportCardPlacement.askEveryTime),
            },
          ),
        );
        library.importPlacementPicker = (_, _) async =>
            fail('Manual imports must not ask for a download destination');

        for (final folderId in [target.id, null]) {
          for (final feature in localFeatures) {
            final captured = settings.captureImportPlacement(
              feature,
              openedFromFolderId: folderId,
            );
            // Restoring a captured operation must keep its original folder,
            // even if a different page is now open.
            final restored = ImportPlacementRequest.fromJson(
              captured.toJson(),
            )!;
            expect(
              await library.resolveImportCardParentId(
                feature: feature,
                openedFromFolderId: inbox.id,
                request: restored,
              ),
              folderId,
              reason: '$feature from $folderId',
            );
          }
          for (final kind in [
            LibraryImportSourceKind.localFile,
            LibraryImportSourceKind.share,
          ]) {
            final file = await media('${mode.name}-${kind.name}-$folderId.mp4');
            final result = await library.importVideosBackground(
              [file.path],
              folderId,
              useOriginalPath: true,
              sourceKind: kind,
            );
            expect(
              library.getVideo(result.createdVideoIds.single)!.parentId,
              folderId,
            );
            expect(await file.exists(), isTrue);
          }
        }
        expect(library.storageCollections, hasLength(3));
        expect(settings.importPlacementRules.overrides, hasLength(3));
      },
    );
  }

  test(
    'folder, archive and package imports preserve the current hierarchy',
    () async {
      final course = await library.createCollection('course', null);
      final target = await library.createCollection('chapter', course.id);
      await settings.updateSetting('importCardPlacement', 'sourceFolder');

      await media('selected/part/lesson.mp4');
      final folder = await library.importFolderSelection(
        p.join(root.path, 'selected'),
        target.id,
        sortOptions: sort,
      );
      final archive = File(p.join(root.path, 'selected.zip'));
      await archive.writeAsBytes(
        ZipEncoder().encode(
          Archive()..addFile(ArchiveFile('part/lesson.mp4', 3, [1, 2, 3])),
        ),
      );
      final zipped = await library.importArchiveSelection(
        archive.path,
        target.id,
        sortOptions: sort,
      );
      await media('package/part/lesson.mp4');
      final package = await library.importPortablePackageDirectory(
        p.join(root.path, 'package'),
        rootCollectionName: 'restored-package',
        mediaEntriesHint: 1,
        sortOptions: sort,
        openedFromFolderId: target.id,
      );
      for (final result in [folder, zipped, package]) {
        expect(
          library.getCollection(result.rootCollectionId)!.parentId,
          target.id,
        );
        expect(
          library.relativeFolderPath(
            target.id,
            library.getVideo(result.importedVideoIds.single)!.parentId,
          ),
          contains('part'),
        );
      }
      expect(
        library.getContents(null).whereType<VideoCollection>().single.id,
        course.id,
      );
      expect(await archive.exists(), isTrue);
    },
  );

  test(
    'explicit targets remain valid and a missing local folder keeps files',
    () async {
      final folder = await library.createCollection('folder', null);
      final file = await media('lesson.mp4');
      final imported = await library.importVideosBackground(
        [file.path],
        folder.id,
        useOriginalPath: true,
        importPlacement: ImportPlacementRequest.explicit(
          ImportCardFeature.localFile,
          null,
        ),
      );
      expect(
        library.getVideo(imported.createdVideoIds.single)!.parentId,
        isNull,
      );
      await expectLater(
        library.importVideosBackground(
          [file.path],
          'deleted-folder',
          useOriginalPath: true,
        ),
        throwsA(isA<ImportPlacementException>()),
      );
      expect(await file.exists(), isTrue);
      expect(library.storageVideos, hasLength(1));
      expect(library.hasActiveImport, isFalse);
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
