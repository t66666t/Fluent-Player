import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_presentation.dart';

StorageFileEntry entry(
  String name,
  int bytes,
  StorageOrigin origin, {
  StorageCategory category = StorageCategory.streaming,
  StorageCleanupPolicy policy = StorageCleanupPolicy.regenerableCache,
  List<StorageOrigin> tags = const [],
  bool external = false,
  bool explicitDelete = false,
}) => StorageFileEntry(
  path: '/data/$name',
  rootPath: '/data',
  rootLabel: 'data',
  category: category,
  bytes: bytes,
  modifiedMicros: 1,
  changedMicros: 1,
  ownerIds: const [],
  ownerTitles: const [],
  canDelete: !explicitDelete,
  origin: origin,
  sourceTags: tags,
  cleanupPolicy: policy,
  external: external,
  explicitDelete: explicitDelete,
);

void main() {
  final snapshot = StorageSnapshot(
    scannedAt: DateTime(2026),
    roots: const [],
    warnings: const [],
    files: [
      entry('podcast.seg', 100, StorageOrigin.podcast),
      entry(
        'cover.jpg',
        20,
        StorageOrigin.shared,
        category: StorageCategory.thumbnails,
        tags: [StorageOrigin.podcast, StorageOrigin.cloudDrive],
      ),
      entry('cloud.bin', 200, StorageOrigin.cloudDrive),
      entry(
        'offline.mp3',
        300,
        StorageOrigin.podcast,
        category: StorageCategory.offlineDownloads,
        policy: StorageCleanupPolicy.savedContent,
        explicitDelete: true,
      ),
      entry(
        'lesson.fluentpack',
        400,
        StorageOrigin.localMedia,
        category: StorageCategory.transfer,
        policy: StorageCleanupPolicy.savedContent,
      ),
      entry('external.mp4', 800, StorageOrigin.localMedia, external: true),
    ],
  );

  test(
    'source summary, categories, cleanup and external files share one scope',
    () {
      final all = StorageView(snapshot, StorageSourceFilter.all);
      expect(all.bytes, 1020);
      expect(all.fileCount, 5);
      expect(all.cacheBytes, 320);
      expect(all.confirmationBytes, 700);
      expect(all.externalBytes, 800);
      expect(
        all.categories.fold<int>(0, (sum, usage) => sum + usage.bytes),
        all.bytes,
      );

      final podcast = StorageView(snapshot, StorageSourceFilter.podcast);
      expect(podcast.bytes, 420);
      expect(podcast.fileCount, 3);
      expect(podcast.cacheBytes, 120);
      expect(podcast.confirmationBytes, 300);
      expect(podcast.externalFiles, isEmpty);
      expect(podcast.cacheFiles.map((file) => file.path), [
        '/data/podcast.seg',
        '/data/cover.jpg',
      ]);

      final cloud = StorageView(snapshot, StorageSourceFilter.cloudDrive);
      expect(cloud.bytes, 220);
      expect(cloud.cacheBytes, 220);
      // Shared covers occur in both filters but the all-files total counts once.
      expect(StorageView(snapshot, StorageSourceFilter.shared).bytes, 20);
      expect(snapshot.appBytes, 1020);
    },
  );

  test('empty scope has no files or cleanup from other sources', () {
    final view = StorageView(snapshot, StorageSourceFilter.website);
    expect(view.bytes, 0);
    expect(view.fileCount, 0);
    expect(view.cacheFiles, isEmpty);
    expect(view.confirmationBytes, 0);
    expect(view.categories, isEmpty);
  });

  test(
    'saved resources without an available delete action are not offered for cleanup',
    () {
      final retained = StorageSnapshot(
        scannedAt: DateTime(2026),
        roots: const [],
        warnings: const [],
        files: [
          entry(
            'saved-cover.jpg',
            100,
            StorageOrigin.shared,
            category: StorageCategory.thumbnails,
            policy: StorageCleanupPolicy.savedContent,
            explicitDelete: true,
          ),
        ],
      );
      final view = StorageView(retained, StorageSourceFilter.all);
      expect(view.bytes, 100);
      expect(view.cacheBytes, 0);
      expect(view.confirmationBytes, 0);
      expect(storageNeedsConfirmation(retained.files.single), isFalse);
    },
  );

  test('every purpose belongs to one presentation section', () {
    expect(
      StorageCategory.values.map(storageSection).toSet(),
      StorageSection.values.toSet(),
    );
    expect(storageSection(StorageCategory.orphaned), StorageSection.review);
    expect(storageSection(StorageCategory.models), StorageSection.resources);
    expect(
      storageSection(StorageCategory.offlineDownloads),
      StorageSection.saved,
    );
  });
}
