import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  late Directory workspace;
  late Directory data;
  late Directory cache;
  late PathProviderPlatform originalProvider;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    workspace = await Directory.systemTemp.createTemp(
      'library_storage_accounting_',
    );
    data = await Directory(p.join(workspace.path, 'data')).create();
    cache = await Directory(p.join(workspace.path, 'cache')).create();
    originalProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Provider(data.path, cache.path);
    SettingsService().largeDataRootPath = data.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
  });
  tearDown(() async {
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = originalProvider;
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });
  Future<File> file(String path, int bytes) async {
    final result = File(path);
    await result.parent.create(recursive: true);
    await result.writeAsBytes(List.filled(bytes, 7));
    return result;
  }

  VideoItem video(
    String id,
    String path, {
    String? parentId,
    String? danmaku,
    String? thumbnail,
  }) => VideoItem(
    id: id,
    path: path,
    title: id,
    durationMs: 100,
    lastUpdated: 0,
    parentId: parentId,
    danmakuPath: danmaku,
    thumbnailPath: thumbnail,
    hasProbedChapters: true,
  );
  Future<void> load(
    List<VideoItem> videos, {
    List<VideoCollection> collections = const [],
  }) async {
    await File(p.join(data.path, 'library.json')).writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'videos': videos.map((v) => v.toJson()).toList(),
        'collections': collections.map((c) => c.toJson()).toList(),
        'rootChildrenIds': [
          ...videos.where((v) => v.parentId == null).map((v) => v.id),
          ...collections.where((c) => c.parentId == null).map((c) => c.id),
        ],
      }),
    );
    await library.init();
  }

  test(
    'selection counts shared media once, but a single owner cannot release it',
    () async {
      final shared = await file(
        p.join(data.path, 'imported_videos', 'shared.mp4'),
        80,
      );
      await load([video('a', shared.path), video('b', shared.path)]);
      expect(
        await library.calculateItemsTotalSize([library.getVideo('a')!]),
        0,
      );
      expect(
        await library.calculateItemsTotalSize([
          library.getVideo('a')!,
          library.getVideo('b')!,
        ]),
        80,
      );
    },
  );

  test(
    'folder and child selection includes recycled children without duplication',
    () async {
      final media = await file(
        p.join(data.path, 'imported_videos', 'a.mp4'),
        60,
      );
      final danmaku = await file(p.join(data.path, 'danmaku', 'a.ass'), 20);
      final thumbnail = await file(
        p.join(data.path, 'thumbnails', 'folder.jpg'),
        10,
      );
      final child = video(
        'a',
        media.path,
        parentId: 'folder',
        danmaku: danmaku.path,
      )..isRecycled = true;
      await load(
        [child],
        collections: [
          VideoCollection(
            id: 'folder',
            name: 'folder',
            createTime: 0,
            thumbnailPath: thumbnail.path,
            childrenIds: ['a'],
            isRecycled: true,
          ),
        ],
      );
      expect(
        await library.calculateItemsTotalSize([
          library.getCollection('folder')!,
          library.getVideo('a')!,
        ]),
        90,
      );
      expect(library.isStorageItemRecycled('a'), true);
    },
  );

  test(
    'last shared owner inside a permanently deleted folder releases the file',
    () async {
      final shared = await file(
        p.join(data.path, 'imported_videos', 'shared.mp4'),
        80,
      );
      await load(
        [
          video('a', shared.path, parentId: 'folder'),
          video('b', shared.path, parentId: 'folder'),
        ],
        collections: [
          VideoCollection(
            id: 'folder',
            name: 'folder',
            createTime: 0,
            childrenIds: ['a', 'b'],
            isRecycled: true,
          ),
        ],
      );
      await library.moveToRecycleBin(['folder']);
      await library.deleteFromRecycleBin(['folder']);
      expect(await shared.exists(), false);
      expect(library.getVideo('a'), isNull);
      expect(library.getVideo('b'), isNull);
    },
  );

  test(
    'external video and thumbnail remain after permanent card deletion',
    () async {
      final media = await file(p.join(workspace.path, 'external', 'a.mp4'), 60);
      final thumbnail = await file(
        p.join(workspace.path, 'external', 'a.jpg'),
        10,
      );
      await load([
        video('a', media.path, thumbnail: thumbnail.path)..isRecycled = true,
      ]);
      expect(await library.calculateItemSize(library.getVideo('a')!), 0);
      await library.moveToRecycleBin(['a']);
      await library.deleteFromRecycleBin(['a']);
      expect(await media.exists(), true);
      expect(await thumbnail.exists(), true);
    },
  );

  test(
    'private-copy import keeps existing app-owned media without another copy',
    () async {
      final media = await file(
        p.join(data.path, 'yt_dlp_downloads', 'a.mp4'),
        60,
      );
      await load([]);
      SettingsService().copyImportedMediaToPrivateStorage = true;
      final item = video('a', media.path);
      await library.addSingleVideo(item, useOriginalPath: true);
      expect(item.path, media.path);
      expect(
        await Directory(p.join(data.path, 'imported_videos')).exists(),
        false,
      );
      expect(await media.exists(), true);
    },
  );

  test('committed private import removes exact picker copy', () async {
    final media = await file(
      p.join(cache.path, 'file_picker', 'pick', 'a.mp4'),
      60,
    );
    final sibling = await file(p.join(media.parent.path, 'b.mp4'), 25);
    await load([]);
    SettingsService().copyImportedMediaToPrivateStorage = true;
    final item = video('a', media.path);
    await library.addSingleVideo(item, useOriginalPath: true);
    expect(p.isWithin(data.path, item.path), true);
    expect(await File(item.path).length(), 60);
    expect(await media.exists(), false);
    expect(await sibling.exists(), true);
  });

  test('failed library commit retains source picker media', () async {
    final media = await file(
      p.join(cache.path, 'file_picker', 'pick', 'a.mp4'),
      60,
    );
    await load([]);
    library.writeLibrarySnapshotOverrideForTesting = () async =>
        throw const FileSystemException('disk full');
    library.saveRetryDelaysForTesting = [];
    SettingsService().copyImportedMediaToPrivateStorage = true;
    final item = video('a', media.path);
    await library.addSingleVideo(item, useOriginalPath: true);
    expect(library.hasPersistenceFailure, true);
    expect(await media.exists(), true);
    expect(await File(item.path).length(), 60);
  });

  test(
    'shared legacy and task subtitles survive until their final owner',
    () async {
      final subtitle = await file(
        p.join(data.path, 'subtitles', 'tasks', 'a', 'shared.srt'),
        20,
      );
      final oldSubtitle = await file(
        p.join(data.path, 'subtitles', 'legacy.srt'),
        10,
      );
      final external = await file(
        p.join(workspace.path, 'external', 'external.srt'),
        15,
      );
      final a = video('a', 'missing-a.mp4')
        ..subtitlePath = subtitle.path
        ..secondarySubtitlePath = oldSubtitle.path;
      final b = video('b', 'missing-b.mp4')
        ..subtitlePath = subtitle.path
        ..secondarySubtitlePath = oldSubtitle.path
        ..localSubtitles = {'external': external.path};
      await load([a, b]);
      await library.moveToRecycleBin(['a']);
      await library.deleteFromRecycleBin(['a']);
      expect(await subtitle.exists(), true);
      expect(await oldSubtitle.exists(), true);
      await library.moveToRecycleBin(['b']);
      await library.deleteFromRecycleBin(['b']);
      expect(await subtitle.exists(), false);
      expect(await oldSubtitle.exists(), false);
      expect(await external.exists(), true);
    },
  );

  test(
    'shared collection cover survives until the last card or folder',
    () async {
      final cover = await file(
        p.join(data.path, 'thumbnails', 'shared.jpg'),
        10,
      );
      await load(
        [video('a', 'missing.mp4', thumbnail: cover.path)],
        collections: [
          VideoCollection(
            id: 'folder',
            name: 'folder',
            createTime: 0,
            thumbnailPath: cover.path,
          ),
        ],
      );
      await library.moveToRecycleBin(['folder']);
      await library.deleteFromRecycleBin(['folder']);
      expect(await cover.exists(), true);
      await library.moveToRecycleBin(['a']);
      await library.deleteFromRecycleBin(['a']);
      expect(await cover.exists(), false);
    },
  );

  test(
    'removing a folder releases a cover shared only by its children',
    () async {
      final cover = await file(
        p.join(data.path, 'thumbnails', 'shared.jpg'),
        10,
      );
      await load(
        [video('a', 'missing.mp4', parentId: 'folder', thumbnail: cover.path)],
        collections: [
          VideoCollection(
            id: 'folder',
            name: 'folder',
            createTime: 0,
            thumbnailPath: cover.path,
            childrenIds: ['a'],
          ),
        ],
      );
      await library.moveToRecycleBin(['folder']);
      await library.deleteFromRecycleBin(['folder']);
      expect(await cover.exists(), false);
    },
  );

  test(
    'importing shared legacy cache media keeps existing paths valid',
    () async {
      final source = await file(
        p.join(cache.path, 'file_picker', 'legacy.mp4'),
        25,
      );
      await load([video('existing', source.path)]);
      SettingsService().copyImportedMediaToPrivateStorage = false;
      final imported = video('new', source.path);
      await library.addSingleVideo(imported);
      expect(await source.exists(), true);
      expect(library.getVideo('existing')!.path, source.path);
      expect(imported.path, source.path);
    },
  );

  test(
    'a linked media directory cannot delete external originals',
    () async {
      final external = await file(
        p.join(workspace.path, 'outside', 'original.mp4'),
        60,
      );
      final alias = p.join(data.path, 'imported_videos');
      await Link(alias).create(external.parent.path);
      final path = p.join(alias, 'original.mp4');
      await load([video('a', path)]);
      expect(await library.calculateItemSize(library.getVideo('a')!), 0);
      await library.moveToRecycleBin(['a']);
      await library.deleteFromRecycleBin(['a']);
      expect(await external.exists(), true);
    },
    skip: Platform.isWindows
        ? 'Windows symlink creation needs Developer Mode or elevation'
        : false,
  );
}

class _Provider extends PathProviderPlatform {
  _Provider(this.data, this.cache);
  final String data;
  final String cache;
  @override
  Future<String?> getApplicationDocumentsPath() async => data;
  @override
  Future<String?> getApplicationSupportPath() async => data;
  @override
  Future<String?> getTemporaryPath() async => cache;
}
