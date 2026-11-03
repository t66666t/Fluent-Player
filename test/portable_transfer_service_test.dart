import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/portable_transfer/portable_transfer_models.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'test_dir_cleanup.dart';

void main() {
  group('PortableTransferService package inspection', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('fluentpack_test_');
    });

    tearDown(() async {
      await deleteTestTempDir(tempDir);
    });

    test('reads a valid cross-platform package manifest', () async {
      final package = File(p.join(tempDir.path, 'sample.fluentpack'));
      final encoder = ZipFileEncoder()..create(package.path);
      encoder.addArchiveFile(
        ArchiveFile.string(
          'Sample/manifest.json',
          jsonEncode({
            'format': 'fluent-player-portable-package',
            'formatVersion': PortableTransferService.formatVersion,
            'packageName': '我的媒体',
            'createdAt': '2026-09-16T10:00:00.000Z',
            'mediaCount': 3,
            'folderCount': 1,
            'fileCount': 4,
            'totalBytes': 2048,
            'checksums': {'Sample/video.mp4': 'digest'},
          }),
        ),
      );
      await encoder.close();

      final preview = await PortableTransferService.instance.inspectPackage(
        package.path,
      );

      expect(preview.packageName, '我的媒体');
      expect(preview.mediaCount, 3);
      expect(preview.folderCount, 1);
      expect(preview.totalBytes, 2048);
      expect(preview.hasChecksums, isTrue);
    });

    test('rejects an unrelated zip renamed as fluentpack', () async {
      final package = File(p.join(tempDir.path, 'not-ours.fluentpack'));
      final encoder = ZipFileEncoder()..create(package.path);
      encoder.addArchiveFile(ArchiveFile.string('hello.txt', 'hello'));
      await encoder.close();

      expect(
        () => PortableTransferService.instance.inspectPackage(package.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a valid package with a non-fluentpack extension', () async {
      final package = File(p.join(tempDir.path, 'wrong-extension.zip'));
      final encoder = ZipFileEncoder()..create(package.path);
      encoder.addArchiveFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'format': 'fluent-player-portable-package',
            'formatVersion': PortableTransferService.formatVersion,
            'packageName': 'Wrong extension',
          }),
        ),
      );
      await encoder.close();

      expect(
        () => PortableTransferService.instance.inspectPackage(package.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('accepts fluentpack extension case-insensitively', () {
      expect(
        PortableTransferService.hasPackageExtension('Backup.FLUENTPACK'),
        isTrue,
      );
      expect(
        PortableTransferService.hasPackageExtension('Backup.fluentpack.zip'),
        isFalse,
      );
    });

    test('rejects packages created by a newer format version', () async {
      final package = File(p.join(tempDir.path, 'future.fluentpack'));
      final encoder = ZipFileEncoder()..create(package.path);
      encoder.addArchiveFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'format': 'fluent-player-portable-package',
            'formatVersion': PortableTransferService.formatVersion + 1,
            'packageName': 'Future',
          }),
        ),
      );
      await encoder.close();

      expect(
        () => PortableTransferService.instance.inspectPackage(package.path),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('PortableTransferService task removal', () {
    late Directory tempDir;
    final service = PortableTransferService.instance;

    setUp(() async {
      service.clearFinished();
      tempDir = await Directory.systemTemp.createTemp('transfer_remove_test_');
    });

    tearDown(() async {
      service.clearFinished();
      await deleteTestTempDir(tempDir);
    });

    test('deletes the linked file by default', () async {
      final linkedFile = File(p.join(tempDir.path, 'linked.fluentpack'));
      await linkedFile.writeAsString('keep until task removal');
      final task = await service.exportSelection(
        library: LibraryService(),
        rootIds: const <String>['missing-item'],
        outputPath: linkedFile.path,
        options: const PortableExportOptions(packageName: '删除文件'),
      );
      await _waitUntilFinished(task);

      final result = await service.removeTasks(<String>[task.id]);

      expect(result.removedTaskCount, 1);
      expect(result.deletedFileCount, 1);
      expect(result.failedFilePaths, isEmpty);
      expect(await linkedFile.exists(), isFalse);
    });

    test('can remove only the task record and keep the file', () async {
      final linkedFile = File(p.join(tempDir.path, 'kept.fluentpack'));
      await linkedFile.writeAsString('keep me');
      final task = await service.exportSelection(
        library: LibraryService(),
        rootIds: const <String>['missing-item'],
        outputPath: linkedFile.path,
        options: const PortableExportOptions(packageName: '保留文件'),
      );
      await _waitUntilFinished(task);

      final result = await service.removeTasks(<String>[
        task.id,
      ], deleteFiles: false);

      expect(result.removedTaskCount, 1);
      expect(result.deletedFileCount, 0);
      expect(await linkedFile.exists(), isTrue);
    });
  });
}

Future<void> _waitUntilFinished(PortableTransferTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (task.isActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(task.isActive, isFalse);
}
