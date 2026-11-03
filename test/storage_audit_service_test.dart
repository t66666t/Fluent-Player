import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/services/storage_audit_models.dart';
import 'package:video_player_app/services/storage_audit_service.dart';

import 'support/storage_directory_alias.dart';

void main() {
  late Directory workspace;
  late Directory data;
  late Directory cache;
  final services = <StorageAuditService>[];
  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('storage_audit_test_');
    data = await Directory(p.join(workspace.path, 'data')).create();
    cache = await Directory(p.join(workspace.path, 'cache')).create();
  });
  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    services.clear();
    if (await workspace.exists()) await workspace.delete(recursive: true);
  });
  Future<File> write(String path, int size) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(size, 1));
    return file;
  }

  StorageScanInput input({
    List<StorageReference> refs = const [],
    List<String> protected = const [],
    List<String> filePrefixes = const [],
  }) => StorageScanInput(
    roots: [
      StorageRoot(data.path, 'data', StorageRootKind.data),
      StorageRoot(cache.path, 'cache', StorageRootKind.cache),
    ],
    references: refs,
    protectedPaths: protected,
    protectedFilePrefixes: filePrefixes,
  );
  StorageAuditService service(
    Future<StorageScanInput> Function() builder, {
    String? Function()? blocked,
  }) {
    final result = StorageAuditService(
      buildInput: builder,
      deletionBlockedReason: blocked ?? () => null,
    );
    services.add(result);
    return result;
  }

  test(
    'finished fluentpack is clearable immediately in private roots',
    () async {
      final package = await write(
        p.join(data.path, 'portable_transfer', 'lesson.FLUENTPACK'),
        42,
      );
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [StorageRoot(data.path, 'data', StorageRootKind.data)],
          minimumTemporaryAge: const Duration(minutes: 10),
        ),
      );
      final entry = snapshot.files.single;
      expect(entry.category, StorageCategory.transfer);
      expect(entry.canDelete, true);
      final audit = service(() async => input());
      final result = await audit.delete(StorageDeletionPlan([entry]));
      expect(result.deletedPaths, [package.path]);
      expect(audit.lastSnapshot!.appBytes, 0);
    },
  );

  test(
    'fluentpack extension does not grant access to shared documents',
    () async {
      await write(p.join(data.path, 'personal.fluentpack'), 15);
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(
              data.path,
              'shared',
              StorageRootKind.data,
              scoped: true,
            ),
          ],
        ),
      );
      expect(snapshot.files, isEmpty);
    },
  );

  test(
    'resumable folder delivery is protected and inactive remnants are clearable',
    () async {
      final active = await write(
        p.join(
          data.path,
          'portable_transfer',
          'nearby',
          'active-task',
          'incoming.fluentpack.part',
        ),
        42,
      );
      final inactive = await write(
        p.join(
          data.path,
          'portable_transfer',
          'nearby',
          'old-task',
          'receive.json',
        ),
        20,
      );
      final receipts = await write(
        p.join(data.path, 'portable_transfer', 'folder_receipts_v1.json'),
        10,
      );
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [StorageRoot(data.path, 'data', StorageRootKind.data)],
          minimumTemporaryAge: Duration.zero,
          protectedPrefixes: [active.parent.path],
        ),
      );
      final entries = {for (final entry in snapshot.files) entry.path: entry};
      expect(entries[active.path]!.category, StorageCategory.transfer);
      expect(entries[active.path]!.canDelete, isFalse);
      expect(entries[inactive.path]!.category, StorageCategory.transfer);
      expect(entries[inactive.path]!.canDelete, isTrue);
      expect(entries[receipts.path]!.category, StorageCategory.metadata);
      expect(entries[receipts.path]!.canDelete, isFalse);
    },
  );

  test(
    'fluentpack extension does not unlock an ambiguous shared picker cache',
    () async {
      await write(
        p.join(cache.path, 'file_picker', 'other-app.fluentpack'),
        15,
      );
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(
              cache.path,
              'shared temp',
              StorageRootKind.cache,
              scoped: true,
            ),
          ],
        ),
      );
      expect(snapshot.files.single.canDelete, false);
      expect(snapshot.files.single.protection, contains('共享临时目录'));
    },
  );

  test('targeted ownership check only examines the requested file', () async {
    final selected = await write(
      p.join(data.path, 'imported_videos', 'selected.mp4'),
      20,
    );
    await write(p.join(data.path, 'imported_videos', 'sibling.mp4'), 30);
    final snapshot = await scanStorageFiles(
      input(protected: [selected.path]),
      onlyPaths: [selected.path],
    );
    expect(snapshot.files.single.path, selected.path);
    expect(snapshot.files.single.canDelete, false);
    expect(snapshot.appBytes, 20);
  });

  test(
    'selected cleanup accepts canonical files under an aliased root',
    () async {
      final file = await write(p.join(cache.path, 'ytdlp_selected.mp4'), 20);
      final alias = p.join(workspace.path, 'cache-alias');
      await createStorageDirectoryAlias(alias, cache.path);
      try {
        final audit = service(
          () async => StorageScanInput(
            roots: [StorageRoot(alias, 'aliased cache', StorageRootKind.cache)],
          ),
        );
        final snapshot = await audit.scan();
        expect(
          storagePathKey(snapshot.files.single.path),
          storagePathKey(file.path),
        );
        final result = await audit.delete(StorageDeletionPlan(snapshot.files));
        expect(result.deletedPaths, [snapshot.files.single.path]);
        expect(await file.exists(), isFalse);
      } finally {
        await Link(alias).delete();
      }
    },
  );

  test(
    'cleanup uses selected input and preserves the full inventory',
    () async {
      final selected = await write(
        p.join(cache.path, 'ytdlp_selected.mp4'),
        20,
      );
      final other = await write(p.join(data.path, 'library.json'), 30);
      var fullBuilds = 0;
      var selectedBuilds = 0;
      var guards = 0;
      final audit = StorageAuditService(
        buildInput: () async {
          fullBuilds++;
          if (fullBuilds > 1) throw StateError('cleanup requested a full scan');
          return input();
        },
        buildDeletionInput: (paths) async {
          selectedBuilds++;
          expect(paths, [selected.path]);
          return input();
        },
        fileDeletionBlockedReason: (_) {
          guards++;
          return null;
        },
        deletionBlockedReason: () => null,
      );
      services.add(audit);
      final snapshot = await audit.scan();
      final result = await audit.delete(
        StorageDeletionPlan([
          snapshot.files.singleWhere((file) => file.path == selected.path),
        ]),
      );
      expect(result.deletedPaths, [selected.path]);
      expect(fullBuilds, 1);
      expect(selectedBuilds, 1);
      expect(guards, 1);
      expect(audit.lastSnapshot!.files.single.path, other.path);
      expect(audit.lastSnapshot!.appBytes, 30);
      expect(audit.lastSnapshot!.scannedAt, snapshot.scannedAt);
    },
  );

  test('selected nested files retain shared-root scope rules', () async {
    final owned = await write(
      p.join(data.path, 'portable_transfer', 'nested', 'backup.fluentpack'),
      20,
    );
    final foreign = await write(
      p.join(data.path, 'personal', 'backup.fluentpack'),
      30,
    );
    final scoped = StorageScanInput(
      roots: [
        StorageRoot(
          data.path,
          'shared documents',
          StorageRootKind.data,
          scoped: true,
        ),
      ],
    );
    final preview = await scanStorageFiles(scoped);
    expect(preview.files.single.path, owned.path);
    final selected = await scanStorageFiles(
      scoped,
      onlyPaths: [owned.path, foreign.path],
    );
    expect(
      selected.files.singleWhere((f) => f.path == owned.path).canDelete,
      isTrue,
    );
    expect(
      selected.files.singleWhere((f) => f.path == foreign.path).external,
      isTrue,
    );
    final audit = service(() async => scoped);
    final result = await audit.delete(StorageDeletionPlan(preview.files));
    expect(result.deletedPaths, [owned.path]);
    expect(await foreign.exists(), isTrue);
  });

  test('cleanup progress counts deleted, skipped and failed files', () async {
    final deleted = await write(p.join(cache.path, 'ytdlp_deleted.mp4'), 20);
    final busy = await write(p.join(cache.path, 'ytdlp_busy.mp4'), 30);
    final failed = await write(p.join(cache.path, 'ytdlp_failed.mp4'), 40);
    final progress = <StorageDeletionProgress>[];
    final audit = StorageAuditService(
      buildInput: () async => input(),
      deletionBlockedReason: () => null,
      fileDeletionBlockedReason: (file) =>
          file.path == busy.path ? 'playing' : null,
      beforeDelete: (file) async {
        if (file.path == failed.path) throw const FileSystemException('locked');
      },
    );
    services.add(audit);
    final snapshot = await audit.scan();
    final result = await audit.delete(
      StorageDeletionPlan(snapshot.files),
      onProgress: progress.add,
    );
    expect(result.deletedPaths, [deleted.path]);
    expect(result.skipped.keys, [busy.path]);
    expect(result.failed.keys, [failed.path]);
    expect(progress.first.completedFiles, 0);
    expect(progress.last.completedFiles, 3);
    expect(progress.last.totalFiles, 3);
    expect(progress.last.releasedBytes, 20);
  });

  test('empty cleanup does not build input or scan', () async {
    final audit = service(() async => throw StateError('unexpected scan'));
    final result = await audit.delete(const StorageDeletionPlan([]));
    expect(result.deletedPaths, isEmpty);
    expect(audit.lastSnapshot, isNull);
  });

  test('file changed by preparation is skipped before deletion', () async {
    final file = await write(p.join(cache.path, 'ytdlp_old.mp4'), 20);
    final audit = StorageAuditService(
      buildInput: () async => input(),
      deletionBlockedReason: () => null,
      beforeDelete: (_) => file.setLastModified(DateTime(2030)),
    );
    services.add(audit);
    final snapshot = await audit.scan();
    final result = await audit.delete(StorageDeletionPlan(snapshot.files));
    expect(result.deletedPaths, isEmpty);
    expect(result.skipped[file.path], contains('文件发生变化'));
    expect(await file.exists(), isTrue);
  });

  test(
    'live file guard skips one busy file and deletes an unrelated file',
    () async {
      final busy = await write(p.join(cache.path, 'ytdlp_busy.mp4'), 15);
      final other = await write(p.join(cache.path, 'ytdlp_old.mp4'), 20);
      final audit = StorageAuditService(
        buildInput: () async => input(),
        deletionBlockedReason: () => null,
        fileDeletionBlockedReason: (file) async =>
            file.path == busy.path ? '该文件正在使用' : null,
      );
      services.add(audit);
      final snapshot = await audit.scan();
      final result = await audit.delete(StorageDeletionPlan(snapshot.files));
      expect(result.deletedPaths, [other.path]);
      expect(result.skipped[busy.path], '该文件正在使用');
      expect(await busy.exists(), true);
      expect(audit.lastSnapshot!.files.single.path, busy.path);
      expect(audit.lastSnapshot!.appBytes, 15);
    },
  );

  test(
    'every byte is counted once across overlapping roots and shared cards',
    () async {
      final original = await write(
        p.join(data.path, 'imported_videos', 'shared.mp4'),
        90,
      );
      await write(p.join(cache.path, 'file_picker', 'old', 'shared.mp4'), 40);
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(
              workspace.path,
              'container',
              StorageRootKind.privateContainer,
            ),
            ...input().roots,
          ],
          references: [
            StorageReference(
              path: original.path,
              ownerId: 'a',
              ownerTitle: 'A',
              category: StorageCategory.libraryMedia,
              recycled: true,
            ),
            StorageReference(
              path: original.path,
              ownerId: 'b',
              ownerTitle: 'B',
              category: StorageCategory.libraryMedia,
            ),
          ],
        ),
      );
      expect(snapshot.appBytes, 130);
      expect(snapshot.files, hasLength(2));
      expect(snapshot.categories.fold(0, (sum, c) => sum + c.bytes), 130);
      expect(
        snapshot.categories
            .firstWhere((c) => c.category == StorageCategory.libraryMedia)
            .bytes,
        90,
      );
      expect(
        snapshot.categories
            .firstWhere((c) => c.category == StorageCategory.picker)
            .clearableBytes,
        40,
      );
      expect(snapshot.files.first.ownerIds.toSet(), {'a', 'b'});
      expect(snapshot.files.first.canDelete, false);
    },
  );

  test(
    'external originals and adjacent user files are not application storage',
    () async {
      final outside = await write(
        p.join(workspace.path, 'user', 'original.mp4'),
        32,
      );
      await write(p.join(workspace.path, 'user', 'private.mp4'), 64);
      final snapshot = await scanStorageFiles(
        input(
          refs: [
            StorageReference(
              path: outside.path,
              ownerId: 'a',
              ownerTitle: 'A',
              category: StorageCategory.libraryMedia,
            ),
          ],
        ),
      );
      expect(snapshot.appBytes, 0);
      expect(snapshot.externalBytes, 32);
      expect(snapshot.files, hasLength(1));
      expect(snapshot.files.single.external, true);
      expect(snapshot.files.single.canDelete, false);
    },
  );

  test(
    'shared desktop temp only scans owned names and never enumerates other app folders',
    () async {
      await write(p.join(cache.path, 'file_picker', 'a.mp4'), 12);
      await write(p.join(cache.path, 'other_app', 'a.mp4'), 100);
      await write(p.join(cache.path, 'unrelated.mp4'), 200);
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: [
            StorageRoot(
              cache.path,
              'temp',
              StorageRootKind.cache,
              scoped: true,
            ),
          ],
        ),
      );
      expect(snapshot.appBytes, 12);
      expect(snapshot.files, hasLength(1));
      expect(snapshot.clearableBytes, 0);
    },
  );

  test('ambiguous files in shared temp are visible and protected', () async {
    await write(p.join(cache.path, 'merged_user.mp4'), 14);
    final snapshot = await scanStorageFiles(
      StorageScanInput(
        roots: [
          StorageRoot(cache.path, 'temp', StorageRootKind.cache, scoped: true),
        ],
      ),
    );
    expect(snapshot.files.single.canDelete, false);
    expect(snapshot.clearableBytes, 0);
  });

  test(
    'concurrent scan callers both receive input collection failure',
    () async {
      final audit = service(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        throw StateError('cannot collect roots');
      });
      final first = audit.scan();
      final second = audit.scan();
      await Future.wait([
        expectLater(first, throwsStateError),
        expectLater(second, throwsStateError),
      ]);
    },
  );

  test('resumable tracks are protected by precise filename prefix', () async {
    final keep = await write(
      p.join(cache.path, 'bbdown_task_a_video.m4s.part0'),
      20,
    );
    final remove = await write(
      p.join(cache.path, 'bbdown_task_b_video.m4s.part0'),
      30,
    );
    final snapshot = await scanStorageFiles(
      input(filePrefixes: [p.join(cache.path, 'bbdown_task_a_')]),
    );
    expect(
      snapshot.files.firstWhere((f) => f.path == keep.path).canDelete,
      false,
    );
    expect(
      snapshot.files.firstWhere((f) => f.path == remove.path).canDelete,
      true,
    );
    expect(snapshot.clearableBytes, 30);
  });

  test(
    'retained media in a cache directory is displayed as owned media',
    () async {
      final media = await write(
        p.join(cache.path, 'file_picker', 'legacy.mp4'),
        17,
      );
      final snapshot = await scanStorageFiles(
        input(
          refs: [
            StorageReference(
              path: media.path,
              ownerId: 'a',
              ownerTitle: 'A',
              category: StorageCategory.libraryMedia,
              recycled: true,
            ),
          ],
        ),
      );
      expect(snapshot.files.single.category, StorageCategory.recycleBin);
      expect(snapshot.files.single.canDelete, false);
      expect(snapshot.appBytes, 17);
    },
  );

  test(
    'exact preview deletes only selected file; added sibling remains',
    () async {
      final selected = await write(
        p.join(cache.path, 'file_picker', 'selected.mp4'),
        23,
      );
      final audit = service(() async => input());
      final snapshot = await audit.scan();
      final added = await write(p.join(selected.parent.path, 'new.mp4'), 31);
      final result = await audit.delete(StorageDeletionPlan(snapshot.files));
      expect(result.releasedBytes, 23);
      expect(result.deletedPaths, [selected.path]);
      expect(await selected.exists(), false);
      expect(await added.exists(), true);
      expect(result.failed, isEmpty);
      // Cleanup must not rescan newly created files into the retained totals.
      expect(audit.lastSnapshot!.files, isEmpty);
      expect(audit.lastSnapshot!.scannedAt, snapshot.scannedAt);
    },
  );

  test('new library reference after preview prevents deletion', () async {
    final file = await write(
      p.join(data.path, 'imported_videos', 'old.mp4'),
      28,
    );
    var refs = <StorageReference>[];
    final audit = service(() async => input(refs: refs));
    final snapshot = await audit.scan();
    expect(snapshot.files.single.canDelete, true);
    refs = [
      StorageReference(
        path: file.path,
        ownerId: 'new',
        ownerTitle: 'New',
        category: StorageCategory.libraryMedia,
      ),
    ];
    final result = await audit.delete(StorageDeletionPlan(snapshot.files));
    expect(result.releasedBytes, 0);
    expect(result.skipped, hasLength(1));
    expect(await file.exists(), true);
  });

  test('same-size modification after preview is skipped', () async {
    final file = await write(p.join(cache.path, 'ytdlp_old_video.mp4'), 25);
    final audit = service(() async => input());
    final snapshot = await audit.scan();
    await file.setLastModified(DateTime.now().add(const Duration(minutes: 2)));
    final result = await audit.delete(StorageDeletionPlan(snapshot.files));
    expect(result.skipped, hasLength(1));
    expect(result.releasedBytes, 0);
    expect(await file.exists(), true);
  });

  test('busy app refuses destructive operation', () async {
    await write(p.join(cache.path, 'ytdlp_old.mp4'), 25);
    final audit = service(() async => input(), blocked: () => '正在下载');
    final snapshot = await audit.scan();
    await expectLater(
      audit.delete(StorageDeletionPlan(snapshot.files)),
      throwsStateError,
    );
    expect(await File(snapshot.files.single.path).exists(), true);
  });

  test('new work starting during revalidation stops all deletes', () async {
    await write(p.join(cache.path, 'ytdlp_old.mp4'), 25);
    var busy = false;
    var builds = 0;
    final audit = service(() async {
      builds++;
      if (builds > 1) busy = true;
      return input();
    }, blocked: () => busy ? '正在导入' : null);
    final snapshot = await audit.scan();
    final result = await audit.delete(StorageDeletionPlan(snapshot.files));
    expect(result.deletedPaths, isEmpty);
    expect(result.skipped, hasLength(1));
  });

  test(
    'unknown files and configuration cannot be included in a fabricated plan',
    () async {
      await write(p.join(data.path, 'library.json'), 9);
      await write(p.join(cache.path, 'unknown_legacy.db'), 30);
      final audit = service(() async => input());
      final snapshot = await audit.scan();
      expect(snapshot.clearableBytes, 0);
      final result = await audit.delete(StorageDeletionPlan(snapshot.files));
      expect(result.deletedPaths, isEmpty);
      expect(result.skipped, hasLength(2));
    },
  );

  test(
    'directory and file symlinks cannot escape scan boundaries',
    () async {
      final outside = await write(
        p.join(workspace.path, 'outside', 'video.mp4'),
        90,
      );
      await Link(p.join(cache.path, 'file_picker')).create(outside.parent.path);
      await Link(p.join(cache.path, 'ytdlp_link.mp4')).create(outside.path);
      final snapshot = await scanStorageFiles(input());
      expect(snapshot.appBytes, 0);
      expect(snapshot.files, isEmpty);
      expect(snapshot.warnings, isNotEmpty);
    },
    skip: Platform.isWindows
        ? 'Windows symlink creation needs Developer Mode or elevation'
        : false,
  );

  test(
    'parent substituted by symlink after scan fails exact path verification',
    () async {
      await write(p.join(cache.path, 'file_picker', 'video.mp4'), 30);
      final snapshot = await scanStorageFiles(input());
      final entry = snapshot.files.single;
      await Directory(
        p.join(cache.path, 'file_picker'),
      ).rename(p.join(workspace.path, 'moved'));
      await Link(
        p.join(cache.path, 'file_picker'),
      ).create(p.join(workspace.path, 'moved'));
      expect(await storageFileMatches(entry), false);
    },
    skip: Platform.isWindows
        ? 'Windows symlink creation needs Developer Mode or elevation'
        : false,
  );

  test('unit conversion labels decimal and binary values explicitly', () {
    expect(formatStorageSize(130000000000), '130.00 GB');
    expect(formatStorageSize(1073741824, binary: true), '1.00 GiB');
    expect(formatStorageSize(0), '0 B');
  });

  test('Android system total does not add cache to data a second time', () {
    final usage = StoragePlatformUsage(
      appBytes: 10,
      dataBytes: 130,
      cacheBytes: 90,
      sampledAt: DateTime(2026),
    );
    expect(usage.totalBytes, 140);
  });

  test(
    'recent unowned cache is kept until its grace interval expires',
    () async {
      final file = await write(
        p.join(cache.path, 'file_picker', 'fresh.mp4'),
        15,
      );
      final snapshot = await scanStorageFiles(
        StorageScanInput(
          roots: input().roots,
          minimumTemporaryAge: const Duration(minutes: 10),
        ),
      );
      expect(snapshot.files.single.canDelete, false);
      expect(snapshot.clearableBytes, 0);
      await file.setLastModified(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
      final stale = await scanStorageFiles(
        StorageScanInput(
          roots: input().roots,
          minimumTemporaryAge: const Duration(minutes: 10),
        ),
      );
      expect(stale.files.single.canDelete, true);
    },
  );

  test(
    'completed task output may be deleted, but library ownership takes precedence',
    () async {
      final file = await write(
        p.join(data.path, 'yt_dlp_downloads', 'ready.mp4'),
        35,
      );
      final taskRef = StorageReference(
        path: file.path,
        ownerId: 'task',
        ownerTitle: 'download',
        category: StorageCategory.downloads,
        deletable: true,
      );
      final ready = await scanStorageFiles(input(refs: [taskRef]));
      expect(ready.files.single.canDelete, true);
      final imported = await scanStorageFiles(
        input(
          refs: [
            taskRef,
            StorageReference(
              path: file.path,
              ownerId: 'card',
              ownerTitle: 'imported',
              category: StorageCategory.libraryMedia,
            ),
          ],
        ),
      );
      expect(imported.files.single.category, StorageCategory.libraryMedia);
      expect(imported.files.single.canDelete, false);
    },
  );
}
