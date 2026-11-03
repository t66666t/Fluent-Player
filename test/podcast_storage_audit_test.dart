import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:video_player_app/features/podcasts/podcast_store.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';
import 'package:video_player_app/services/storage_contributors.dart';

void main() {
  late Directory workspace;
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('podcast_storage_audit_');
  });
  tearDown(() async {
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });

  Future<File> write(String path, List<int> bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<StorageSnapshot> scan(Directory data, {Directory? documents}) {
    final inspection = inspectStorageFeatures(
      dataRoot: data,
      historicalRoot: documents,
    );
    return scanStorageFiles(
      StorageScanInput(
        roots: [
          StorageRoot(data.path, '媒体库数据', StorageRootKind.data),
          if (documents != null)
            StorageRoot(
              documents.path,
              '历史文档目录',
              StorageRootKind.data,
              scoped: true,
            ),
          ...inspection.roots,
        ],
        assets: inspection.assets,
        verifiedPaths: inspection.verifiedPaths,
        warnings: inspection.warnings,
      ),
    );
  }

  test('scoped shared folder named podcasts is not an app directory', () async {
    final data = Directory(p.join(workspace.path, 'AppData'));
    final documents = Directory(p.join(workspace.path, 'Documents'));
    final store = PodcastStore.open(
      p.join(data.path, 'podcasts', 'podcasts.sqlite'),
    );
    store.write('asset', 'asset-a', {
      'id': 'asset-a',
      'episodeId': 'ep-a',
      'url': 'https://example.test/a.mp3',
      'revision': 0,
      'downloaded': false,
      'segments': {'0': 4},
      'total': 4,
    }, channel: 'ep-a');
    store.close();
    final owned = await write(
      p.join(data.path, 'podcasts', 'media', 'asset-a', '0-0.seg'),
      [1, 2, 3, 4],
    );
    final foreign = await write(
      p.join(documents.path, 'podcasts', 'media', 'asset-a', '0-0.seg'),
      [9, 9, 9, 9, 9],
    );
    final snapshot = await scan(data, documents: documents);
    final paths = snapshot.files.map((file) => file.path).toList();
    expect(paths, contains(owned.path));
    expect(paths, isNot(contains(foreign.path)));
    final entry = snapshot.files.singleWhere((file) => file.path == owned.path);
    expect(entry.external, isFalse);
    expect(entry.origin, StorageOrigin.podcast);
    expect(entry.category, StorageCategory.streaming);
    expect(entry.canDelete, isTrue);
    expect(
      snapshot.origins.fold<int>(0, (sum, origin) => sum + origin.bytes),
      snapshot.appBytes,
    );
    expect(
      snapshot.categories.fold<int>(0, (sum, category) => sum + category.bytes),
      snapshot.appBytes,
    );
  });

  test(
    'selected inspection keeps policy without visiting other episodes',
    () async {
      final data = Directory(p.join(workspace.path, 'library'));
      final podcast = Directory(p.join(data.path, 'podcasts'));
      final store = PodcastStore.open(p.join(podcast.path, 'podcasts.sqlite'));
      for (final id in ['selected', 'unrelated']) {
        store.write('asset', id, {
          'id': id,
          'episodeId': id,
          'url': 'https://example.test/$id.mp3',
          'revision': 0,
          'downloaded': id == 'unrelated',
          'segments': {'0': 3},
          'total': 3,
        });
      }
      store.close();
      final file = await write(
        p.join(podcast.path, 'media', 'selected', '0-0.seg'),
        [1, 2, 3],
      );
      final selected = inspectStorageFeatures(
        dataRoot: data,
        onlyPaths: [file.path],
      );
      final full = inspectStorageFeatures(dataRoot: data);
      final asset = selected.assets.singleWhere(
        (a) => a.assetKey == 'podcast:selected',
      );
      final original = full.assets.singleWhere(
        (a) => a.assetKey == asset.assetKey,
      );
      expect(asset.policy, original.policy);
      expect(asset.version, original.version);
      expect(
        selected.assets.any((a) => a.assetKey == 'podcast:unrelated'),
        isFalse,
      );
      expect(selected.warnings, isEmpty);
      expect(full.warnings, isNotEmpty);
    },
  );

  test('offline, retained and paused data stay out of cache cleanup', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final store = PodcastStore.open(
      p.join(data.path, 'podcasts', 'podcasts.sqlite'),
    );
    store.write('episode', 'ep', {
      'id': 'ep',
      'channelId': 'ch',
      'title': '试听节目',
    });
    store.write('channel', 'ch', {'id': 'ch', 'title': '频道'});
    store.write('asset', 'cached', {
      'id': 'cached',
      'episodeId': '',
      'url': 'https://example.test/preview.mp3',
      'revision': 0,
      'downloaded': false,
      'segments': {'0': 3},
      'total': 3,
    });
    store.write('asset', 'offline', {
      'id': 'offline',
      'episodeId': 'ep',
      'url': 'https://example.test/full.mp3',
      'revision': 1,
      'downloaded': true,
      'segments': {'0': 5},
      'total': 8,
      'assembled': 'complete-1.mp3',
    }, channel: 'ep');
    store.write('download', 'ep', {
      'episodeId': 'ep',
      'mediaUrl': 'https://example.test/full.mp3',
      'status': 'completed',
      'received': 8,
      'total': 8,
      'automatic': true,
    }, channel: 'ep');
    store.write('asset', 'paused', {
      'id': 'paused',
      'episodeId': 'ep2',
      'url': 'https://example.test/part.mp3',
      'revision': 0,
      'downloaded': false,
      'segments': {'0': 2},
      'total': 9,
    }, channel: 'ep2');
    store.write('download', 'ep2', {
      'episodeId': 'ep2',
      'mediaUrl': 'https://example.test/part.mp3',
      'status': 'paused',
      'received': 2,
      'total': 9,
    }, channel: 'ep2');
    store.write('state', 'ep3', {'retained': true});
    store.write('asset', 'kept', {
      'id': 'kept',
      'episodeId': 'ep3',
      'url': 'https://example.test/kept.mp3',
      'revision': 0,
      'downloaded': false,
      'segments': {'0': 2},
      'total': 2,
    }, channel: 'ep3');
    store.close();
    await write(
      p.join(data.path, 'podcasts', 'media', 'cached', '0-0.seg'),
      [1, 1, 1],
    );
    await write(
      p.join(data.path, 'podcasts', 'media', 'offline', '1-0.seg'),
      [1, 1, 1, 1, 1],
    );
    final complete = await write(
      p.join(data.path, 'podcasts', 'media', 'offline', 'complete-1.mp3'),
      [2, 2, 2, 2, 2, 2, 2, 2],
    );
    await write(
      p.join(data.path, 'podcasts', 'media', 'paused', '0-0.seg'),
      [3, 3],
    );
    await write(
      p.join(data.path, 'podcasts', 'media', 'kept', '0-0.seg'),
      [4, 4],
    );
    final snapshot = await scan(data);
    StorageFileEntry file(String name) => snapshot.files.firstWhere(
      (entry) => p.basename(entry.path) == name && entry.path.contains(name),
    );
    final cache = snapshot.files.firstWhere((entry) => entry.path.contains('cached'));
    expect(cache.category, StorageCategory.streaming);
    expect(cache.ownerTitles.single, contains('未订阅试听'));
    expect(cache.canDelete, isTrue);
    expect(
      storageDeletionPermitted(StorageCleanupAction.clearCache, cache),
      isTrue,
    );
    final offlineSeg = snapshot.files.firstWhere(
      (entry) => entry.path.endsWith('1-0.seg'),
    );
    final offlineFile = snapshot.files.firstWhere(
      (entry) => entry.path == complete.path,
    );
    expect(offlineSeg.category, StorageCategory.offlineDownloads);
    expect(offlineFile.category, StorageCategory.offlineDownloads);
    expect(offlineSeg.canDelete, isFalse);
    expect(offlineFile.explicitDelete, isTrue);
    expect(offlineSeg.bytes + offlineFile.bytes, 13);
    expect(
      storageDeletionPermitted(StorageCleanupAction.clearCache, offlineFile),
      isFalse,
    );
    final paused = snapshot.files.firstWhere((entry) => entry.path.contains('paused'));
    expect(paused.category, StorageCategory.downloadTemp);
    expect(
      storageDeletionPermitted(StorageCleanupAction.abandonResume, paused),
      isTrue,
    );
    expect(
      storageDeletionPermitted(StorageCleanupAction.clearCache, paused),
      isFalse,
    );
    final kept = snapshot.files.firstWhere((entry) => entry.path.contains('kept'));
    expect(kept.canDelete, isFalse);
    expect(kept.protection, contains('保留'));
    expect(file('podcasts.sqlite').category, StorageCategory.metadata);
    expect(file('podcasts.sqlite').canDelete, isFalse);
  });

  test('a live lease blocks one asset and index correction keeps the episode', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final databasePath = p.join(data.path, 'podcasts', 'podcasts.sqlite');
    final store = PodcastStore.open(databasePath);
    store.write('episode', 'ep', {
      'id': 'ep',
      'title': '保留节目',
      'channelId': 'ch',
    });
    store.write('asset', 'busy', {
      'id': 'busy',
      'episodeId': 'ep',
      'url': 'https://example.test/busy.mp3',
      'revision': 0,
      'downloaded': false,
      'segments': {'0': 2},
      'total': 2,
    }, channel: 'ep');
    store.write('asset', 'free', {
      'id': 'free',
      'episodeId': 'other',
      'url': 'https://example.test/free.mp3',
      'revision': 0,
      'downloaded': false,
      'segments': {'0': 2},
      'total': 2,
    });
    store.close();
    final busy = await write(
      p.join(data.path, 'podcasts', 'media', 'busy', '0-0.seg'),
      [1, 2],
    );
    final free = await write(
      p.join(data.path, 'podcasts', 'media', 'free', '0-0.seg'),
      [3, 4],
    );
    Future<StorageScanInput> input() async {
      final inspection = inspectStorageFeatures(dataRoot: data);
      return StorageScanInput(
        roots: [
          StorageRoot(data.path, '媒体库数据', StorageRootKind.data),
          ...inspection.roots,
        ],
        assets: inspection.assets,
        verifiedPaths: inspection.verifiedPaths,
        warnings: inspection.warnings,
      );
    }

    final audit = StorageAuditService(
      buildInput: input,
      deletionBlockedReason: () => null,
      correctIndexes: (paths) =>
          correctDeletedStorageFiles(dataRoot: data, deletedPaths: paths),
    );
    addTearDown(audit.dispose);
    final first = await audit.scan();
    final background = sqlite3.open(databasePath);
    background.execute(
      "INSERT INTO records(kind,id,channel,payload) VALUES('assetLease','busy','ep',?)",
      [
        jsonEncode({
          'owner': 'background',
          'until': DateTime.now().millisecondsSinceEpoch + 60000,
        }),
      ],
    );
    background.dispose();
    final result = await audit.delete(
      StorageDeletionPlan(
        first.files.where((file) => file.canDelete).toList(),
        action: StorageCleanupAction.clearCache,
      ),
    );
    expect(await busy.exists(), isTrue);
    expect(result.skipped[busy.path], isNotNull);
    expect(await free.exists(), isFalse);
    final reread = PodcastStore.open(databasePath);
    final episode = reread.read('episode', 'ep');
    final asset = reread.read('asset', 'free');
    reread.close();
    expect(episode?['title'], '保留节目');
    expect(asset?['segments'], isEmpty);
    expect(asset?['downloaded'], isFalse);
  });

  test('unreadable and newer podcast indexes are not treated as unreferenced', () async {
    final data = Directory(p.join(workspace.path, 'library'));
    final database = File(p.join(data.path, 'podcasts', 'podcasts.sqlite'));
    await database.parent.create(recursive: true);
    await database.writeAsString('not-sqlite');
    final segment = await write(
      p.join(data.path, 'podcasts', 'media', 'asset', '0-0.seg'),
      [1, 2, 3],
    );
    final broken = await scan(data);
    expect(broken.warnings, isNotEmpty);
    expect(
      broken.files.firstWhere((file) => file.path == segment.path).canDelete,
      isFalse,
    );

    final newer = Directory(p.join(workspace.path, 'newer', 'podcasts'));
    await newer.create(recursive: true);
    final db = sqlite3.open(p.join(newer.path, 'podcasts.sqlite'));
    db.execute('PRAGMA user_version=99');
    db.execute(
      'CREATE TABLE records (kind TEXT, id TEXT, channel TEXT, payload TEXT)',
    );
    db.dispose();
    final file = await write(
      p.join(newer.parent.path, 'podcasts', 'media', 'asset', '0-0.seg'),
      [4],
    );
    final unknown = await scan(Directory(newer.parent.path));
    expect(unknown.warnings.join('\n'), contains('无法识别'));
    expect(
      unknown.files.firstWhere((entry) => entry.path == file.path).canDelete,
      isFalse,
    );
  });

  test('duplicate roots and real copies are counted once per path', () async {
    final data = Directory(p.join(workspace.path, 'LibraryData'));
    await data.create(recursive: true);
    final file = await write(p.join(data.path, 'note.txt'), [1, 2, 3, 4]);
    final copy = await write(p.join(data.path, 'copy.txt'), [1, 2, 3, 4]);
    final snapshot = await scanStorageFiles(
      StorageScanInput(
        roots: [
          StorageRoot(data.path, '数据', StorageRootKind.data),
          StorageRoot(data.path.toUpperCase(), '数据大写', StorageRootKind.data),
        ],
      ),
    );
    expect(snapshot.files, hasLength(2));
    expect(snapshot.appBytes, file.lengthSync() + copy.lengthSync());
  });
}
