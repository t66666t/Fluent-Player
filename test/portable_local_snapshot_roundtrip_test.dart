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
    'local snapshot restores empty folders and creates independent duplicate cards',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'portable_local_roundtrip_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        await deleteTestTempDir(root);
      });

      final media = await File(
        p.join(root.path, 'same-source.mp4'),
      ).writeAsBytes(List<int>.generate(2048, (index) => index & 0xff));
      final cover = await File(
        p.join(root.path, 'same-source.jpg'),
      ).writeAsString('cover');

      final library = LibraryService();
      await library.init();
      final sourceFolder = await library.createCollection('同名文件夹', null);
      await library.createCollection('空文件夹', sourceFolder.id);
      final original = VideoItem(
        id: 'original-local-card',
        path: media.path,
        title: '同名视频',
        thumbnailPath: cover.path,
        durationMs: 60000,
        lastPositionMs: 12000,
        lastUpdated: DateTime.now().millisecondsSinceEpoch,
        parentId: sourceFolder.id,
        hasProbedChapters: true,
      );
      await library.addSingleVideo(
        original,
        useOriginalPath: true,
        reuseExistingItem: false,
      );

      final package = p.join(root.path, 'local-snapshot.fluentpack');
      final service = PortableTransferService.instance;
      final exportTask = await service.exportSelection(
        library: library,
        rootIds: <String>[sourceFolder.id],
        outputPath: package,
        options: const PortableExportOptions(
          packageName: '本地快照',
          includeSidecars: true,
        ),
      );
      await _waitForTask(exportTask);
      expect(exportTask.status, PortableTransferStatus.completed);

      final preview = await service.inspectPackage(package);
      expect(preview.mediaCount, 1);
      expect(preview.folderCount, 2);
      final importTask = await service.importPackage(
        library: library,
        packagePath: package,
        preview: preview,
      );
      await _waitForTask(importTask);
      expect(importTask.status, PortableTransferStatus.completed);

      final videos = _allVideos(
        library,
      ).where((item) => item.title == '同名视频').toList();
      expect(videos, hasLength(2));
      expect(videos.map((item) => item.id).toSet(), hasLength(2));
      expect(
        videos.map((item) => p.normalize(item.path)).toSet(),
        hasLength(2),
      );
      final restored = videos.singleWhere((item) => item.id != original.id);
      expect(restored.lastPositionMs, original.lastPositionMs);
      expect(await File(restored.path).exists(), isTrue);

      final packageRoot = library.collections.singleWhere(
        (item) => item.name == '本地快照',
      );
      final importedFolder = library
          .getContents(packageRoot.id)
          .whereType<VideoCollection>()
          .singleWhere((item) => item.name == '同名文件夹');
      final restoredEmptyFolder = library
          .getContents(importedFolder.id)
          .whereType<VideoCollection>()
          .singleWhere((item) => item.name == '空文件夹');
      expect(library.getContents(restoredEmptyFolder.id), isEmpty);
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

List<VideoItem> _allVideos(LibraryService library) {
  final result = <VideoItem>[];
  void visit(String? parentId) {
    for (final item in library.getContents(parentId)) {
      if (item is VideoItem) {
        result.add(item);
      } else if (item is VideoCollection) {
        visit(item.id);
      }
    }
  }

  visit(null);
  return result;
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
