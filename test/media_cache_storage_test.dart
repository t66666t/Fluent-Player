import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';
import 'package:video_player_app/services/storage_contributors.dart';
import 'media_cache_service_test.dart' show source;

void main() {
  late Directory root, data;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('media_cache_storage_');
    data = Directory(p.join(root.path, 'library'))..createSync();
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  File write(String path, int bytes) {
    final file = File(path)..parent.createSync(recursive: true);
    file.writeAsBytesSync(List.filled(bytes, 7));
    return file;
  }

  Future<StorageSnapshot> scan({List<StorageAssetDescriptor> live = const []}) {
    final disk = inspectStorageFeatures(dataRoot: data);
    return scanStorageFiles(
      StorageScanInput(
        roots: [
          StorageRoot(data.path, '媒体库', StorageRootKind.data),
          ...disk.roots,
        ],
        assets: [...disk.assets, ...live],
        verifiedPaths: disk.verifiedPaths,
        warnings: disk.warnings,
      ),
    );
  }

  void index(List<CacheVariant> variants, List<CacheTask> tasks) =>
      File(p.join(data.path, 'media_cache.json')).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'tasks': tasks.map((t) => t.toJson()).toList(),
          'variants': variants.map((v) => v.toJson()).toList(),
        }),
      );

  test(
    'disk-only audit retains complete copies and valid paused breakpoints',
    () async {
      final output = write(
        p.join(
          data.path,
          'downloads',
          'bilibili',
          'files',
          'cache_finished.mp4',
        ),
        230,
      );
      final part = write(
        p.join(
          data.path,
          'downloads',
          'bilibili',
          'tasks',
          'cache_task',
          'video.part',
        ),
        91,
      );
      index(
        [
          CacheVariant(
            source: source(),
            quality: const CacheQuality(id: '1080', label: '1080P'),
            path: output.path,
            bytes: 230,
            createdAt: 1,
          ),
        ],
        [
          CacheTask(
            id: 'task',
            source: source(),
            createdAt: 1,
            state: CacheTaskState.paused,
            workDirectory: part.parent.path,
          ),
        ],
      );
      final snapshot = await scan();
      final complete = snapshot.files.singleWhere((f) => f.path == output.path);
      final partial = snapshot.files.singleWhere((f) => f.path == part.path);
      expect(complete.cleanupPolicy, StorageCleanupPolicy.savedContent);
      expect(complete.category, StorageCategory.offlineDownloads);
      expect(complete.canDelete, isFalse);
      expect(complete.explicitDelete, isTrue);
      expect(partial.role, StorageAssetRole.resumePart);
      expect(partial.canDelete, isFalse);
      expect(partial.explicitDelete, isTrue);
      expect(snapshot.files.where((f) => f.path == output.path), hasLength(1));
    },
  );

  test('a live writer overrides disk-only task ownership', () async {
    final part = write(
      p.join(
        data.path,
        'downloads',
        'cloud_drive',
        'tasks',
        'cache_task',
        'seg-0.part',
      ),
      99,
    );
    index([], [
      CacheTask(
        id: 'task',
        source: source(),
        createdAt: 1,
        state: CacheTaskState.paused,
        workDirectory: part.parent.path,
      ),
    ]);
    final snapshot = await scan(
      live: [
        StorageAssetDescriptor(
          assetKey: 'live',
          origin: StorageOrigin.cloudDrive,
          category: StorageCategory.downloadTemp,
          policy: StorageCleanupPolicy.protected,
          title: '正在缓存',
          directory: part.parent.path,
          protected: true,
          role: StorageAssetRole.resumePart,
        ),
      ],
    );
    final file = snapshot.files.singleWhere((f) => f.path == part.path);
    expect(file.cleanupPolicy, StorageCleanupPolicy.protected);
    expect(file.explicitDelete, isFalse);
  });

  test(
    'custom destinations enumerate only the registered media file',
    () async {
      final file = write(p.join(root.path, 'personal', 'cache_done.mp4'), 100);
      final unrelated = write(
        p.join(root.path, 'personal', 'holiday.mp4'),
        800,
      );
      index([
        CacheVariant(
          source: source(),
          quality: const CacheQuality(id: '80', label: '1080P'),
          path: file.path,
          bytes: 100,
          createdAt: 1,
        ),
      ], []);
      final snapshot = await scan();
      final entry = snapshot.files.singleWhere((f) => f.path == file.path);
      expect(entry.external, isFalse);
      expect(entry.explicitDelete, isTrue);
      expect(snapshot.files.any((f) => f.path == unrelated.path), isFalse);
    },
  );

  test(
    'corrupt index preserves unclassified owned downloads and uses backup',
    () async {
      final file = write(
        p.join(data.path, 'downloads', 'bilibili', 'files', 'cache_saved.mp4'),
        71,
      );
      final journal = File(p.join(data.path, 'media_cache.json'))
        ..writeAsStringSync('{broken');
      var snapshot = await scan();
      expect(
        snapshot.files.singleWhere((f) => f.path == file.path).canDelete,
        isFalse,
      );
      expect(snapshot.warnings.any((w) => w.contains('缓存索引无法读取')), isTrue);
      File('${journal.path}.bak').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'tasks': [],
          'variants': [
            CacheVariant(
              source: source(),
              quality: const CacheQuality(id: '80', label: '1080P'),
              path: file.path,
              bytes: 71,
              createdAt: 1,
            ).toJson(),
          ],
        }),
      );
      snapshot = await scan();
      expect(
        snapshot.files.singleWhere((f) => f.path == file.path).cleanupPolicy,
        StorageCleanupPolicy.savedContent,
      );
    },
  );
  test(
    'system URLSession staging is counted but cannot be purged as temporary cache',
    () async {
      final file = write(
        p.join(
          data.path,
          'Library',
          'Caches',
          'com.apple.nsurlsessiond',
          'Downloads',
          'CFNetworkDownload_test.tmp',
        ),
        900,
      );
      final snapshot = await scan();
      final entry = snapshot.files.singleWhere((f) => f.path == file.path);
      expect(entry.bytes, 900);
      expect(entry.canDelete, isFalse);
      expect(entry.explicitDelete, isFalse);
      expect(entry.cleanupPolicy, StorageCleanupPolicy.protected);
    },
  );
}
