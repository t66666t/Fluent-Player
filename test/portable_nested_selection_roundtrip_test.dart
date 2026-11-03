import 'dart:async';
import 'dart:io';

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

  test(
    'nested partial export keeps folder path and omits unselected siblings',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'portable_nested_select_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        await deleteTestTempDir(root);
      });

      Future<File> media(String name) {
        return File(
          p.join(root.path, name),
        ).writeAsBytes(List<int>.generate(1024, (index) => index & 0xff));
      }

      final fileA = await media('clip-a.mp4');
      final fileB = await media('clip-b.mp4');
      final fileC = await media('clip-c.mp4');

      final library = LibraryService();
      await library.init();
      final course = await library.createCollection('嵌套选择课程', null);
      final lesson1 = await library.createCollection('第一课', course.id);
      final lesson2 = await library.createCollection('第二课', course.id);

      Future<VideoItem> addClip(
        File file,
        String title,
        String parentId,
      ) async {
        final item = VideoItem(
          id: 'nested-$title',
          path: file.path,
          title: title,
          durationMs: 1000,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          parentId: parentId,
        );
        await library.addSingleVideo(
          item,
          useOriginalPath: true,
          reuseExistingItem: false,
        );
        return library.getVideo(item.id)!;
      }

      final clipA = await addClip(fileA, '片段A-嵌套选择', lesson1.id);
      await addClip(fileB, '片段B-嵌套选择', lesson1.id);
      await addClip(fileC, '片段C-嵌套选择', lesson2.id);

      final packageName = '嵌套部分导出-${DateTime.now().microsecondsSinceEpoch}';
      final package = p.join(root.path, 'nested-select.fluentpack');
      final service = PortableTransferService.instance;
      final exportTask = await service.exportSelection(
        library: library,
        rootIds: <String>[clipA.id, lesson2.id],
        outputPath: package,
        options: PortableExportOptions(
          packageName: packageName,
          includeSidecars: false,
        ),
      );
      await _waitForTask(exportTask);
      expect(exportTask.status, PortableTransferStatus.completed);

      final preview = await service.inspectPackage(package);
      expect(preview.mediaCount, 2);
      expect(preview.folderCount, 3);

      final importTask = await service.importPackage(
        library: library,
        packagePath: package,
        preview: preview,
      );
      await _waitForTask(importTask);
      expect(importTask.status, PortableTransferStatus.completed);

      final packageRoot = library.collections.singleWhere(
        (item) => item.name == packageName,
      );
      final importedCourse = library
          .getContents(packageRoot.id)
          .whereType<VideoCollection>()
          .singleWhere((item) => item.name == '嵌套选择课程');
      final importedLesson1 = library
          .getContents(importedCourse.id)
          .whereType<VideoCollection>()
          .singleWhere((item) => item.name == '第一课');
      final importedLesson2 = library
          .getContents(importedCourse.id)
          .whereType<VideoCollection>()
          .singleWhere((item) => item.name == '第二课');

      final lesson1Videos = library
          .getContents(importedLesson1.id)
          .whereType<VideoItem>()
          .toList();
      final lesson2Videos = library
          .getContents(importedLesson2.id)
          .whereType<VideoItem>()
          .toList();
      expect(lesson1Videos.map((item) => item.title), ['片段A-嵌套选择']);
      expect(lesson2Videos.map((item) => item.title), ['片段C-嵌套选择']);
      expect(
        library
            .getContents(importedLesson1.id)
            .whereType<VideoItem>()
            .any((item) => item.title == '片段B-嵌套选择'),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'exporting only a nested folder imports it without outer shells',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'portable_nested_leaf_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        await deleteTestTempDir(root);
      });

      final clip = await File(p.join(root.path, 'clip-c.mp4')).writeAsBytes(
        List<int>.generate(1024, (index) => index & 0xff),
      );

      final library = LibraryService();
      await library.init();
      final course = await library.createCollection('嵌套选择课程', null);
      await library.createCollection('第一课', course.id);
      final lesson2 = await library.createCollection('第二课', course.id);
      await library.addSingleVideo(
        VideoItem(
          id: 'nested-leaf-c',
          path: clip.path,
          title: '片段C-仅深层文件夹',
          durationMs: 1000,
          lastUpdated: DateTime.now().millisecondsSinceEpoch,
          parentId: lesson2.id,
        ),
        useOriginalPath: true,
        reuseExistingItem: false,
      );

      final packageName = '深层文件夹导出-${DateTime.now().microsecondsSinceEpoch}';
      final package = p.join(root.path, 'nested-leaf.fluentpack');
      final service = PortableTransferService.instance;
      final exportTask = await service.exportSelection(
        library: library,
        rootIds: <String>[lesson2.id],
        outputPath: package,
        options: PortableExportOptions(
          packageName: packageName,
          includeSidecars: false,
        ),
      );
      await _waitForTask(exportTask);
      expect(exportTask.status, PortableTransferStatus.completed);

      final preview = await service.inspectPackage(package);
      expect(preview.mediaCount, 1);
      expect(preview.folderCount, 1);

      final importTask = await service.importPackage(
        library: library,
        packagePath: package,
        preview: preview,
      );
      await _waitForTask(importTask);
      expect(importTask.status, PortableTransferStatus.completed);

      final packageRoot = library.collections.singleWhere(
        (item) => item.name == packageName,
      );
      final importedTop = library
          .getContents(packageRoot.id)
          .whereType<VideoCollection>()
          .toList();
      expect(importedTop.map((item) => item.name), ['第二课']);
      expect(
        library
            .getContents(packageRoot.id)
            .whereType<VideoCollection>()
            .any((item) => item.name == '嵌套选择课程'),
        isFalse,
      );
      expect(
        library
            .getContents(importedTop.single.id)
            .whereType<VideoItem>()
            .map((item) => item.title),
        ['片段C-仅深层文件夹'],
      );
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

Future<void> _waitForTask(PortableTransferTask task) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (task.isActive && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  if (task.isActive) throw TimeoutException('portable task did not finish');
  if (task.status == PortableTransferStatus.failed) {
    fail(task.error ?? task.subtitle);
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
