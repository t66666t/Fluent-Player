import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_video_shot.dart';
import 'package:video_player_app/widgets/bilibili_sprite_preview.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_shot_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sprite cell rect follows the image grid, not the preview box', () {
    final first = bilibiliSpriteCellRect(
      imageWidth: 1600,
      imageHeight: 900,
      columns: 10,
      rows: 10,
      column: 0,
      row: 0,
    );
    final later = bilibiliSpriteCellRect(
      imageWidth: 1600,
      imageHeight: 900,
      columns: 10,
      rows: 10,
      column: 3,
      row: 2,
    );

    expect(first.left, 0.5);
    expect(first.top, 0.5);
    expect(first.width, 159);
    expect(later.left, closeTo(480.5, 0.001));
    expect(later.top, closeTo(180.5, 0.001));
    expect(later.right, lessThan(640));
    expect(later.bottom, lessThan(270));
  });

  test('time index selects the correct sprite page, row and column', () {
    const shot = BilibiliVideoShot(
      spritePaths: <String>['first.jpg', 'second.jpg'],
      timestampsSeconds: <int>[0, 8, 14, 20, 30, 40, 50],
      columns: 3,
      rows: 2,
      cellWidth: 480,
      cellHeight: 270,
    );

    expect(shot.frameAt(0)?.spritePath, 'first.jpg');
    expect(shot.frameAt(19000)?.column, 2);
    expect(shot.frameAt(19000)?.row, 0);
    final secondPage = shot.frameAt(50000)!;
    expect(secondPage.spritePath, 'second.jpg');
    expect(secondPage.spriteIndex, 1);
    expect(secondPage.column, 0);
    expect(secondPage.row, 0);
  });

  test('video-shot metadata survives card persistence', () {
    final item = VideoItem(
      id: 'card',
      path: 'bilibili://stream/BV1test?cid=1',
      title: 'stream',
      durationMs: 1000,
      lastUpdated: 1,
      sourceRef: const MediaSourceRef(
        value: 'BV1test',
        kind: MediaSourceKind.bilibiliStream,
        bvid: 'BV1test',
        cid: 1,
      ),
      bilibiliVideoShot: const BilibiliVideoShot(
        spritePaths: <String>['C:/old/bilibili_videoshots/card/sprite.jpg'],
        timestampsSeconds: <int>[0, 8],
        columns: 10,
        rows: 10,
        cellWidth: 480,
        cellHeight: 270,
      ),
    );

    final restored = VideoItem.fromJson(item.toJson());

    expect(restored.bilibiliVideoShot?.timestampsSeconds, <int>[0, 8]);
    expect(restored.bilibiliVideoShot?.columns, 10);
    expect(restored.bilibiliVideoShot?.spritePaths, hasLength(1));
  });

  test(
    'sprite storage is counted, retained in recycle bin and permanently deleted',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      final root = await Directory.systemTemp.createTemp(
        'bilibili_video_shot_lifecycle_',
      );
      final originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      addTearDown(() async {
        PathProviderPlatform.instance = originalPathProvider;
        SettingsService().resetForTest();
        if (await root.exists()) await root.delete(recursive: true);
      });

      const videoId = 'shot-card';
      final mediaFile = File(p.join(root.path, 'video.mp4'));
      await mediaFile.writeAsBytes(List<int>.filled(23, 1));
      final spriteDirectory = Directory(
        p.join(root.path, BilibiliVideoShotService.directoryName, videoId),
      );
      await spriteDirectory.create(recursive: true);
      final spriteFile = File(p.join(spriteDirectory.path, 'sprite_000.jpg'));
      await spriteFile.writeAsBytes(List<int>.filled(41, 2));

      final library = LibraryService();
      await library.init();
      final item = VideoItem(
        id: videoId,
        path: mediaFile.path,
        title: 'downloaded Bilibili video',
        thumbnailPath: p.join(root.parent.path, 'external_thumb.jpg'),
        durationMs: 1000,
        lastUpdated: 1,
        isBilibiliExported: true,
        hasProbedChapters: true,
        bilibiliVideoShot: BilibiliVideoShot(
          spritePaths: <String>[spriteFile.path],
          timestampsSeconds: const <int>[0],
          columns: 10,
          rows: 10,
          cellWidth: 480,
          cellHeight: 270,
        ),
      );
      await library.addSingleVideo(item, useOriginalPath: true);

      expect(await library.calculateItemSize(item), 64);
      await library.moveToRecycleBin(<String>[videoId]);
      expect(await spriteFile.exists(), isTrue);

      await library.deleteFromRecycleBin(<String>[videoId]);
      expect(await spriteDirectory.exists(), isFalse);
    },
  );
}

class _FakePathProvider extends PathProviderPlatform {
  final String rootPath;

  _FakePathProvider(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;
}
