import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

class _IosPaths extends PathProviderPlatform {
  _IosPaths(this.container);
  final Directory container;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      p.join(container.path, 'Documents');
  @override
  Future<String?> getApplicationSupportPath() async =>
      p.join(container.path, 'Library', 'Application Support');
  @override
  Future<String?> getTemporaryPath() async =>
      p.join(container.path, 'Library', 'Caches');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  late Directory sandbox;
  late Directory container;
  late AppStorageService previousStorage;
  late AppStorageService storage;
  late PathProviderPlatform previousPaths;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    // resetForTest resets initialization, not every mutable setting field.
    settings.copyImportedMediaToPrivateStorage = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    previousStorage = AppStorageService.instance;
    previousPaths = PathProviderPlatform.instance;
    sandbox = await Directory.systemTemp.createTemp('ios_import_cache_');
    container = await Directory(p.join(sandbox.path, 'container')).create();
    final support = await Directory(
      p.join(container.path, 'Library', 'Application Support'),
    ).create(recursive: true);
    final documents = await Directory(
      p.join(container.path, 'Documents'),
    ).create();
    final cache = await Directory(
      p.join(container.path, 'Library', 'Caches'),
    ).create();
    storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.ios,
        support: support,
        documents: documents,
        defaultData: support,
        cache: cache,
        executable: Directory(p.join(sandbox.path, 'program')),
      ),
    );
    AppStorageService.instance = storage;
    PathProviderPlatform.instance = _IosPaths(container);
    await storage.initialize();
    settings.largeDataRootPath = support.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    await library.init(deferMaintenance: true);
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    settings.resetForTest();
    await storage.releaseForegroundLease();
    AppStorageService.instance = previousStorage;
    PathProviderPlatform.instance = previousPaths;
    debugDefaultTargetPlatformOverride = null;
    await sandbox.delete(recursive: true);
  });

  Future<File> fixture(String relative) async {
    final file = File(p.join(container.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3, 4, 5]);
    return file;
  }

  Future<void> loadCommunityBesideLegacyDocuments(
    List<VideoItem> videos,
  ) async {
    library.resetLibraryForTesting();
    await storage.releaseForegroundLease();
    final documents = Directory(p.join(container.path, 'Documents'));
    await File(p.join(documents.path, 'library.json')).writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'videos': videos.map((item) => item.toJson()).toList(),
        'collections': [],
        'rootChildrenIds': videos.map((item) => item.id).toList(),
      }),
    );
    final support = await Directory(
      p.join(container.path, 'Library', 'legacy-layout-support'),
    ).create();
    storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.ios,
        support: support,
        documents: documents,
        defaultData: support,
        cache: Directory(p.join(container.path, 'Library', 'Caches')),
        executable: Directory(p.join(sandbox.path, 'program')),
      ),
    );
    AppStorageService.instance = storage;
    await storage.initialize();
    settings.largeDataRootPath = documents.path;
    library.skipImportSidecarWorkForTesting = true;
    await library.init(deferMaintenance: true);
    expect(storage.dataDirectory.path, support.path);
    expect(library.storageVideos, isEmpty);
  }

  VideoItem media(String id, String path, {String? subtitle, String? cover}) =>
      VideoItem(
        id: id,
        path: path,
        title: id,
        durationMs: 100,
        lastUpdated: 1,
        hasProbedChapters: true,
        subtitlePath: subtitle,
        thumbnailPath: cover,
      );

  for (final location in [
    p.join('tmp', 'incoming_media'),
    // file_picker's iOS implementation also returns NSTemporaryDirectory files.
    p.join('tmp', 'file_picker'),
    p.join('Library', 'Caches', 'incoming_media'),
  ]) {
    test(
      'default import persists $location and keeps the external original',
      () async {
        final source = await fixture(p.join(location, '中文 movie.mp4'));
        final original = await source.copy(
          p.join(sandbox.path, 'external-original.mp4'),
        );
        final sibling = await fixture(p.join(location, 'other.mp4'));
        expect(settings.copyImportedMediaToPrivateStorage, isFalse);
        await library.importVideosBackground([source.path], null);
        final item = library.storageVideos.single;
        // iOS keeps user media in Documents/imported_media; Application Support
        // contains the catalog and must not be mistaken for every managed asset.
        final imported = await storage.importedMediaDirectory();
        expect(p.isWithin(imported.path, item.path), isTrue);
        expect(await File(item.path).readAsBytes(), [1, 2, 3, 4, 5]);
        expect(await source.exists(), isFalse);
        expect(await sibling.exists(), isTrue);
        expect(await original.readAsBytes(), [1, 2, 3, 4, 5]);

        final savedPath = item.path;
        library.resetLibraryForTesting();
        library.skipImportSidecarWorkForTesting = true;
        await library.init(deferMaintenance: true);
        expect(library.storageVideos.single.path, savedPath);
        expect(await File(savedPath).readAsBytes(), [1, 2, 3, 4, 5]);
      },
    );
  }

  test(
    'failed library commit retains legacy iOS picker source and original',
    () async {
      final source = await fixture(
        p.join('tmp', 'incoming_media', 'movie.mp4'),
      );
      final original = await source.copy(p.join(sandbox.path, 'original.mp4'));
      library.writeLibrarySnapshotOverrideForTesting = () async =>
          throw const FileSystemException('simulated disk full');
      library.saveRetryDelaysForTesting = [];
      await library.importVideosBackground([source.path], null);
      expect(library.hasPersistenceFailure, isTrue);
      expect(await source.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(await original.readAsBytes(), [1, 2, 3, 4, 5]);
    },
  );

  test('ordinary iOS Documents media remains an external reference', () async {
    final source = await fixture(p.join('Documents', 'user-movie.mp4'));
    await library.importVideosBackground([source.path], null);
    expect(library.storageVideos.single.path, source.path);
    expect(await source.readAsBytes(), [1, 2, 3, 4, 5]);
  });

  test('private import reuses an existing iOS managed media file', () async {
    final directory = await storage.importedMediaDirectory();
    final source = await fixture(
      p.relative(p.join(directory.path, 'managed.mp4'), from: container.path),
    );
    settings.copyImportedMediaToPrivateStorage = true;
    await library.importVideosBackground([source.path], null);
    expect(library.storageVideos.single.path, source.path);
    expect(await directory.list().length, 1);
  });

  test(
    'iOS managed media is deleted only after its final card is removed',
    () async {
      final directory = await storage.importedMediaDirectory();
      final source = await fixture(
        p.relative(p.join(directory.path, 'managed.mp4'), from: container.path),
      );
      final original = await fixture(p.join('Documents', 'user-original.mp4'));
      await library.importVideosBackground([source.path, source.path], null);
      final ids = library.storageVideos.map((item) => item.id).toList();
      await library.moveToRecycleBin(ids);
      expect(await source.exists(), isTrue);
      await library.deleteFromRecycleBin([ids.first]);
      expect(await source.exists(), isTrue);
      await library.deleteFromRecycleBin([ids.last]);
      expect(await source.exists(), isFalse);
      expect(await original.readAsBytes(), [1, 2, 3, 4, 5]);
    },
  );

  test(
    'community data stays separate and deletion cannot touch a legacy Documents library',
    () async {
      final source = await fixture(p.join('Documents', 'user-movie.mp4'));
      final subtitle = await fixture(p.join('Documents', 'user-caption.srt'));
      final cover = await fixture(p.join('Documents', 'user-cover.jpg'));
      final managed = await fixture(
        p.join('Documents', 'imported_media', 'owned.mp4'),
      );
      await loadCommunityBesideLegacyDocuments([
        media(
          'external',
          source.path,
          subtitle: subtitle.path,
          cover: cover.path,
        ),
        media('managed', managed.path),
      ]);
      await library.moveToRecycleBin(['external', 'managed']);
      await library.deleteFromRecycleBin(['external', 'managed']);
      expect(await source.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(await subtitle.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(await cover.readAsBytes(), [1, 2, 3, 4, 5]);
      expect(await managed.exists(), isTrue);
      expect(
        await File(
          p.join(container.path, 'Documents', 'library.json'),
        ).exists(),
        isTrue,
      );
    },
  );

  test(
    'community import never moves an ordinary Documents original by default',
    () async {
      final source = await fixture(p.join('Documents', 'user-movie.mp4'));
      await loadCommunityBesideLegacyDocuments([]);
      expect(settings.copyImportedMediaToPrivateStorage, isFalse);
      final item = media('new-external', source.path);
      await library.addSingleVideo(item);
      expect(item.path, source.path);
      expect(await source.readAsBytes(), [1, 2, 3, 4, 5]);
    },
  );
}
