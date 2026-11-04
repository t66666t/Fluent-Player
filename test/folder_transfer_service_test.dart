import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_folder_transfer.dart';
import 'package:video_player_app/features/portable_transfer/portable_transfer_service.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_lan.dart';
import 'package:video_player_app/features/media_cache/media_cache_models.dart';
import 'package:video_player_app/features/media_cache/media_cache_service.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'test_dir_cleanup.dart';
import 'media_cache_service_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> run(Future<void> Function(_Fixture fixture) test) =>
      HttpOverrides.runWithHttpOverrides(() async {
        final fixture = _Fixture();
        await fixture.start();
        try {
          await test(fixture);
        } finally {
          await fixture.close();
        }
      }, _RealHttp());

  test(
    'consent precedes packaging; completion waits for import and sync link',
    () => run((f) async {
      f.linkGate = Completer<void>();
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final incoming = f.b.tasks.single;
      expect(incoming.phase, FolderTransferPhase.offered);
      expect(incoming.mediaCount, 1);
      expect(incoming.estimatedBytes, 0); // Offer precedes any disk scan.
      expect(f.buildCount, 0);
      expect(f.a.tasks.single.packagePath, isNull);
      expect(f.receivedRoots, isEmpty);
      expect(f.library.storageCollections.length, 2);

      await f.b.accept(incoming.id);
      await f.until(() => f.receivedRoots.length == 1);
      final target = f.receivedRoots.single;
      expect(incoming.phase, FolderTransferPhase.linking);
      expect(f.a.tasks.single.phase, isNot(FolderTransferPhase.completed));
      final actual = f.library.mediaInFolderTree(target).single;
      expect(await File(actual.path).readAsBytes(), f.bytes);
      expect(actual.lastPositionMs, 0);
      expect(f.receivedFingerprintIds.single, contains(actual.id));

      f.linkGate!.complete();
      await f.until(
        () =>
            incoming.phase == FolderTransferPhase.completed &&
            f.a.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(f.buildCount, 1);
      expect(incoming.completedBytes, incoming.totalBytes);
      expect(
        incoming.totalBytes,
        f.bytes.length,
      ); // Raw media, no archive overhead.
      expect(incoming.transportOffer?['protocol'], 3);
      expect(f.a.tasks.single.completedBytes, incoming.totalBytes);
      expect(f.savedB?['targets'], containsValue(target));
    }),
  );

  test(
    'a second actual delivery preserves target IDs and receiver playback',
    () => run((f) async {
      await f.deliver();
      final target = f.b.tasks.single.targetCollectionId!;
      final local = f.library.mediaInFolderTree(target).single;
      local.lastPositionMs = 84000;
      f.library.seedMediaActivityForTesting(
        MediaActivityRecord(
          mediaId: local.id,
          completed: true,
          continueEnrolled: true,
          lastPlayedAtMs: 123,
          accumulatedWatchMs: 456,
        ),
      );

      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 2);
      final second = f.b.tasks.firstWhere(
        (task) => task.phase == FolderTransferPhase.offered,
      );
      await f.b.accept(second.id);
      await f.until(
        () =>
            second.phase == FolderTransferPhase.completed &&
            f.a.tasks.every(
              (task) => task.phase == FolderTransferPhase.completed,
            ),
      );
      expect(second.targetCollectionId, target);
      expect(f.library.mediaInFolderTree(target).single.id, local.id);
      expect(f.library.getVideo(local.id)?.lastPositionMs, 84000);
      expect(f.library.mediaActivity(local.id)?.completed, true);
      expect(f.library.mediaActivity(local.id)?.lastPlayedAtMs, 123);
      expect(f.receivedRoots, [target, target]);
      expect(f.library.storageCollections.length, 4);
    }),
  );

  test(
    'deleting a download cache waits until device sending releases its file',
    () => run((f) async {
      final previous = MediaCacheService.instance;
      final cache = MediaCacheService(
        backend: FakeBackend(f.temp),
        journal: File(p.join(f.temp.path, 'send-cache.json')),
        observeNetwork: false,
      );
      MediaCacheService.instance = cache;
      await cache.initialize();
      try {
        final source = f.library.mediaInFolderTree(f.sourceFolder).single;
        source.sourceRef = const MediaSourceRef(
          value: 'BVSyncLease',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BVSyncLease',
          cid: 77,
        );
        source.bilibiliDownloadPath = source.path;
        final variant = CacheVariant(
          source: CacheSource.fromItem(source)!,
          quality: const CacheQuality(id: '80', label: '1080P', height: 1080),
          path: source.path,
          bytes: f.bytes.length,
          createdAt: 1,
          managed: false,
        );
        await cache.registerLegacy(variant);
        f.linkGate = Completer<void>();
        await f.a.sendFolder(f.sourceFolder, 'beta');
        await f.until(() => f.b.tasks.isNotEmpty);
        await f.b.accept(f.b.tasks.single.id);
        await f.until(() => f.receivedRoots.isNotEmpty);
        await cache.deleteVariant(variant.id);
        expect(await File(source.path).exists(), isTrue);
        expect(
          cache.variants.any((v) => v.path == source.path && v.pendingDelete),
          isTrue,
        );
        f.linkGate!.complete();
        await f.until(
          () => f.a.tasks.single.phase == FolderTransferPhase.completed,
        );
        await f.until(() => !File(source.path).existsSync());
        final received = f.library
            .mediaInFolderTree(f.receivedRoots.single)
            .single;
        expect(
          await File(
            received.bilibiliDownloadPath ?? received.path,
          ).readAsBytes(),
          f.bytes,
        );
      } finally {
        if (f.linkGate?.isCompleted == false) f.linkGate!.complete();
        await f.a.pause();
        await f.b.pause();
        await cache.shutdown();
        MediaCacheService.instance = previous;
      }
    }),
  );

  test(
    'new incoming folder uses chosen parent and keeps it on retry',
    () => run((f) async {
      final parent = await f.library.createCollection('Receive Here', null);
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final incoming = f.b.tasks.single;
      await f.b.accept(incoming.id, destinationParentId: parent.id);
      await f.until(() => incoming.phase == FolderTransferPhase.completed);
      final root = incoming.targetCollectionId!;
      expect(f.library.getCollection(root)!.parentId, parent.id);
      await f.b.retry(incoming.id);
      expect(f.library.getCollection(root)!.parentId, parent.id);
      expect(
        await File(f.library.mediaInFolderTree(root).single.path).readAsBytes(),
        f.bytes,
      );
    }),
  );

  test(
    'direct receive does not demand double the available media space',
    () => run((f) async {
      f.receiverAvailableBytes =
          f.bytes.length + 16 * 1024 * 1024 + 512 * 1024 * 1024;
      await f.a.sendFolder(
        f.sourceFolder,
        'beta',
        syncOptions: {
          'estimatedBytes': f.bytes.length,
          'includeMediaIds': [
            f.library.mediaInFolderTree(f.sourceFolder).single.id,
          ],
        },
      );
      await f.until(() => f.b.tasks.length == 1);
      final incoming = f.b.tasks.single;
      await f.b.accept(incoming.id);
      await f.until(() => incoming.phase == FolderTransferPhase.completed);
      expect(incoming.error, isNull);
    }),
  );

  test(
    'corrupt permanent files after a link failure must be received again',
    () => run((f) async {
      f.failNextLink = true;
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final incoming = f.b.tasks.single;
      await f.b.accept(incoming.id);
      await f.until(
        () =>
            incoming.phase == FolderTransferPhase.paused &&
            f.receivedRoots.isNotEmpty,
      );
      final target = incoming.targetCollectionId!;
      final item = f.library.mediaInFolderTree(target).single;
      final file = File(item.path);
      final before = await file.stat();
      final broken = await file.readAsBytes();
      broken[0] ^= 1;
      await file.writeAsBytes(broken, flush: true);
      await file.setLastModified(before.modified);
      item.lastPositionMs = 12345;
      await f.b.retry(incoming.id);
      await f.until(() => incoming.phase == FolderTransferPhase.completed);
      final recovered = f.library.mediaInFolderTree(target).single;
      expect(await File(recovered.path).readAsBytes(), f.bytes);
      expect(recovered.id, item.id);
      expect(recovered.lastPositionMs, 12345);
      expect(f.buildCount, greaterThan(1));
    }),
  );

  test(
    'reject and sender cancel notify both sides without creating a folder',
    () => run((f) async {
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final first = f.b.tasks.single;
      await f.b.reject(first.id);
      await f.until(
        () => f.a.tasks.single.phase == FolderTransferPhase.cancelled,
      );
      expect(first.phase, FolderTransferPhase.cancelled);

      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 2);
      final second = f.a.tasks.firstWhere(
        (task) => task.phase != FolderTransferPhase.cancelled,
      );
      await f.a.cancel(second.id);
      await f.until(
        () => f.b.tasks.every(
          (task) => task.phase == FolderTransferPhase.cancelled,
        ),
      );
      expect(f.buildCount, 0);
      expect(f.receivedRoots, isEmpty);
      expect(f.library.storageCollections.length, 2);
    }),
  );

  test(
    'cancelling during initial onImported never creates the progress link',
    () => run((f) async {
      f.adoptGate = Completer<void>();
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final task = f.b.tasks.single;
      await f.b.accept(task.id);
      await f.until(() => f.adoptedRoots.length == 1);
      final target = task.targetCollectionId!;
      final copied = f.library.mediaInFolderTree(target).single;
      expect(await File(copied.path).readAsBytes(), f.bytes);
      expect(f.receivedRoots, isEmpty);
      await f.b.cancel(task.id);
      f.adoptGate!.complete();
      await f.until(
        () => f.a.tasks.single.phase == FolderTransferPhase.cancelled,
      );
      await f.until(() => task.syncOptions['importStarted'] != true);
      expect(task.phase, FolderTransferPhase.cancelled);
      expect(f.receivedRoots, isEmpty);
      expect(f.adoptedRoots, [target]);
      expect(f.library.getVideo(copied.id), isNotNull);
      expect(await File(copied.path).exists(), isTrue);
    }),
  );

  test(
    'cancelling a resumed pending-adopt task never calls receiveLink',
    () => run((f) async {
      await f.deliver();
      final original = f.b.tasks.single;
      final target = original.targetCollectionId!;
      final saved =
          jsonDecode(jsonEncode(f.b.toJson())) as Map<String, dynamic>;
      final taskJson = (saved['tasks'] as List).single as Map;
      taskJson['phase'] = 'paused';
      taskJson['syncOptions'] = {
        ...Map<String, dynamic>.from(taskJson['syncOptions'] as Map),
        'adopted': false,
        'importStarted': true,
      };
      await f.b.pause();
      f.b.dispose();
      f.b = f.manager('beta', f.lanB, savedState: saved);
      f.lanB.onControl = f.b.handleControl;
      f.adoptGate = Completer<void>();
      await f.b.start();
      await f.b.retry(original.id);
      await f.until(() => f.adoptedRoots.length == 2);
      final resumed = f.b.tasks.single;
      expect(f.receivedRoots, [target]);
      await f.b.cancel(resumed.id);
      f.adoptGate!.complete();
      await f.until(() => resumed.syncOptions['importStarted'] != true);
      // Let the continuation after onImported run, so this assertion verifies
      // side effects after the await rather than only the cancellation flag.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(resumed.phase, FolderTransferPhase.cancelled);
      expect(f.receivedRoots, [target]);
      expect(f.library.mediaInFolderTree(target), hasLength(1));
    }),
  );

  test(
    'pausing during onImported retries identity adoption before linking without recopying',
    () => run((f) async {
      f.adoptGate = Completer<void>();
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final task = f.b.tasks.single;
      await f.b.accept(task.id);
      await f.until(() => f.adoptedRoots.length == 1);
      final target = task.targetCollectionId!;
      final imported = f.library.mediaInFolderTree(target).single;
      final mediaId = imported.id, mediaPath = imported.path;
      final stableIds = Map<String, String>.of(task.importedStableIds);
      final videoCount = f.library.storageVideos.length;
      final collectionCount = f.library.storageCollections.length;
      final completedBytes = task.completedBytes;
      expect(f.receivedRoots, isEmpty);
      expect(await File(mediaPath).readAsBytes(), f.bytes);

      // pause changes the task state before its first await. Release the
      // callback only after that change, then let pause join the receive job.
      // No timer or arbitrary delay is needed to race the callback return.
      final pausing = f.b.pause();
      expect(task.phase, FolderTransferPhase.paused);
      f.adoptGate!.complete();
      await pausing;
      expect(task.syncOptions['adopted'], isFalse);
      expect(task.syncOptions['importStarted'], isFalse);
      expect(f.receivedRoots, isEmpty);
      expect(f.adoptedRoots, [target]);
      expect(f.a.tasks.single.phase, isNot(FolderTransferPhase.completed));

      f.adoptGate = Completer<void>();
      await f.b.start();
      await f.b.retry(task.id);
      await f.until(() => f.adoptedRoots.length == 2);
      expect(task.phase, FolderTransferPhase.linking);
      expect(f.adoptedRoots, [target, target]);
      expect(f.receivedRoots, isEmpty);
      expect(task.targetCollectionId, target);
      expect(task.importedStableIds, stableIds);
      expect(f.library.mediaInFolderTree(target).single.id, mediaId);
      expect(f.library.mediaInFolderTree(target).single.path, mediaPath);
      expect(f.library.storageVideos.length, videoCount);
      expect(f.library.storageCollections.length, collectionCount);
      expect(f.buildCount, 1);

      f.adoptGate!.complete();
      await f.until(
        () =>
            task.phase == FolderTransferPhase.completed &&
            f.a.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(task.syncOptions['adopted'], isTrue);
      expect(f.receivedRoots, [target]);
      expect(f.adoptedRoots, [target, target]);
      expect(task.targetCollectionId, target);
      expect(task.importedStableIds, stableIds);
      expect(task.completedBytes, completedBytes);
      expect(f.library.mediaInFolderTree(target).single.id, mediaId);
      expect(f.library.mediaInFolderTree(target).single.path, mediaPath);
      expect(await File(mediaPath).readAsBytes(), f.bytes);
      expect(f.library.storageVideos.length, videoCount);
      expect(f.library.storageCollections.length, collectionCount);
      expect(f.buildCount, 1);
    }),
  );

  test(
    'control from a different device cannot accept or cancel another transfer',
    () => run((f) async {
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final task = f.b.tasks.single;
      for (final method in [
        'folder.cancel',
        'folder.ready',
        'folder.progress',
      ]) {
        await expectLater(
          f.b.handleControl('gamma', method, {'id': task.id}),
          throwsFormatException,
        );
      }
      await expectLater(
        f.a.handleControl('gamma', 'folder.accept', {'id': task.id}),
        throwsFormatException,
      );
      expect(task.phase, FolderTransferPhase.offered);
      expect(task.accepted, false);
      await f.b.accept(task.id);
      await f.until(() => task.phase == FolderTransferPhase.completed);
    }),
  );

  test(
    'offline send stays queued and resumes into explicit receiver consent',
    () => run((f) async {
      await f.b.pause();
      await f.lanB.stop();
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.a.tasks.single.phase == FolderTransferPhase.paused);
      final task = f.a.tasks.single;
      expect(f.buildCount, 0);
      expect(f.receivedRoots, isEmpty);
      await f.lanB.start(
        bindAddress: InternetAddress.loopbackIPv4,
        enableDiscovery: false,
      );
      await f.b.start();
      await f.reconnect();
      await f.a.retry(task.id);
      await f.until(() => f.b.tasks.length == 1);
      expect(f.b.tasks.single.phase, FolderTransferPhase.offered);
      expect(f.buildCount, 0);
      await f.b.accept(task.id);
      await f.until(
        () => f.a.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(f.receivedRoots.length, 1);
    }),
  );

  test(
    'paused task survives manager restart and never bypasses consent',
    () => run((f) async {
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final id = f.a.tasks.single.id;
      await f.a.pause();
      expect(f.a.tasks.single.phase, FolderTransferPhase.paused);
      final saved =
          jsonDecode(jsonEncode(f.a.toJson())) as Map<String, dynamic>;
      f.a.dispose();
      f.a = f.manager('alpha', f.lanA, savedState: saved);
      f.lanA.onControl = f.a.handleControl;
      expect(f.a.tasks.single.phase, FolderTransferPhase.paused);
      await f.a.start();
      await f.a.retry(id);
      await f.until(
        () => f.a.tasks.single.phase == FolderTransferPhase.waiting,
      );
      expect(f.b.tasks.single.phase, FolderTransferPhase.offered);
      expect(f.buildCount, 0);
      await f.b.accept(id);
      await f.until(
        () => f.a.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(f.receivedRoots.length, 1);
    }),
  );
  test(
    'receiver restart after link failure reuses imported folder without recopy',
    () => run((f) async {
      f.failNextLink = true;
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final id = f.b.tasks.single.id;
      await f.b.accept(id);
      await f.until(
        () =>
            f.b.tasks.single.phase == FolderTransferPhase.paused &&
            f.b.tasks.single.targetCollectionId != null,
      );
      final target = f.b.tasks.single.targetCollectionId!;
      final mediaId = f.library.mediaInFolderTree(target).single.id;
      expect(f.a.tasks.single.phase, isNot(FolderTransferPhase.completed));
      final state =
          jsonDecode(jsonEncode(f.b.toJson())) as Map<String, dynamic>;
      await f.b.pause();
      f.b.dispose();
      f.b = f.manager('beta', f.lanB, savedState: state);
      f.lanB.onControl = f.b.handleControl;
      await f.b.start();
      await f.b.retry(id);
      await f.until(
        () =>
            f.b.tasks.single.phase == FolderTransferPhase.completed &&
            f.a.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(f.library.mediaInFolderTree(target).single.id, mediaId);
      expect(f.receivedRoots, [target, target]);
      expect(f.library.storageCollections.length, 4);
    }),
  );

  test(
    'retry does not finish by linking when the permanent video is gone',
    () => run((f) async {
      await f.deliver();
      final task = f.b.tasks.single;
      final target = task.targetCollectionId!;
      final video = f.library.mediaInFolderTree(target).single;
      video.lastPositionMs = 42000;
      final mediaId = video.id;
      await File(video.path).delete();
      final linked = f.receivedRoots.length;
      task.phase = FolderTransferPhase.paused;
      await f.b.retry(task.id);
      await f.until(
        () =>
            task.phase == FolderTransferPhase.needsAttention ||
            task.phase == FolderTransferPhase.paused,
      );
      expect(task.phase, isNot(FolderTransferPhase.completed));
      expect(f.receivedRoots.length, linked);
      expect(f.library.getVideo(mediaId)?.id, mediaId);
      expect(f.library.getVideo(mediaId)?.lastPositionMs, 42000);
      expect(await File(video.path).exists(), isFalse);
    }),
  );

  test(
    'turning sync off during link pauses completion and resumes the same folder',
    () => run((f) async {
      f.linkGate = Completer<void>();
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final task = f.b.tasks.single;
      await f.b.accept(task.id);
      await f.until(() => f.receivedRoots.length == 1);
      final target = task.targetCollectionId;
      await f.b.pause();
      expect(task.phase, FolderTransferPhase.paused);
      f.linkGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(task.phase, FolderTransferPhase.paused);
      expect(f.a.tasks.single.phase, isNot(FolderTransferPhase.completed));
      await f.b.start();
      await f.b.retry(task.id);
      await f.until(
        () =>
            task.phase == FolderTransferPhase.completed &&
            f.a.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(task.targetCollectionId, target);
      expect(f.receivedRoots, [target, target]);
      expect(f.library.mediaInFolderTree(target!).length, 1);
    }),
  );
  test(
    'available capacity is checked before consent and can recover without reoffering',
    () => run((f) async {
      f.receiverAvailableBytes = 0;
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      final incoming = f.b.tasks.single;
      await expectLater(
        f.b.accept(incoming.id),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'Chinese capacity message',
            contains('空间不足'),
          ),
        ),
      );
      expect(incoming.accepted, false);
      expect(incoming.phase, FolderTransferPhase.offered);
      expect(incoming.error, contains('空间不足'));
      expect(f.buildCount, 0);
      expect(f.receivedRoots, isEmpty);
      expect(f.library.storageCollections.length, 2);
      f.receiverAvailableBytes = 2 * 1024 * 1024 * 1024;
      await f.b.accept(incoming.id);
      await f.until(
        () =>
            incoming.phase == FolderTransferPhase.completed &&
            f.a.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(f.receivedRoots.length, 1);
      expect(incoming.accepted, true);
    }),
  );

  for (final cancelled in [true, false]) {
    test(
      'late authenticated terminal reports cannot change a ${cancelled ? 'cancelled' : 'completed'} send',
      () => run((f) async {
        if (cancelled) {
          f.linkGate = Completer<void>();
          await f.a.sendFolder(f.sourceFolder, 'beta');
          await f.until(() => f.b.tasks.length == 1);
          await f.b.accept(f.b.tasks.single.id);
          await f.until(() => f.receivedRoots.length == 1);
          await f.a.cancel(f.a.tasks.single.id);
          await f.until(
            () => f.b.tasks.single.phase == FolderTransferPhase.cancelled,
          );
          f.linkGate!.complete();
        } else {
          await f.deliver();
        }
        final task = f.a.tasks.single;
        final phase = task.phase;
        final peer = f.lanB.nearbyDevices.singleWhere(
          (item) => item.id == 'alpha',
        );
        for (final attention in [true, false, true]) {
          await f.lanB.sendControl(peer, 'folder.done', {
            'id': task.id,
            'attention': attention,
            'unavailableCount': 1,
          });
          expect(task.phase, phase);
          expect(task.canRetry, isFalse);
        }
        await f.a.retry(task.id);
        expect(task.phase, phase);
        expect(f.buildCount, 1);
      }),
    );
  }

  test(
    'authenticated progress arriving out of order cannot regress a real delivery',
    () => run((f) async {
      f.linkGate = Completer<void>();
      await f.a.sendFolder(f.sourceFolder, 'beta');
      await f.until(() => f.b.tasks.length == 1);
      await f.b.accept(f.b.tasks.single.id);
      await f.until(() => f.receivedRoots.length == 1);
      final sender = f.a.tasks.single;
      expect(sender.totalBytes, greaterThan(0));
      expect(sender.phase, isNot(FolderTransferPhase.completed));
      final peer = f.lanB.nearbyDevices.singleWhere(
        (item) => item.id == 'alpha',
      );
      final sequence = sender.lastRemoteSequence + 1000;
      await f.lanB.sendControl(peer, 'folder.progress', {
        'id': sender.id,
        'seq': sequence,
        'bytes': sender.totalBytes,
        'total': sender.totalBytes,
        'speed': 1000,
        'phase': 'linking',
        'stageProgress': 0.8,
      });
      await f.lanB.sendControl(peer, 'folder.progress', {
        'id': sender.id,
        'seq': sequence - 1,
        'bytes': sender.totalBytes ~/ 2,
        'total': sender.totalBytes,
        'speed': 1,
        'phase': 'transferring',
        'stageProgress': 0.1,
      });
      expect(sender.lastRemoteSequence, sequence);
      expect(sender.completedBytes, sender.totalBytes);
      expect(sender.phase, FolderTransferPhase.linking);
      expect(sender.stageProgress, 0.8);
      // A duplicate of the newer report also cannot replace it with old bytes.
      await f.lanB.sendControl(peer, 'folder.progress', {
        'id': sender.id,
        'seq': sequence,
        'bytes': 0,
        'total': sender.totalBytes,
        'speed': 0,
        'phase': 'transferring',
      });
      expect(sender.completedBytes, sender.totalBytes);
      expect(sender.phase, FolderTransferPhase.linking);
      f.linkGate!.complete();
      await f.until(
        () =>
            sender.phase == FolderTransferPhase.completed &&
            f.b.tasks.single.phase == FolderTransferPhase.completed,
      );
      expect(f.receivedRoots.length, 1);
    }),
  );
}

class _Fixture {
  late Directory temp;
  late LibraryService library;
  late ProgressSyncLan lanA, lanB;
  late FolderTransferService a, b;
  late String sourceFolder;
  late PortableTransferService adapterService;
  final bytes = List<int>.generate(256 * 1024, (i) => i % 251);
  final originalProvider = PathProviderPlatform.instance;
  int buildCount = 0;
  final receivedRoots = <String>[];
  final adoptedRoots = <String>[];
  final receivedFingerprintIds = <Set<String>>[];
  Map<String, dynamic>? savedA, savedB;
  Completer<void>? linkGate;
  Completer<void>? adoptGate;
  bool failNextLink = false;
  int? receiverAvailableBytes = 1024 * 1024 * 1024 * 1024;

  Future<void> start() async {
    temp = await Directory.systemTemp.createTemp('folder_manager_');
    PathProviderPlatform.instance = _Paths(temp.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = temp.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
    // Two roots here model the source library. A received root is independent.
    final root = await library.createCollection('课程', null);
    sourceFolder = root.id;
    final child = await library.createCollection('第一章', root.id);
    final file = File(p.join(temp.path, 'source.mp4'));
    await file.writeAsBytes(bytes);
    await library.addSingleVideo(
      VideoItem(
        id: 'source-media',
        path: file.path,
        title: '课时一',
        durationMs: 120000,
        lastPositionMs: 53000,
        lastUpdated: 1,
        parentId: child.id,
        hasProbedChapters: true,
      ),
      useOriginalPath: true,
    );
    // library.init() creates a legacy empty default root; remove it explicitly.
    for (final folder
        in library.collections.where((item) => item.id != root.id).toList()) {
      await library.moveToRecycleBin([folder.id]);
      await library.deleteFromRecycleBin([folder.id]);
    }

    final keyA = await X25519().newKeyPairFromSeed(List<int>.filled(32, 1));
    final keyB = await X25519().newKeyPairFromSeed(List<int>.filled(32, 2));
    lanA = ProgressSyncLan(
      deviceId: 'alpha',
      deviceName: '电脑',
      privateKeyBytes: await keyA.extractPrivateKeyBytes(),
      trustedPeerPublicKeys: {
        'beta': base64Encode((await keyB.extractPublicKey()).bytes),
      },
      onTrustChanged: (_) {},
      onReadChanges: (_) async => [],
      onChanges: (_, _) async {},
    );
    lanB = ProgressSyncLan(
      deviceId: 'beta',
      deviceName: '手机',
      privateKeyBytes: await keyB.extractPrivateKeyBytes(),
      trustedPeerPublicKeys: {
        'alpha': base64Encode((await keyA.extractPublicKey()).bytes),
      },
      onTrustChanged: (_) {},
      onReadChanges: (_) async => [],
      onChanges: (_, _) async {},
    );
    await lanA.start(
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
    );
    await lanB.start(
      bindAddress: InternetAddress.loopbackIPv4,
      enableDiscovery: false,
    );
    await reconnect();
    adapterService = PortableTransferService.forTesting();
    a = manager('alpha', lanA);
    b = manager('beta', lanB);
    lanA.onControl = a.handleControl;
    lanB.onControl = b.handleControl;
    await a.start();
    await b.start();
  }

  FolderTransferService manager(
    String id,
    ProgressSyncLan lan, {
    Map<String, dynamic>? savedState,
  }) => FolderTransferService(
    library: library,
    lan: lan,
    autoRetry: false,
    savedState: savedState,
    adapter: PortableFolderTransfer(service: adapterService),
    availableBytes: (_) async =>
        id == 'beta' ? receiverAvailableBytes : 1024 * 1024 * 1024 * 1024,
    directoryProvider: () async => Directory(p.join(temp.path, id)),
    peerNames: () => {'alpha': '电脑', 'beta': '手机'},
    persistState: () async {
      final manager = id == 'alpha' ? a : b;
      final copy =
          jsonDecode(jsonEncode(manager.toJson())) as Map<String, dynamic>;
      if (id == 'alpha') {
        savedA = copy;
      } else {
        savedB = copy;
      }
    },
    buildLink: (root, peer, fingerprints) async {
      expect(id, 'alpha');
      expect(root, sourceFolder);
      expect(peer, 'beta');
      expect(fingerprints.keys, contains('source-media'));
      buildCount++;
      return {'version': 1, 'source': root, 'groupId': 'test-sync-group'};
    },
    onImported: (peer, target, descriptor, mappings) async {
      expect(id, 'beta');
      expect(peer, 'alpha');
      expect(target, isNot(sourceFolder));
      expect(descriptor['source'], sourceFolder);
      adoptedRoots.add(target);
      await adoptGate?.future;
    },
    receiveLink: (descriptor, peer, target, fingerprints) async {
      expect(id, 'beta');
      expect(peer, 'alpha');
      expect(descriptor['source'], sourceFolder);
      expect(target, isNot(sourceFolder));
      final media = library.mediaInFolderTree(target);
      expect(media.length, 1);
      expect(
        await File(
          media.single.bilibiliDownloadPath ?? media.single.path,
        ).readAsBytes(),
        bytes,
      );
      receivedRoots.add(target);
      receivedFingerprintIds.add(fingerprints.keys.toSet());
      if (failNextLink) {
        failNextLink = false;
        throw StateError('Temporary sync-link storage failure');
      }
      await linkGate?.future;
    },
  );

  Future<void> reconnect() async {
    await lanA.connectAddress('127.0.0.1:${lanB.port}');
    await lanB.connectAddress('127.0.0.1:${lanA.port}');
  }

  Future<void> deliver() async {
    final before = b.tasks.length;
    await a.sendFolder(sourceFolder, 'beta');
    await until(() => b.tasks.length > before);
    final incoming = b.tasks.firstWhere(
      (task) => task.phase == FolderTransferPhase.offered,
    );
    await b.accept(incoming.id);
    await until(
      () =>
          incoming.phase == FolderTransferPhase.completed &&
          a.tasks.every((task) => task.phase == FolderTransferPhase.completed),
    );
  }

  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail(
          'Transfer did not converge. '
          'A=${a.tasks.map((task) => '${task.phase}:${task.error}').toList()} '
          'B=${b.tasks.map((task) => '${task.phase}:${task.error}').toList()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> close() async {
    if (linkGate?.isCompleted == false) linkGate!.complete();
    if (adoptGate?.isCompleted == false) adoptGate!.complete();
    await a.pause();
    await b.pause();
    await lanA.stop();
    await lanB.stop();
    a.dispose();
    b.dispose();
    lanA.dispose();
    lanB.dispose();
    adapterService.dispose();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = originalProvider;
    await deleteTestTempDir(temp);
  }
}

class _RealHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

class _Paths extends PathProviderPlatform {
  final String root;
  _Paths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getDownloadsPath() async => root;
}
