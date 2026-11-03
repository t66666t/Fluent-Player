import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/library_snapshot_reader.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/services/app_storage_service.dart';
import 'package:video_player_app/services/storage_migration_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox, support, documents, data, exe;
  late AppStorageService storage, previous;
  late StorageLocations locations;
  Future<File> file(String path, String text) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    return f.writeAsString(text, flush: true);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('fluent_upgrade_');
    support = await Directory(p.join(sandbox.path, 'support')).create();
    documents = await Directory(p.join(sandbox.path, 'documents')).create();
    data = await Directory(p.join(sandbox.path, 'data')).create();
    exe = await Directory(p.join(sandbox.path, 'program')).create();
    locations = StorageLocations(
      platform: StoragePlatform.windows,
      support: support,
      documents: documents,
      defaultData: data,
      executable: exe,
    );
    previous = AppStorageService.instance;
    storage = AppStorageService(locations: () async => locations);
    AppStorageService.instance = storage;
    StorageMigrationCoordinator.participants.clear();
    StorageMigrationCoordinator.maintenance = false;
    StorageMigrationCoordinator.preflight = null;
  });
  tearDown(() async {
    AppStorageService.instance = previous;
    StorageMigrationCoordinator.participants.clear();
    StorageMigrationCoordinator.maintenance = false;
    StorageMigrationCoordinator.preflight = null;
    await sandbox.delete(recursive: true);
  });
  Future<StorageMigrationResult> migrate(
    Directory target, {
    bool organize = false,
    Future<void> Function(String)? checkpoint,
    int space = 1 << 40,
  }) => StorageMigrationCoordinator(
    storage,
    availableBytes: (_) async => space,
    checkpoint: checkpoint,
  ).migrate(target, organize: organize);

  test(
    'fresh installations use a durable default on all five platforms',
    () async {
      for (final platform in StoragePlatform.values) {
        final root = Directory(p.join(sandbox.path, platform.name));
        final appSupport = await Directory(
          p.join(root.path, 'support'),
        ).create(recursive: true);
        final appDocs = await Directory(
          p.join(root.path, 'documents'),
        ).create();
        final durable = Directory(p.join(root.path, 'durable'));
        final service = AppStorageService(
          locations: () async => StorageLocations(
            platform: platform,
            support: appSupport,
            documents: appDocs,
            defaultData: durable,
            executable: exe,
          ),
        );
        await service.initialize();
        expect(service.dataDirectory.path, durable.path);
        expect(p.isWithin(exe.path, service.dataDirectory.path), isFalse);
        expect(
          (await service.downloadFiles('web')).path,
          p.join(durable.path, 'downloads', 'web', 'files'),
        );
      }
    },
  );
  test(
    'custom root and stable catalog survive executable relocation',
    () async {
      await file(p.join(data.path, 'library.json'), '{}');
      await storage.initialize(configuredRoot: data.path);
      locations = StorageLocations(
        platform: StoragePlatform.windows,
        support: support,
        documents: documents,
        defaultData: Directory(p.join(sandbox.path, 'other-default')),
        executable: Directory(p.join(sandbox.path, 'new-release')),
      );
      final updated = AppStorageService(locations: () async => locations);
      await updated.initialize();
      expect(updated.dataDirectory.path, data.path);
      expect(
        await File(p.join(data.path, 'library.json')).readAsString(),
        '{}',
      );
    },
  );
  test('existing legacy library is adopted without moving its bytes', () async {
    final legacy = await file(
      p.join(documents.path, 'library.json'),
      ' {"videos":[]} ',
    );
    await storage.initialize();
    expect(storage.dataDirectory.path, documents.path);
    expect(await legacy.readAsString(), ' {"videos":[]} ');
    expect(await File(p.join(data.path, 'library.json')).exists(), isFalse);
  });
  test('multiple historical libraries fail closed', () async {
    await file(p.join(documents.path, 'library.json'), '{}');
    await file(p.join(exe.path, 'VideoPlayerData', 'library.json'), '{}');
    await expectLater(
      storage.initialize(),
      throwsA(isA<StorageUnavailableException>()),
    );
    expect(await File(p.join(data.path, 'library.json')).exists(), isFalse);
  });
  test(
    'Linux recovery selects a library and its metadata without merging the other root',
    () async {
      final first = await file(
        p.join(support.path, 'library.json'),
        '{"videos":[]}',
      );
      final second = await file(
        p.join(documents.path, 'library.json'),
        '{"videos":[{"id":"chosen"}]}',
      );
      final tasks = await file(
        p.join(documents.path, 'bilibili_download_tasks.json'),
        '["preserved"]',
      );
      locations = StorageLocations(
        platform: StoragePlatform.linux,
        support: support,
        documents: documents,
        defaultData: data,
        executable: exe,
      );
      await expectLater(
        storage.initialize(),
        throwsA(isA<StorageSelectionRequiredException>()),
      );
      await storage.recoverWithRoot(documents);
      expect(storage.dataDirectory.path, documents.path);
      expect(storage.metadataDirectory.path, documents.path);
      expect(
        (await storage.dataRecord('bilibili_download_tasks.json')).path,
        tasks.path,
      );
      expect(await first.readAsString(), '{"videos":[]}');
      expect(await second.readAsString(), '{"videos":[{"id":"chosen"}]}');
      final restarted = AppStorageService(locations: () async => locations);
      await restarted.initialize();
      expect(restarted.metadataDirectory.path, documents.path);
    },
  );
  test(
    'missing registered disk does not create an empty replacement',
    () async {
      await storage.initialize(configuredRoot: data.path);
      await data.rename('${data.path}-offline');
      final updated = AppStorageService(locations: () async => locations);
      await expectLater(
        updated.initialize(),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(await data.exists(), isFalse);
    },
  );
  test('unreadable catalog and backup preserve all records', () async {
    await file(p.join(support.path, 'storage', 'layout.json'), 'broken');
    await file(
      p.join(support.path, 'storage', 'layout.json.bak'),
      'also broken',
    );
    await expectLater(
      storage.initialize(),
      throwsA(isA<StorageUnavailableException>()),
    );
    expect(
      await File(p.join(support.path, 'storage', 'layout.json')).readAsString(),
      'broken',
    );
  });
  test(
    'legacy web and Douyin journals remain discoverable after restart',
    () async {
      final web = await file(
        p.join(documents.path, 'web_media_downloads', 'queue_v2', 'index.json'),
        '{"version":2}',
      );
      final dy = await file(
        p.join(data.path, 'douyin_downloads', 'tasks.json'),
        '[]',
      );
      await storage.initialize(configuredRoot: data.path);
      expect(
        (await storage.downloadRecord(
          'web',
          'index.json',
          'web_media_downloads',
          legacyRelative: 'queue_v2/index.json',
        )).path,
        web.path,
      );
      expect(
        (await storage.downloadRecord(
          'douyin',
          'tasks.json',
          'douyin_downloads',
        )).path,
        dy.path,
      );
      final updated = AppStorageService(locations: () async => locations);
      await updated.initialize();
      expect(
        (await updated.downloadRecord(
          'web',
          'index.json',
          'web_media_downloads',
          legacyRelative: 'queue_v2/index.json',
        )).path,
        web.path,
      );
    },
  );
  test(
    'nested path references preserve external URIs, text and logical sources',
    () async {
      await storage.initialize();
      final local = p.join(data.path, 'subtitles', 'a.srt');
      final original = {
        'videos': [
          {
            'path': p.join(data.path, 'imported_media', '电影.mp4'),
            'bilibiliDownloadPath': p.join(
              data.path,
              'downloads',
              'bilibili',
              'files',
              'original.mp4',
            ),
            'managedSubtitleAssets': [
              {'path': local, 'wordTimingPath': '$local.json'},
            ],
            'additionalSubtitles': {'中文': local},
            'sourceRef': {'value': 'https://example.test/a'},
            'title': local,
            'url': 'content://provider/item',
            'external': p.join(sandbox.path, 'external.mp4'),
          },
        ],
      };
      final encoded = storage.encodePaths(original);
      expect(encoded['videos'][0]['_storagePaths'], isNotEmpty);
      expect(encoded['videos'][0]['_storagePaths']['bilibiliDownloadPath'], {
        'rootId': 'data',
        'relativePath': 'downloads/bilibili/files/original.mp4',
      });
      final replacement = await Directory(
        p.join(sandbox.path, 'moved'),
      ).create();
      await storage.commitRoot(replacement, {});
      final restored = storage.decodePaths(encoded)['videos'][0];
      expect(
        restored['bilibiliDownloadPath'],
        p.join(
          replacement.path,
          'downloads',
          'bilibili',
          'files',
          'original.mp4',
        ),
      );
      expect(
        restored['managedSubtitleAssets'][0]['path'],
        p.join(replacement.path, 'subtitles', 'a.srt'),
      );
      expect(
        restored['additionalSubtitles']['中文'],
        p.join(replacement.path, 'subtitles', 'a.srt'),
      );
      expect(restored['title'], local);
      expect(restored['url'], 'content://provider/item');
      expect(restored['external'], p.join(sandbox.path, 'external.mp4'));
      expect(restored['sourceRef']['value'], 'https://example.test/a');
    },
  );
  test('path refs reject traversal and absolute relative paths', () {
    for (final relative in ['../a', 'a/../../b', r'C:\escape', '/escape']) {
      expect(
        StoragePathRef.fromJson({'rootId': 'data', 'relativePath': relative}),
        isNull,
      );
    }
  });
  test(
    'restart restores Bilibili download provenance in already migrated libraries without path refs',
    () async {
      final media = await file(
        p.join(data.path, 'downloads', 'bilibili', 'files', 'original.mp4'),
        'the complete original media',
      );
      // Old releases saved this field as an absolute path without _storagePaths.
      // Migration preserves the JSON bytes and records aliases in the catalog.
      await file(
        p.join(data.path, 'library.json'),
        jsonEncode({
          'schemaVersion': 1,
          'videos': [
            {
              'id': 'download-card',
              'title': 'Downloaded media',
              'path': 'bilibili://stream/BV123?cid=42',
              'bilibiliDownloadPath': media.path,
              'playbackPath': media.path,
            },
          ],
          'collections': [],
          'rootChildrenIds': ['download-card'],
        }),
      );
      await storage.initialize(configuredRoot: data.path);
      final target = Directory(p.join(sandbox.path, 'moved'));
      await migrate(target);
      final finalTarget = Directory(p.join(sandbox.path, 'moved-again'));
      await migrate(finalTarget);
      final restarted = AppStorageService(locations: () async => locations);
      await restarted.initialize();
      final snapshot = await readLibrarySnapshot(
        p.join(finalTarget.path, 'library.json'),
        pathEncoding: restarted.capturePathEncoding(),
        maximumSchemaVersion: 100,
      );
      final item = snapshot.videos!['download-card']!;
      final expected = p.join(
        finalTarget.path,
        'downloads',
        'bilibili',
        'files',
        'original.mp4',
      );
      expect(item.playbackPath, expected);
      expect(item.bilibiliDownloadPath, expected);
      expect(
        await File(expected).readAsString(),
        'the complete original media',
      );
      expect(await media.exists(), isTrue);
      expect(item.path, 'bilibili://stream/BV123?cid=42');
    },
  );
  test('full migration keeps originals, SQLite and progress intact', () async {
    final media = await file(
      p.join(data.path, 'imported_videos', '片段.mp4'),
      'video-bytes',
    );
    await file(
      p.join(data.path, 'library.json'),
      jsonEncode({
        'videos': [
          {
            'id': 'old-id',
            'path': media.path,
            'lastPosition': 2300,
            'isFavorite': true,
          },
        ],
      }),
    );
    final dbFile = File(p.join(data.path, 'podcasts', 'podcasts.sqlite'));
    await dbFile.parent.create();
    final db = sqlite3.open(dbFile.path);
    db.execute('CREATE TABLE records (id TEXT, payload TEXT)');
    db.execute('INSERT INTO records VALUES (?,?)', [
      'episode',
      '{"played":true}',
    ]);
    db.dispose();
    await storage.initialize(configuredRoot: data.path);
    final target = Directory(p.join(sandbox.path, 'destination'));
    final result = await migrate(target);
    expect(result.files, 3);
    expect(await media.readAsString(), 'video-bytes');
    final loaded = storage.decodePaths(
      jsonDecode(
        await File(p.join(target.path, 'library.json')).readAsString(),
      ),
    );
    expect(loaded['videos'][0]['id'], 'old-id');
    expect(loaded['videos'][0]['lastPosition'], 2300);
    expect(
      loaded['videos'][0]['path'],
      p.join(target.path, 'imported_videos', '片段.mp4'),
    );
    final copied = sqlite3.open(
      p.join(target.path, 'podcasts', 'podcasts.sqlite'),
    );
    expect(
      copied.select('SELECT payload FROM records').single['payload'],
      '{"played":true}',
    );
    copied.dispose();
    expect(
      jsonDecode(await File(result.journal).readAsString())['phase'],
      'committed',
    );
  });
  test('organizing separates Bilibili from generic imported media', () async {
    final bb = await file(p.join(data.path, 'imported_videos', 'b站.mp4'), 'bb');
    final local = await file(
      p.join(data.path, 'imported_videos', 'local.mp3'),
      'local',
    );
    await file(
      p.join(data.path, 'library.json'),
      jsonEncode({
        'videos': [
          {
            'path': bb.path,
            'sourceRef': {'value': 'https://www.bilibili.com/video/BV123'},
          },
          {'path': local.path},
        ],
      }),
    );
    await storage.initialize(configuredRoot: data.path);
    await migrate(data, organize: true);
    final value = storage.decodePaths(
      jsonDecode(await File(p.join(data.path, 'library.json')).readAsString()),
    );
    expect(
      value['videos'][0]['path'],
      p.join(data.path, 'downloads', 'bilibili', 'files', 'b站.mp4'),
    );
    expect(
      value['videos'][1]['path'],
      p.join(data.path, 'imported_media', 'local.mp3'),
    );
    expect(await bb.exists(), isTrue);
    expect(await local.exists(), isTrue);
  });
  test('insufficient space never commits the target', () async {
    await file(p.join(data.path, 'library.json'), '{}');
    await storage.initialize();
    await expectLater(
      migrate(Directory(p.join(sandbox.path, 'target')), space: 0),
      throwsA(isA<StorageUnavailableException>()),
    );
    expect(storage.dataDirectory.path, data.path);
  });
  test(
    'interrupted verified copy can resume without modifying originals',
    () async {
      final original = await file(
        p.join(data.path, 'library.json'),
        '{"videos":[]}',
      );
      await storage.initialize(configuredRoot: data.path);
      final target = Directory(p.join(sandbox.path, 'target'));
      await expectLater(
        migrate(
          target,
          checkpoint: (phase) async {
            if (phase == 'verified') throw StateError('power loss');
          },
        ),
        throwsStateError,
      );
      expect(storage.dataDirectory.path, data.path);
      expect(await original.readAsString(), '{"videos":[]}');
      final updated = AppStorageService(locations: () async => locations);
      await updated.initialize();
      storage = updated;
      AppStorageService.instance = updated;
      await migrate(target);
      expect(updated.dataDirectory.path, target.path);
    },
  );
  test(
    'foreign target library, nested roots and build folders are rejected',
    () async {
      locations = StorageLocations(
        platform: StoragePlatform.windows,
        support: support,
        documents: documents,
        defaultData: data,
        executable: Directory(
          p.join(sandbox.path, 'build', 'windows', 'runner', 'Release'),
        ),
      );
      await storage.initialize();
      final target = Directory(p.join(sandbox.path, 'foreign'));
      await file(p.join(target.path, 'library.json'), '{"foreign":true}');
      for (final dir in [
        target,
        Directory(p.join(data.path, 'child')),
        Directory(p.join(sandbox.path, 'build', 'Release', 'data')),
      ]) {
        await expectLater(
          migrate(dir),
          throwsA(isA<StorageUnavailableException>()),
        );
      }
      expect(
        await File(p.join(target.path, 'library.json')).readAsString(),
        '{"foreign":true}',
      );
    },
  );
  test(
    'same-name files with different bytes preserve both and rebind refs',
    () async {
      final media = await file(
        p.join(data.path, 'imported_media', 'a.mp4'),
        'source',
      );
      await file(
        p.join(data.path, 'library.json'),
        jsonEncode({
          'videos': [
            {'path': media.path},
          ],
        }),
      );
      await storage.initialize();
      final target = Directory(p.join(sandbox.path, 'target'));
      final foreign = await file(
        p.join(target.path, 'imported_media', 'a.mp4'),
        'foreign',
      );
      await migrate(target);
      expect(await foreign.readAsString(), 'foreign');
      expect(
        await File(storage.restorePath(media.path)).readAsString(),
        'source',
      );
      expect(storage.restorePath(media.path), isNot(foreign.path));
    },
  );
  test(
    'shared Documents migration preserves external originals and references',
    () async {
      final original = await file(
        p.join(documents.path, 'personal movie.mp4'),
        'external',
      );
      final managed = await file(
        p.join(documents.path, 'imported_videos', 'managed.mp4'),
        'managed',
      );
      await file(
        p.join(documents.path, 'library.json'),
        jsonEncode({
          'videos': [
            {'path': original.path},
            {'path': managed.path},
          ],
        }),
      );
      await storage.initialize();
      final target = Directory(p.join(sandbox.path, 'new-library'));
      await migrate(target);
      final restored = storage.decodePaths(
        jsonDecode(
          await File(p.join(target.path, 'library.json')).readAsString(),
        ),
      );
      expect(restored['videos'][0]['path'], original.path);
      expect(await original.readAsString(), 'external');
      expect(
        await File(p.join(target.path, 'personal movie.mp4')).exists(),
        isFalse,
      );
      expect(
        restored['videos'][1]['path'],
        p.join(target.path, 'imported_videos', 'managed.mp4'),
      );
    },
  );
  test(
    'typed old-release fixtures preserve card IDs, folders, playback and subtitles',
    () async {
      final fixtures =
          jsonDecode(
                await File(
                  'test/fixtures/storage_upgrade/historical_libraries.json',
                ).readAsString(),
              )
              as List;
      final library = LibraryService();
      dynamic adapt(dynamic value) {
        if (value is String) return value.replaceAll('@DATA@', data.path);
        if (value is List) return value.map(adapt).toList();
        if (value is Map) return value.map((k, v) => MapEntry(k, adapt(v)));
        return value;
      }

      await storage.initialize(configuredRoot: data.path);
      await file(p.join(data.path, 'imported_videos', '中文 视频.mp4'), 'media');
      await file(
        p.join(data.path, 'subtitles', '中文.srt'),
        '1\n00:00:00,000 --> 00:00:01,000\n字幕\n',
      );
      SettingsService().largeDataRootPath = data.path;
      try {
        for (final fixture in fixtures) {
          library.resetLibraryForTesting();
          library.skipImportSidecarWorkForTesting = true;
          await file(
            p.join(data.path, 'library.json'),
            jsonEncode(adapt(fixture['library'])),
          );
          await library.init();
          final item = library.getVideo('old-video')!;
          expect(item.lastPositionMs, 23000, reason: fixture['tag']);
          expect(item.parentId, 'old-folder', reason: fixture['tag']);
          expect(library.getCollection('old-folder')!.name, '旧收藏');
          expect(await File(item.path).readAsString(), 'media');
          expect(await File(item.subtitlePath!).exists(), isTrue);
          await library.saveProgress();
          library.resetLibraryForTesting();
          library.skipImportSidecarWorkForTesting = true;
          await library.init();
          expect(library.getVideo('old-video')!.lastPositionMs, 23000);
        }
      } finally {
        library.resetLibraryForTesting();
        SettingsService().largeDataRootPath = null;
      }
    },
  );
  test(
    'a damaged primary JSON restores from backup without overwriting it',
    () async {
      final record = await file(p.join(data.path, 'tasks.json'), 'truncated');
      await file('${record.path}.bak', '[{"id":"keep"}]');
      expect((await readStorageJson(record) as List).single['id'], 'keep');
      await writeStorageJson(record, [
        {'id': 'new'},
      ]);
      expect(
        jsonDecode(
          await File('${record.path}.bak').readAsString(),
        ).single['id'],
        'keep',
      );
    },
  );
  test(
    'aliases across consecutive directory changes resolve to the latest file',
    () async {
      await storage.initialize();
      final a = p.join(data.path, 'imported_media', 'a.mp4');
      final b = p.join(sandbox.path, 'second', 'imported_media', 'a.mp4');
      final c = p.join(sandbox.path, 'third', 'imported_media', 'a.mp4');
      storage.aliases.addAll({a: b, b: c});
      expect(storage.restorePath(a), c);
    },
  );
  test(
    'legacy cookie-only profiles retain their original metadata location',
    () async {
      await file(
        p.join(documents.path, '.bilibili_cookies', 'cookies.json'),
        '{}',
      );
      await storage.initialize();
      expect(storage.metadataDirectory.path, documents.path);
    },
  );
  test(
    'a registered profile with a missing index never becomes an empty library',
    () async {
      final index = await file(p.join(data.path, 'library.json'), '{}');
      await storage.initialize();
      await index.delete();
      final updated = AppStorageService(locations: () async => locations);
      await expectLater(
        updated.initialize(),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(await index.exists(), isFalse);
    },
  );
  test(
    'known resume artifacts are promoted with verified bytes and original retained',
    () async {
      await storage.initialize();
      final source = await file(
        p.join(sandbox.path, 'old-cache', 'bbdown_task_video.m4s'),
        'resumable-bytes',
      );
      final target = await storage.downloadTasks('bilibili');
      final copied = await storage.retainTaskFile(source, target);
      expect(await copied.readAsString(), 'resumable-bytes');
      expect(await source.readAsString(), 'resumable-bytes');
      await copied.writeAsString('other-task-bytes');
      await expectLater(
        storage.retainTaskFile(source, target),
        throwsA(isA<StorageUnavailableException>()),
      );
      expect(await copied.readAsString(), 'other-task-bytes');
    },
  );
  test(
    'empty registered workspaces move with the root before their first task',
    () async {
      await storage.initialize();
      await storage.featureDirectory('cloud_drive_material');
      final target = Directory(p.join(sandbox.path, 'empty-moved'));
      await migrate(target);
      expect(
        (await storage.downloadRecord(
          'web',
          'index.json',
          'web_media_downloads',
        )).path,
        p.join(target.path, 'downloads', 'web', 'tasks', 'index.json'),
      );
      expect(
        (await storage.featureDirectory('cloud_drive_material')).path,
        p.join(target.path, 'cloud_drive_material'),
      );
    },
  );
  test(
    'all declared task and preview path references relocate together',
    () async {
      await storage.initialize();
      final record = storage.encodePaths({
        'request': {
          'outputDir': p.join(data.path, 'downloads', 'yt_dlp', 'files'),
        },
        'producedPaths': [
          p.join(data.path, 'downloads', 'yt_dlp', 'files', 'a.mp4'),
        ],
        'bilibiliVideoShot': {
          'spritePaths': [p.join(data.path, 'bilibili_videoshots', 'a.jpg')],
        },
        'sourceRef': {
          'value': 'https://remote.test',
          'path': p.join(data.path, 'remote-logical-path'),
        },
      });
      final next = await Directory(p.join(sandbox.path, 'replaced')).create();
      await storage.commitRoot(next, {});
      final restored = storage.decodePaths(record);
      expect(
        restored['request']['outputDir'],
        p.join(next.path, 'downloads', 'yt_dlp', 'files'),
      );
      expect(
        restored['producedPaths'].single,
        p.join(next.path, 'downloads', 'yt_dlp', 'files', 'a.mp4'),
      );
      expect(
        restored['bilibiliVideoShot']['spritePaths'].single,
        p.join(next.path, 'bilibili_videoshots', 'a.jpg'),
      );
      expect(
        restored['sourceRef']['path'],
        p.join(data.path, 'remote-logical-path'),
      );
    },
  );
  test(
    'empty legacy output directories and paused request refs are reorganized',
    () async {
      final empty = await Directory(
        p.join(data.path, 'yt_dlp_downloads'),
      ).create();
      await storage.initialize(configuredRoot: data.path);
      final request = storage.encodePaths({'outputDir': empty.path});
      await migrate(data, organize: true);
      expect(
        storage.decodePaths(request)['outputDir'],
        p.join(data.path, 'downloads', 'yt_dlp', 'files'),
      );
      expect(
        await Directory(
          p.join(data.path, 'downloads', 'yt_dlp', 'files'),
        ).exists(),
        isTrue,
      );
    },
  );
  test(
    'an unrelated user folder named build is not treated as program output',
    () async {
      await storage.initialize();
      final chosen = Directory(
        p.join(sandbox.path, 'personal', 'build', 'media'),
      );
      await storage.validateNewRoot(chosen);
      await storage.commitRoot(chosen, {});
      expect(storage.requiresBootstrapRelocation, isFalse);
    },
  );
  test(
    'case-only destination collisions preserve both media and file types',
    () async {
      final a = await file(
        p.join(data.path, 'douyin_downloads', 'Clip.mp4'),
        'first',
      );
      final b = await file(
        p.join(data.path, 'downloads', 'douyin', 'files', 'clip.mp4'),
        'second',
      );
      await file(
        p.join(data.path, 'library.json'),
        jsonEncode({
          'videos': [
            {'path': a.path},
            {'path': b.path},
          ],
        }),
      );
      await storage.initialize(configuredRoot: data.path);
      final target = Directory(p.join(sandbox.path, 'case-target'));
      await migrate(target, organize: true);
      final first = storage.restorePath(a.path),
          second = storage.restorePath(b.path);
      expect(first.toLowerCase(), isNot(second.toLowerCase()));
      expect(p.extension(first), '.mp4');
      expect(p.extension(second), '.mp4');
      expect(await File(first).readAsString(), 'first');
      expect(await File(second).readAsString(), 'second');
    },
  );
  test('iOS update rebases a previous container UUID', () async {
    locations = StorageLocations(
      platform: StoragePlatform.ios,
      support: support,
      documents: documents,
      defaultData: data,
      executable: exe,
    );
    await file(
      p.join(support.path, 'storage', 'layout.json'),
      jsonEncode({
        'version': 1,
        'dataRoot':
            '/private/var/mobile/Containers/Data/Application/OLD/Library/Application Support',
        'metadataRoot':
            '/private/var/mobile/Containers/Data/Application/OLD/Documents',
      }),
    );
    await storage.initialize();
    expect(storage.dataDirectory.path, support.path);
    expect(storage.metadataDirectory.path, documents.path);
    expect(
      storage.restorePath(
        '/private/var/mobile/Containers/Data/Application/OLD/Documents/imported_media/a.mp4',
      ),
      p.join(documents.path, 'imported_media/a.mp4'),
    );
  });
}
