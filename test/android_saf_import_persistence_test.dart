import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

class _AndroidPaths extends PathProviderPlatform {
  _AndroidPaths(this.documents, this.support, this.cache, this.externalCache);

  final Directory documents;
  final Directory support;
  final Directory cache;
  final Directory externalCache;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents.path;

  @override
  Future<String?> getApplicationSupportPath() async => support.path;

  @override
  Future<String?> getTemporaryPath() async => cache.path;

  @override
  Future<List<String>?> getExternalCachePaths() async => [externalCache.path];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = LibraryService();
  final settings = SettingsService();
  late Directory root;
  late Directory documents;
  late Directory cache;
  late Directory external;
  late PathProviderPlatform previousPaths;
  late AppStorageService previousStorage;
  late AppStorageService storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings.resetForTest();
    settings.copyImportedMediaToPrivateStorage = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    previousPaths = PathProviderPlatform.instance;
    previousStorage = AppStorageService.instance;
    root = await Directory.systemTemp.createTemp('android_saf_persistence_');
    documents = await Directory(
      p.join(root.path, 'app', 'documents'),
    ).create(recursive: true);
    final support = await Directory(
      p.join(root.path, 'app', 'support'),
    ).create();
    cache = await Directory(p.join(root.path, 'app', 'cache')).create();
    final externalCache = await Directory(
      p.join(root.path, 'external-cache'),
    ).create();
    external = await Directory(
      p.join(root.path, 'provider-originals'),
    ).create();
    PathProviderPlatform.instance = _AndroidPaths(
      documents,
      support,
      cache,
      externalCache,
    );
    storage = AppStorageService(
      locations: () async => StorageLocations(
        platform: StoragePlatform.android,
        support: support,
        documents: documents,
        defaultData: documents,
        cache: cache,
        executable: Directory(p.join(root.path, 'program')),
      ),
    );
    AppStorageService.instance = storage;
    await storage.initialize();
    settings.largeDataRootPath = documents.path;
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 120000;
    await library.init(deferMaintenance: true);
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    settings.resetForTest();
    await storage.releaseForegroundLease();
    AppStorageService.instance = previousStorage;
    PathProviderPlatform.instance = previousPaths;
    debugDefaultTargetPlatformOverride = null;
    // Every path above belongs to this test's newly allocated temporary root.
    await root.delete(recursive: true);
  });

  Future<File> original(String relative, List<int> bytes) async {
    final file = File(p.join(external.path, relative));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes, flush: true);
  }

  // This is the native pickFiles contract: a complete provider-owned byte
  // stream has been staged under cache/picked_media/<selection UUID>/name.
  // The native tests cover URI selection and never returning its raw path.
  Future<File> staged(File source, String selection) async {
    final file = File(
      p.join(cache.path, 'picked_media', selection, p.basename(source.path)),
    );
    await file.parent.create(recursive: true);
    return source.copy(file.path);
  }

  Future<void> restartLibrary() async {
    library.resetLibraryForTesting();
    library.skipImportSidecarWorkForTesting = true;
    library.probeMediaDurationOverrideForTesting = (_) => 120000;
    await library.init(deferMaintenance: true);
  }

  const captions = '1\n00:00:00,000 --> 00:02:00,000\n已授权的伴随字幕\n';

  test(
    'trusted picker source preserves matching subtitles as card-owned copies',
    () async {
      final source = await original('lesson/movie.mp4', [1, 3, 5, 7]);
      final subtitle = File(p.join(source.parent.path, 'movie.srt'));
      final english = File(p.join(source.parent.path, 'movie.en.srt'));
      final unrelated = File(p.join(source.parent.path, 'unrelated.srt'));
      await subtitle.writeAsString(captions);
      await english.writeAsString(
        captions.replaceFirst('已授权的伴随字幕', 'English captions'),
      );
      await unrelated.writeAsString(
        captions.replaceFirst('已授权的伴随字幕', 'Unrelated sentinel'),
      );
      final pick = await staged(source, 'selection-subtitles');

      final result = await library.importVideosBackground(
        [pick.path],
        null,
        sidecarSourcePaths: {pick.path: source.path},
      );

      final item = library.getVideo(result.createdVideoIds.single)!;
      expect(item.path, isNot(source.path));
      final owned = item.localSubtitles!.values.toSet();
      expect(owned, hasLength(2));
      expect(owned, contains(item.subtitlePath));
      expect(item.managedSubtitleAssets, hasLength(2));
      for (final path in owned) {
        expect(
          p.isWithin(
            p.join(documents.path, 'subtitles', 'tasks', item.id),
            path,
          ),
          isTrue,
        );
      }
      expect(await subtitle.readAsString(), captions);
      expect(await english.readAsString(), contains('English captions'));
      expect(await unrelated.readAsString(), contains('Unrelated sentinel'));
      expect(owned.map(p.basename), isNot(contains('unrelated.srt')));

      await external.rename(p.join(root.path, 'provider-no-longer-readable'));
      await cache.delete(recursive: true);
      await restartLibrary();
      final restored = library.getVideo(item.id)!;
      expect(restored.localSubtitles!.values.toSet(), owned);
      for (final path in owned) {
        expect(
          await File(path).readAsString(),
          isNot(contains('Unrelated sentinel')),
        );
      }
      expect(await File(restored.subtitlePath!).readAsString(), isNotEmpty);
    },
  );

  test(
    'invalid and missing hints do not prevent the selected media import',
    () async {
      final source = await original('movie.mp4', [4, 2, 4]);
      await File(p.join(external.path, 'movie.srt')).writeAsString(captions);
      final invalidHints = <String?>[
        null,
        'content://untrusted.provider/movie.mp4',
        'https://example.invalid/movie.mp4',
        'relative/movie.mp4',
        p.join(external.path, 'missing', '..', 'movie.mp4'),
      ];
      for (var i = 0; i < invalidHints.length; i++) {
        final pick = await staged(source, 'invalid-hint-$i');
        final hint = invalidHints[i];
        final result = await library.importVideosBackground(
          [pick.path],
          null,
          sidecarSourcePaths: hint == null ? const {} : {pick.path: hint},
        );
        final item = library.getVideo(result.createdVideoIds.single)!;
        expect(await File(item.path).readAsBytes(), [4, 2, 4]);
        expect(item.localSubtitles ?? {}, isEmpty);
        expect(item.subtitlePath, isNull);
      }
    },
  );

  test(
    'a non-cache media path cannot use a hint to scan another directory',
    () async {
      final source = await original('plain.mp4', [6, 1, 6]);
      final other = await original('unrelated/movie.mp4', [2, 3, 2]);
      await File(
        p.join(other.parent.path, 'movie.srt'),
      ).writeAsString(captions);

      final result = await library.importVideosBackground(
        [source.path],
        null,
        sidecarSourcePaths: {source.path: other.path},
      );

      final item = library.getVideo(result.createdVideoIds.single)!;
      expect(item.path, source.path);
      expect(item.localSubtitles ?? {}, isEmpty);
      expect(
        await File(p.join(other.parent.path, 'movie.srt')).readAsString(),
        captions,
      );
    },
  );

  test(
    'unavailable subtitle storage does not discard a successful media copy',
    () async {
      final source = await original('movie.mp4', [5, 8, 5]);
      final subtitle = File(p.join(external.path, 'movie.srt'));
      await subtitle.writeAsString(captions);
      final pick = await staged(source, 'selection-subtitle-volume-failed');
      final blocked = File(p.join(documents.path, 'subtitles', 'tasks'));
      await blocked.parent.create(recursive: true);
      await blocked.writeAsString('subtitle storage unavailable');

      final result = await library.importVideosBackground(
        [pick.path],
        null,
        sidecarSourcePaths: {pick.path: source.path},
      );

      final item = library.getVideo(result.createdVideoIds.single)!;
      expect(await File(item.path).readAsBytes(), [5, 8, 5]);
      expect(item.localSubtitles ?? {}, isEmpty);
      expect(await subtitle.readAsString(), captions);
      expect(await source.readAsBytes(), [5, 8, 5]);
    },
  );

  test(
    'cancel before publication releases only its unpublished owned copies',
    () async {
      final source = await original('movie.mp4', [1, 4, 1]);
      final subtitle = File(p.join(external.path, 'movie.srt'));
      await subtitle.writeAsString(captions);
      final pick = await staged(source, 'selection-cancel-before-commit');
      var checks = 0;

      final result = await library.importVideosBackground(
        [pick.path],
        null,
        sidecarSourcePaths: {pick.path: source.path},
        shouldContinue: () => ++checks == 1,
      );

      expect(result.createdVideoIds, isEmpty);
      expect(library.storageVideos, isEmpty);
      final tasks = Directory(p.join(documents.path, 'subtitles', 'tasks'));
      if (await tasks.exists()) {
        expect(
          await tasks
              .list(recursive: true)
              .where((file) => file is File)
              .toList(),
          isEmpty,
        );
      }
      expect(await pick.readAsBytes(), [1, 4, 1]);
      expect(await source.readAsBytes(), [1, 4, 1]);
      expect(await subtitle.readAsString(), captions);
      final imported = await storage.importedMediaDirectory();
      expect(
        await imported.list().where((file) => file is File).toList(),
        isEmpty,
      );
    },
  );

  test('cancel never deletes an already-managed media source', () async {
    final imported = await storage.importedMediaDirectory();
    final existing = await File(
      p.join(imported.path, 'previous.mp4'),
    ).writeAsBytes([9, 7, 9]);
    var checks = 0;

    final result = await library.importVideosBackground(
      [existing.path],
      null,
      shouldContinue: () => ++checks == 1,
    );

    expect(result.createdVideoIds, isEmpty);
    expect(library.storageVideos, isEmpty);
    expect(await existing.readAsBytes(), [9, 7, 9]);
  });

  test(
    'copy=false SAF imports survive provider loss, cache removal and reload',
    () async {
      final first = await original('one/中文 movie.mp4', [1, 2, 3, 4]);
      final second = await original('two/中文 movie.mp4', [8, 7, 6, 5]);
      final picks = [
        await staged(first, 'selection-a'),
        await staged(second, 'selection-b'),
      ];
      final result = await library.importVideosBackground(
        picks.map((file) => file.path).toList(),
        null,
        shouldCopy: false,
        useOriginalPath: false,
        allowCacheRescue: true,
      );
      expect(settings.copyImportedMediaToPrivateStorage, isFalse);
      expect(result.createdVideoIds, hasLength(2));
      final items = result.createdVideoIds.map(library.getVideo).toList();
      final imported = await storage.importedMediaDirectory();
      final paths = items.map((item) => item!.path).toList();
      expect(paths.toSet(), hasLength(2));
      for (final path in paths) {
        expect(p.isWithin(imported.path, path), isTrue);
      }
      expect(await File(paths[0]).readAsBytes(), [1, 2, 3, 4]);
      expect(await File(paths[1]).readAsBytes(), [8, 7, 6, 5]);
      expect(await first.readAsBytes(), [1, 2, 3, 4]);
      expect(await second.readAsBytes(), [8, 7, 6, 5]);
      for (final pick in picks) {
        expect(await pick.exists(), isFalse);
      }

      // The original raw paths now cease to exist, as when their broad access
      // disappears. The provider originals themselves remain untouched.
      final unavailable = await external.rename(
        p.join(root.path, 'provider-originals-unavailable'),
      );
      await cache.delete(recursive: true);
      await restartLibrary();
      for (var i = 0; i < result.createdVideoIds.length; i++) {
        expect(library.getVideo(result.createdVideoIds[i])!.path, paths[i]);
      }
      expect(await File(paths[0]).readAsBytes(), [1, 2, 3, 4]);
      expect(await File(paths[1]).readAsBytes(), [8, 7, 6, 5]);
      expect(
        await File(
          p.join(unavailable.path, 'one', '中文 movie.mp4'),
        ).readAsBytes(),
        [1, 2, 3, 4],
      );
    },
  );

  test(
    'failed library commit keeps picker bytes and the previous snapshot',
    () async {
      await library.saveLibraryForTesting();
      final index = File(p.join(documents.path, 'library.json'));
      final before = await index.readAsBytes();
      final source = await original('movie.mp4', [2, 4, 6, 8]);
      final pick = await staged(source, 'selection-failed-commit');
      library.writeLibrarySnapshotOverrideForTesting = () async =>
          throw const FileSystemException('simulated full volume');
      library.saveRetryDelaysForTesting = [];

      await library.importVideosBackground([pick.path], null);

      expect(library.hasPersistenceFailure, isTrue);
      expect(await index.readAsBytes(), before);
      expect(await pick.readAsBytes(), [2, 4, 6, 8]);
      expect(await source.readAsBytes(), [2, 4, 6, 8]);
      final privatePath = library.storageVideos.single.path;
      expect(await File(privatePath).readAsBytes(), [2, 4, 6, 8]);

      library.writeLibrarySnapshotOverrideForTesting = null;
      await library.retryLibraryPersistence();
      expect(library.hasPersistenceFailure, isFalse);
      await restartLibrary();
      expect(library.storageVideos.single.path, privatePath);
      expect(await File(privatePath).readAsBytes(), [2, 4, 6, 8]);
      expect(await source.readAsBytes(), [2, 4, 6, 8]);
    },
  );

  test(
    'failed private copy publishes no card and never releases picker bytes',
    () async {
      final source = await original('movie.mp4', [9, 3, 9]);
      final pick = await staged(source, 'selection-failed-copy');
      await File(
        p.join(documents.path, 'imported_media'),
      ).writeAsString('blocked');

      final result = await library.importVideosBackground([pick.path], null);

      expect(result.createdVideoIds, isEmpty);
      expect(result.failedCount, 1);
      expect(library.storageVideos, isEmpty);
      expect(await pick.readAsBytes(), [9, 3, 9]);
      expect(await source.readAsBytes(), [9, 3, 9]);
    },
  );

  test(
    'permanent deletion owns only the imported copy, never the provider original',
    () async {
      final source = await original('movie.mp4', [7, 7, 1]);
      final sentinel = await original('sentinel.txt', [8, 8, 8]);
      final pick = await staged(source, 'selection-delete');
      final result = await library.importVideosBackground([pick.path], null);
      final id = result.createdVideoIds.single;
      final privatePath = library.getVideo(id)!.path;
      expect(privatePath, isNot(source.path));

      await library.moveToRecycleBin([id]);
      expect(await File(privatePath).exists(), isTrue);
      await library.deleteFromRecycleBin([id]);

      expect(await File(privatePath).exists(), isFalse);
      expect(await source.readAsBytes(), [7, 7, 1]);
      expect(await sentinel.readAsBytes(), [8, 8, 8]);
    },
  );
}
