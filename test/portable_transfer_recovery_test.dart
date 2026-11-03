import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'test_dir_cleanup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late PathProviderPlatform originalPathProvider;
  late LibraryService library;
  final service = PortableTransferService.instance;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    root = await Directory.systemTemp.createTemp('portable_recovery_test_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService();
    await library.init();
    await service.initialize(library: library);
  });

  tearDown(() => service.clearFinished());

  tearDownAll(() async {
    PathProviderPlatform.instance = originalPathProvider;
    SettingsService().resetForTest();
    await deleteTestTempDir(root);
  });

  test(
    'cancelled export removes its part file and remains retryable',
    () async {
      final media = File(p.join(root.path, 'cancel-source.mp4'));
      await media.writeAsBytes(List<int>.filled(2 * 1024 * 1024, 7));
      final item = VideoItem(
        id: 'cancel-source-card',
        path: media.path,
        title: 'Cancel source',
        durationMs: 1000,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
      );
      await library.addSingleVideo(
        item,
        useOriginalPath: true,
        reuseExistingItem: false,
      );
      final output = p.join(root.path, 'cancelled.fluentpack');
      final task = await service.exportSelection(
        library: library,
        rootIds: <String>[item.id],
        outputPath: output,
        options: const PortableExportOptions(
          packageName: 'Cancelled export',
          compression: PortableCompression.smallest,
        ),
      );

      service.cancel(task.id);
      await _waitForTask(task);

      expect(task.status, PortableTransferStatus.cancelled);
      expect(await File('$output.part').exists(), isFalse);
      expect(service.canRetry(task.id), isTrue);

      await service.retryTask(task.id, library);
      await _waitForTask(task);
      expect(task.status, PortableTransferStatus.completed);
      expect(await File(output).exists(), isTrue);
      expect(service.storagePathsInUse, isNot(contains(output)));
      await File(output).delete();
      await service.forgetStorageFiles([output]);
      expect(task.filePath, isNull);
      expect(task.canOpen, false);
    },
  );

  test(
    'failed import cleans extraction but preserves a retry source',
    () async {
      final package = File(p.join(root.path, 'broken-snapshot.fluentpack'));
      final encoder = ZipFileEncoder()..create(package.path);
      encoder.addArchiveFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode(<String, dynamic>{
            'format': 'fluent-player-portable-package',
            'formatVersion': PortableTransferService.formatVersion,
            'packageName': 'Broken snapshot',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'mediaCount': 0,
            'folderCount': 0,
            'fileCount': 0,
            'totalBytes': 0,
            'checksums': <String, String>{},
            'snapshot': <String, dynamic>{
              'collections': <dynamic>[],
              'videos': <dynamic>[],
            },
          }),
        ),
      );
      await encoder.close();
      final preview = await service.inspectPackage(package.path);
      final task = await service.importPackage(
        library: library,
        packagePath: package.path,
        preview: preview,
        deletePackageWhenDone: true,
      );

      await _waitForTask(task);

      expect(task.status, PortableTransferStatus.failed);
      expect(await package.exists(), isTrue);
      expect(service.canRetry(task.id), isTrue);
      expect(service.storagePathsInUse, isNot(contains(package.path)));
      expect(
        await Directory(p.join(root.path, 'fluent_transfer', task.id)).exists(),
        isFalse,
      );

      await service.removeTasks(<String>[task.id]);
      expect(await package.exists(), isFalse);
    },
  );

  test('explicit storage cleanup disables a failed import retry', () async {
    final package = File(p.join(root.path, 'cleanup-failed.fluentpack'));
    await package.writeAsString('broken package');
    final task = await service.importPackage(
      library: library,
      packagePath: package.path,
      preview: PortablePackagePreview(
        packageName: 'Broken',
        createdAt: DateTime.now(),
        mediaCount: 0,
        folderCount: 0,
        fileCount: 0,
        totalBytes: 0,
        hasChecksums: false,
        formatVersion: PortableTransferService.formatVersion,
      ),
      deletePackageWhenDone: true,
    );
    await _waitForTask(task);
    expect(task.status, PortableTransferStatus.failed);
    expect(service.canRetry(task.id), true);
    await package.delete();
    await service.forgetStorageFiles([package.path]);
    expect(service.canRetry(task.id), false);
    expect(task.filePath, isNull);
    expect(task.subtitle, '文件已清理');
  });

  test(
    'failed snapshot import rolls back its partially created root',
    () async {
      final package = File(p.join(root.path, 'broken-hierarchy.fluentpack'));
      final encoder = ZipFileEncoder()..create(package.path);
      encoder.addArchiveFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode(<String, dynamic>{
            'format': 'fluent-player-portable-package',
            'formatVersion': PortableTransferService.formatVersion,
            'packageName': 'Must roll back',
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'mediaCount': 0,
            'folderCount': 1,
            'fileCount': 0,
            'totalBytes': 0,
            'checksums': <String, String>{},
            'snapshot': <String, dynamic>{
              'collections': <Map<String, dynamic>>[
                <String, dynamic>{
                  'exportId': 'child',
                  'parentExportId': 'missing-parent',
                  'name': 'Orphan folder',
                },
              ],
              'videos': <dynamic>[],
            },
          }),
        ),
      );
      await encoder.close();
      final preview = await service.inspectPackage(package.path);
      final task = await service.importPackage(
        library: library,
        packagePath: package.path,
        preview: preview,
      );

      await _waitForTask(task);

      expect(task.status, PortableTransferStatus.failed);
      expect(
        library.getContents(null).where((item) {
          return item is VideoCollection && item.name == 'Must roll back';
        }),
        isEmpty,
      );
      await service.removeTasks(<String>[task.id]);
    },
  );

  test(
    'startup recovers interrupted tasks and removes orphan artifacts',
    () async {
      final recoveryRoot = await Directory(
        p.join(root.path, 'restart-case'),
      ).create(recursive: true);
      PathProviderPlatform.instance = _FakePathProvider(recoveryRoot.path);
      addTearDown(() {
        PathProviderPlatform.instance = _FakePathProvider(root.path);
      });

      const importId = 'interrupted-import';
      const exportId = 'interrupted-export';
      final pickedDirectory = await Directory(
        p.join(recoveryRoot.path, 'picked_fluentpacks'),
      ).create(recursive: true);
      final retrySource = await File(
        p.join(pickedDirectory.path, 'retry.fluentpack'),
      ).writeAsString('retry source');
      final orphan = await File(
        p.join(pickedDirectory.path, 'orphan.fluentpack'),
      ).writeAsString('orphan');
      final extraction = await Directory(
        p.join(recoveryRoot.path, 'fluent_transfer', importId),
      ).create(recursive: true);
      await File(p.join(extraction.path, 'half-written')).writeAsString('data');
      final output = p.join(recoveryRoot.path, 'restart.fluentpack');
      final outputPart = await File('$output.part').writeAsString('partial');

      final stateDirectory = await Directory(
        p.join(recoveryRoot.path, 'portable_transfer'),
      ).create(recursive: true);
      final interruptedImport = PortableTransferTask(
        id: importId,
        kind: PortableTransferKind.import,
        title: 'Interrupted import',
        subtitle: 'running',
        createdAt: DateTime.now(),
        status: PortableTransferStatus.running,
        filePath: retrySource.path,
      );
      final interruptedExport = PortableTransferTask(
        id: exportId,
        kind: PortableTransferKind.export,
        title: 'Interrupted export',
        subtitle: 'running',
        createdAt: DateTime.now(),
        status: PortableTransferStatus.preparing,
        filePath: output,
      );
      await File(p.join(stateDirectory.path, 'tasks_v1.json')).writeAsString(
        jsonEncode(<String, dynamic>{
          'tasks': <Map<String, dynamic>>[
            interruptedImport.toJson(),
            interruptedExport.toJson(),
          ],
          'retrySpecs': <String, dynamic>{
            importId: <String, dynamic>{
              'kind': PortableTransferKind.import.name,
              'packagePath': retrySource.path,
              'deletePackageWhenDone': true,
            },
            exportId: <String, dynamic>{
              'kind': PortableTransferKind.export.name,
              'rootIds': <String>['video-id'],
              'outputPath': output,
              'options': const PortableExportOptions(
                packageName: 'Restart export',
              ).toJson(),
            },
          },
        }),
      );

      final recovered = PortableTransferService.forTesting();
      await recovered.initialize();

      expect(
        recovered.tasks.every(
          (task) => task.status == PortableTransferStatus.failed,
        ),
        isTrue,
      );
      expect(recovered.canRetry(importId), isTrue);
      expect(recovered.canRetry(exportId), isTrue);
      expect(await extraction.exists(), isFalse);
      expect(await outputPart.exists(), isFalse);
      expect(await retrySource.exists(), isTrue);
      expect(await orphan.exists(), isFalse);
    },
  );
}

Future<void> _waitForTask(PortableTransferTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (task.isActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(task.isActive, isFalse, reason: task.subtitle);
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;

  @override
  Future<String?> getDownloadsPath() async => rootPath;
}
