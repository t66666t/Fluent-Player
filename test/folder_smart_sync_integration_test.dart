import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/progress_sync/folder_sync_models.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'test_dir_cleanup.dart';

class _Direct extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String> getApplicationDocumentsPath() async => root;
  @override
  Future<String> getApplicationSupportPath() async => root;
  @override
  Future<String> getApplicationCachePath() async => p.join(root, 'cache');
  @override
  Future<String> getTemporaryPath() async => p.join(root, 'temp');
}

class _GateStore extends MemoryProgressSyncStore {
  Future<void> Function(Map<String, dynamic> snapshot)? beforeWrite;

  @override
  Future<void> write(Map<String, dynamic> value) async {
    final snapshot = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    await beforeWrite?.call(snapshot);
    await super.write(snapshot);
  }
}

Future<void> _until(bool Function() predicate, [Object? description]) async {
  final end = DateTime.now().add(const Duration(seconds: 20));
  while (!predicate()) {
    if (DateTime.now().isAfter(end)) {
      fail(
        description is String Function()
            ? description()
            : description as String? ?? 'smart sync did not converge',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oldPaths = PathProviderPlatform.instance;
  late Directory root;
  late LibraryService library;
  late _Pair pair;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('smart_folder_sync_');
    PathProviderPlatform.instance = _Paths(root.path);
  });
  tearDownAll(() async {
    PathProviderPlatform.instance = oldPaths;
    await deleteTestTempDir(root);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    for (final name in [
      'library.json',
      'library.json.bak',
      'library.json.tmp',
    ]) {
      final file = File(p.join(root.path, name));
      if (await file.exists()) await file.delete();
    }
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
  });
  tearDown(() async {
    await pair.close();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
  });

  test(
    'smart folders automatically deliver both directions, move identities and deduplicate bytes without merging progress',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        pair = _Pair(root, library);
        await pair.open();
        final sourceChild = await library.createCollection('新章节', pair.source);
        await pair.add('new-source', sourceChild.id, '新增视频', 19);
        await pair.a.syncNow();
        await _until(
          () => pair.received.any((item) => item.title == '新增视频'),
          pair.diagnostics,
        );
        expect(
          pair.b.folderTransfers.every(
            (task) => task.phase != FolderTransferPhase.offered,
          ),
          isTrue,
        );
        final targetNew = pair.received.singleWhere(
          (item) => item.title == '新增视频',
        );
        final targetChild = library.getCollection(targetNew.parentId!)!;
        await library.renameItem(sourceChild.id, '章节改名');
        await library.moveItemToCollection('new-source', pair.source);
        await pair.a.syncNow();
        await _until(
          () =>
              targetChild.name == '章节改名' &&
              targetNew.parentId == pair.destination,
          () => pair.diagnostics,
        );
        expect(targetChild.name, '章节改名');
        expect(targetNew.parentId, pair.destination);

        await pair.add('new-phone', pair.destination, '手机新增', 29);
        await pair.b.syncNow();
        await _until(
          () => pair.originals.any((item) => item.title == '手机新增'),
          pair.diagnostics,
        );
        final duplicate = VideoItem.fromJson({
          ...pair.original.toJson(),
          'id': 'same-content-other-course',
          'title': '同视频另一条目',
          'lastPositionMs': 0,
        });
        await library.addSingleVideo(duplicate, useOriginalPath: true);
        await pair.a.syncNow();
        await _until(
          () => pair.received.any((item) => item.title == duplicate.title),
          pair.diagnostics,
        );
        final remoteDuplicate = pair.received.singleWhere(
          (item) => item.title == duplicate.title,
        );
        await _until(
          () =>
              pair.a.folderTransfers.every((task) => !task.isActive) &&
              pair.b.folderTransfers.every((task) => !task.isActive),
          () => pair.diagnostics,
        );
        final remoteOriginal = pair.received.singleWhere(
          (item) => item.title == pair.original.title,
        );
        expect(remoteDuplicate.id, isNot(remoteOriginal.id));
        expect(remoteDuplicate.path, remoteOriginal.path);
        await library.updateVideoProgress(pair.original.id, 3000);
        await library.updateVideoProgress(duplicate.id, 12000);
        await pair.a.flush();
        await pair.a.syncNow();
        expect(remoteOriginal.lastPositionMs, 3000);
        expect(remoteDuplicate.lastPositionMs, 12000);
        expect(pair.a.folderSyncIssues, isEmpty);
        expect(pair.b.folderSyncIssues, isEmpty);
      }, _Direct());
    },
    timeout: const Timeout(Duration(seconds: 80)),
  );

  test(
    'missing files repair the same card, local removal stays local, explicit remote deletion only recycles',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        pair = _Pair(root, library);
        await pair.open();
        final oldId = pair.received.single.id;
        VideoItem remote() => library.getVideo(oldId)!;
        expect(remote().path, isNot(pair.original.path));
        final originalBytes = await File(pair.original.path).readAsBytes();
        await File(remote().path).delete();
        expect(await File(pair.original.path).exists(), isTrue);
        await pair.b.syncNow();
        await _until(
          () => File(remote().path).existsSync(),
          () => pair.diagnostics,
        );
        expect(pair.received.single.id, oldId);
        expect(await File(remote().path).readAsBytes(), originalBytes);
        expect(pair.originals.single.isRecycled, isFalse);
        await pair.b.updateFolderSettings(
          pair.destination,
          pair.b.folderSettings(pair.destination).copyWith(syncDeletes: true),
        );
        await pair.b.removeSyncedItem(pair.destination, oldId);
        await pair.b.syncNow();
        await pair.a.syncNow();
        expect(remote().isRecycled, isTrue);
        expect(pair.received, isEmpty);
        expect(pair.original.isRecycled, isFalse);
        final oldTasks = pair.b.folderTransfers.map((task) => task.id).toSet();
        await pair.a.sendFolder(pair.source, pair.b.deviceId);
        await _until(
          () => pair.b.folderTransfers.any(
            (task) =>
                !oldTasks.contains(task.id) &&
                task.phase == FolderTransferPhase.completed,
          ),
          () => pair.diagnostics,
        );
        await pair.b.syncNow();
        expect(remote().isRecycled, isTrue);
        expect(pair.original.isRecycled, isFalse);
        await pair.b.restoreLocallyRemovedItems(pair.destination);
        expect(pair.received.single.id, oldId);
        expect(await File(remote().path).exists(), isTrue);
        await pair.a.removeSyncedItem(
          pair.source,
          pair.original.id,
          everywhere: true,
        );
        await pair.a.syncNow();
        expect(remote().isRecycled, isTrue);
        expect(pair.original.isRecycled, isTrue);
        expect(await File(remote().path).exists(), isTrue);
        expect(await File(pair.original.path).exists(), isTrue);
        await pair.b.syncNow();
        expect(remote().isRecycled, isTrue);
      }, _Direct());
    },
    timeout: const Timeout(Duration(seconds: 75)),
  );

  test(
    'concurrent renames preserve local state until resolution and keep-both becomes separate synchronized entries',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        pair = _Pair(root, library);
        await pair.open();
        final group = (pair.aStore.value!['groups'] as List).cast<Map>().single;
        final catalog =
            (pair.aStore.value!['folderCatalogs'] as Map)[group['id']] as Map;
        final base = (catalog['events'] as List)
            .map(
              (raw) => FolderSyncEvent.fromJson(
                Map<String, dynamic>.from(raw as Map),
              ),
            )
            .singleWhere(
              (event) => event.node.kind == FolderSyncNodeKind.media,
            );
        final concurrent = FolderSyncEvent(
          id: 'phone-concurrent-rename',
          groupId: group['id'] as String,
          deviceId: pair.b.deviceId,
          clock: {
            ...base.clock,
            pair.b.deviceId: (base.clock[pair.b.deviceId] ?? 0) + 1,
          },
          node: base.node.copyWith(name: '手机改名'),
          deviceName: '手机',
        );
        final cipher = await AesGcm.with256bits().encrypt(
          utf8.encode(jsonEncode(concurrent.toJson())),
          secretKey: SecretKey(base64Decode(group['key'] as String)),
          aad: utf8.encode('folder|${group['id']}|${concurrent.id}'),
        );
        await library.renameItem(pair.original.id, '电脑改名');
        await pair.a.lan!.onChanges(pair.b.deviceId, [
          {
            'kind': 'folder-event',
            'version': 1,
            'groupId': group['id'],
            'eventId': concurrent.id,
            'nonce': base64Encode(cipher.nonce),
            'cipherText': base64Encode(cipher.cipherText),
            'mac': base64Encode(cipher.mac.bytes),
          },
        ]);
        final issue = pair.a.folderSyncIssues.singleWhere(
          (issue) => issue.nodeId == base.node.id,
        );
        expect(issue.choices.length, 2);
        expect(pair.original.title, '电脑改名');
        expect(await File(pair.original.path).exists(), isTrue);
        final oldTasks = pair.a.folderTransfers.map((task) => task.id).toSet();
        await pair.b.sendFolder(pair.destination, pair.a.deviceId);
        await _until(
          () => pair.a.folderTransfers.any(
            (task) =>
                !oldTasks.contains(task.id) &&
                task.phase == FolderTransferPhase.completed,
          ),
          () => pair.diagnostics,
        );
        expect(pair.original.title, '电脑改名');
        expect(
          pair.a.folderSyncIssues
              .singleWhere((i) => i.nodeId == base.node.id)
              .choices,
          hasLength(2),
        );
        final local = issue.choices.singleWhere(
          (event) => event.node.name == '电脑改名',
        );
        await pair.a.resolveFolderSyncConflict(
          group['id'] as String,
          base.node.id,
          local.id,
          keepBoth: true,
        );
        await _until(
          () => pair.originals.length == 2 && pair.received.length == 2,
          pair.diagnostics,
        );
        expect(pair.a.folderSyncIssues, isEmpty);
        expect(pair.b.folderSyncIssues, isEmpty);
        expect(pair.originals.map((item) => item.id).toSet(), hasLength(2));
      }, _Direct());
    },
    timeout: const Timeout(Duration(seconds: 70)),
  );

  test(
    'shared mode settings enforce progress-only and one-way content while progress remains bidirectional',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        pair = _Pair(root, library);
        await pair.open();
        await pair.a.updateFolderSettings(
          pair.source,
          pair.a
              .folderSettings(pair.source)
              .copyWith(mode: FolderSyncMode.progressOnly),
        );
        expect(
          pair.b.folderSettings(pair.destination).mode,
          FolderSyncMode.progressOnly,
        );
        await pair.add('later-source', pair.source, '稍后同步', 71);
        await pair.a.syncNow();
        expect(pair.received, hasLength(1));
        await pair.a.updateFolderSettings(
          pair.source,
          pair.a
              .folderSettings(pair.source)
              .copyWith(
                mode: FolderSyncMode.oneWay,
                sourceDeviceId: pair.a.deviceId,
              ),
        );
        await _until(
          () => pair.received.any((item) => item.title == '稍后同步'),
          pair.diagnostics,
        );
        await pair.add('phone-private', pair.destination, '手机本地', 83);
        await pair.b.syncNow();
        expect(pair.originals.any((item) => item.title == '手机本地'), isFalse);
        final remote = pair.received.singleWhere(
          (item) => item.title == pair.original.title,
        );
        await library.updateVideoProgress(remote.id, 17000);
        await pair.b.flush();
        await pair.b.syncNow();
        expect(pair.original.lastPositionMs, 17000);
        await expectLater(
          pair.b.removeSyncedItem(
            pair.destination,
            remote.id,
            everywhere: true,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(remote.isRecycled, isFalse);
      }, _Direct());
    },
    timeout: const Timeout(Duration(seconds: 75)),
  );

  test(
    'a late transfer cannot recreate an explicitly unbound folder',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        pair = _Pair(root, library);
        await pair.open();
        final entered = Completer<void>(), release = Completer<void>();
        final originalControl = pair.b.lan!.onControl!;
        pair.b.lan!.onControl = (peer, method, payload) async {
          if (method == 'folder.ready' || method == 'folder.directReady') {
            if (!entered.isCompleted) entered.complete();
            await release.future;
          }
          return originalControl(peer, method, payload);
        };
        try {
          await pair.a.sendFolder(pair.source, pair.b.deviceId);
          await entered.future.timeout(const Duration(seconds: 15));
          await pair.b.unbindFolder(pair.destination);
        } finally {
          release.complete();
        }
        await pair.a.syncNow();
        await pair.b.syncNow();
        await _until(
          () => pair.b.folderTransfers.every((task) => !task.isActive),
        );
        expect(pair.b.bindings, isEmpty);
        expect(pair.b.invitations, isEmpty);
        expect(await File(pair.received.single.path).exists(), isTrue);
      }, _Direct());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a partial settings branch cannot discard a previously observed conflict',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        pair = _Pair(root, library);
        await pair.open();
        final raw = Map<String, dynamic>.from(
          (pair.aStore.value!['groups'] as List).cast<Map>().single,
        );
        final baseline = Map<String, int>.from(raw['settingsClock'] as Map);
        await pair.a.updateFolderSettings(
          pair.source,
          pair.a
              .folderSettings(pair.source)
              .copyWith(maxAutoTransferBytes: 1000000),
        );
        final selected = pair.a.folderSettings(pair.source);
        final localClock = Map<String, int>.from(
          ((pair.aStore.value!['groups'] as List)
                  .cast<Map>()
                  .single)['settingsClock']
              as Map,
        );
        await pair.a.lan!.onChanges(pair.b.deviceId, [
          {
            'kind': 'invite',
            'group': {
              ...raw,
              'settings': selected
                  .copyWith(maxAutoTransferBytes: 2000000)
                  .toJson(),
              'settingsClock': {
                ...baseline,
                pair.b.deviceId: (baseline[pair.b.deviceId] ?? 0) + 1,
              },
            },
          },
        ]);
        expect(
          pair.a.folderSyncIssues.any(
            (issue) => issue.reason == 'settingsConflict',
          ),
          isTrue,
        );
        await pair.a.lan!.onChanges(pair.b.deviceId, [
          {
            'kind': 'invite',
            'group': {
              ...raw,
              'settings': selected
                  .copyWith(maxAutoTransferBytes: 3000000)
                  .toJson(),
              'settingsClock': {...localClock, 'third-device': 1},
            },
          },
        ]);
        expect(
          pair.a.folderSettings(pair.source).maxAutoTransferBytes,
          1000000,
        );
        expect(
          pair.a.folderSyncIssues.any(
            (issue) => issue.reason == 'settingsConflict',
          ),
          isTrue,
        );
        await pair.a.updateFolderSettings(pair.source, selected);
        expect(
          pair.a.folderSyncIssues.any(
            (issue) => issue.reason == 'settingsConflict',
          ),
          isFalse,
        );
      }, _Direct());
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'receiveLink queued after unbind cannot recreate a revoked folder',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        pair = _Pair(root, library);
        await pair.open();
        final initialIds = pair.b.folderTransfers
            .map((task) => task.id)
            .toSet();
        final received = pair.received.single;
        final expectedBytes = await File(received.path).readAsBytes();
        final groupId = pair.b.bindings.single.groupId;
        final saveEntered = Completer<void>();
        final releaseSave = Completer<void>();
        final readEntered = Completer<void>();
        final releaseRead = Completer<void>();
        final linkingEntered = Completer<void>();
        final receivingZone = Object(), readingZone = Object();
        final originalControl = pair.b.lan!.onControl!;
        Future<List<Map<String, dynamic>>>? blockedRead;
        Future<void>? pendingUnbind;
        FolderTransferTask? resend;

        void observeLinking() {
          final task = resend;
          if (task != null &&
              task.phase == FolderTransferPhase.linking &&
              !linkingEntered.isCompleted) {
            linkingEntered.complete();
          }
        }

        pair.b.addListener(observeLinking);
        pair.b.lan!.onControl = (peer, method, payload) {
          if ((method == 'folder.ready' || method == 'folder.directReady') &&
              !initialIds.contains(payload['id'])) {
            // The scheduled receive and its continuations inherit this zone.
            // It distinguishes the manager's queue-external save from normal
            // capture/sync writes without relying on wall-clock delays.
            return runZoned(
              () => originalControl(peer, method, payload),
              zoneValues: {receivingZone: true},
            );
          }
          return originalControl(peer, method, payload);
        };
        pair.bStore.beforeWrite = (snapshot) async {
          if (Zone.current[receivingZone] == true && !saveEntered.isCompleted) {
            final tasks =
                ((snapshot['folderTransfers'] as Map?)?['tasks'] as List?) ??
                [];
            final adopted = tasks.whereType<Map>().where(
              (task) =>
                  !initialIds.contains(task['id']) &&
                  task['phase'] == 'importing' &&
                  (task['syncOptions'] as Map?)?['adopted'] == true,
            );
            if (adopted.isNotEmpty) {
              final id = adopted.single['id'];
              resend = pair.b.folderTransfers.singleWhere(
                (task) => task.id == id,
              );
              saveEntered.complete();
              await releaseSave.future;
            }
          }
          if (Zone.current[readingZone] == true && !readEntered.isCompleted) {
            readEntered.complete();
            await releaseRead.future;
          }
        };

        try {
          await pair.a.sendFolder(pair.source, pair.b.deviceId);
          await saveEntered.future.timeout(const Duration(seconds: 15));
          expect(resend!.phase, FolderTransferPhase.importing);
          expect(resend!.syncOptions['adopted'], isTrue);

          // Hold a real queued operation while the adopted task is just about
          // to call receiveLink from outside the service operation queue.
          blockedRead = runZoned(
            () => pair.b.lan!.onReadChanges(pair.a.deviceId),
            zoneValues: {readingZone: true},
          );
          await readEntered.future.timeout(const Duration(seconds: 10));
          pendingUnbind = pair.b.unbindFolder(pair.destination);
          // unbindFolder has one initial await init(); its continuation queues
          // unbind before the manager is allowed to continue below.
          await Future<void>.value();
          releaseSave.complete();
          await linkingEntered.future.timeout(const Duration(seconds: 10));
          // Linking emits its phase synchronously before awaiting _adopt.
          // That completed await then invokes receiveLink. A microtask barrier
          // puts its enqueue behind unbind while the queue remains blocked.
          await Future<void>.value();
          expect(pair.b.bindings, hasLength(1));
          expect(
            pair.bStore.value!['revokedFolderGroups'],
            isNot(contains(groupId)),
          );
          releaseRead.complete();
          await blockedRead!.timeout(const Duration(seconds: 15));
          await pendingUnbind.timeout(const Duration(seconds: 15));
          // This third operation is queued after late receiveLink. Its finish
          // proves the guarded link callback has had its turn to run.
          await pair.b.lan!.onReadChanges(pair.a.deviceId);

          expect(pair.b.bindings, isEmpty);
          expect(pair.b.invitations, isEmpty);
          expect(pair.bStore.value!['groups'], isEmpty);
          expect(pair.bStore.value!['revokedFolderGroups'], contains(groupId));
          expect(resend!.phase, FolderTransferPhase.cancelled);
          expect(pair.received.single.id, received.id);
          expect(await File(received.path).readAsBytes(), expectedBytes);
          expect(received.isRecycled, isFalse);
        } finally {
          pair.bStore.beforeWrite = null;
          if (!releaseSave.isCompleted) releaseSave.complete();
          if (!releaseRead.isCompleted) releaseRead.complete();
          pair.b.removeListener(observeLinking);
          pair.b.lan!.onControl = originalControl;
          await blockedRead?.catchError((Object _) => <Map<String, dynamic>>[]);
          await pendingUnbind?.catchError((Object _) {});
        }
      }, _Direct());
    },
    timeout: const Timeout(Duration(seconds: 65)),
  );
}

class _Pair {
  _Pair(this.root, this.library);
  final Directory root;
  final LibraryService library;
  late ProgressSyncService a, b;
  final aStore = MemoryProgressSyncStore();
  final bStore = _GateStore();
  late String source, destination;
  late VideoItem original;
  List<VideoItem> get originals => library.mediaInFolderTree(source);
  List<VideoItem> get received => library.mediaInFolderTree(destination);
  String get diagnostics =>
      'A: ${a.folderTransfers.map((t) => '${t.phase}:${t.error}').toList()} '
      'B: ${b.folderTransfers.map((t) => '${t.phase}:${t.error}').toList()} '
      'issues=${a.folderSyncIssues.map((i) => i.reason).toList()}/${b.folderSyncIssues.map((i) => i.reason).toList()} '
      'source=$source target=$destination files=${library.storageVideos.map((i) => '${i.id}:${i.parentId}:${i.isRecycled}:${i.path}:${File(i.path).existsSync()}').toList()}';
  Future<void> open() async {
    final pair = this;
    pair.source = (await library.createCollection('课程', null)).id;
    pair.original = await pair.add('original', pair.source, '原视频', 7);
    pair.a = ProgressSyncService(library: library, store: pair.aStore);
    pair.b = ProgressSyncService(library: library, store: pair.bStore);
    await pair.a.init();
    await pair.b.init();
    await pair.a.setEnabled(true);
    await pair.b.setEnabled(true);
    final peer = await pair.a.lan!.connectAddress(
      '127.0.0.1:${pair.b.lan!.port}',
    );
    final pairing = await pair.a.lan!.requestPair(peer);
    await pair.a.lan!.approvePair(pairing.id, expectedCode: pairing.code);
    await pair.b.lan!.approvePair(pairing.id, expectedCode: pairing.code);
    await pair.a.sendFolder(pair.source, peer.id);
    await _until(() => pair.b.folderTransfers.isNotEmpty);
    final task = pair.b.folderTransfers.single;
    await pair.b.acceptFolderTransfer(task.id);
    await _until(
      () => task.phase == FolderTransferPhase.completed,
      () => pair.diagnostics,
    );
    await _until(
      () =>
          pair.a.folderTransfers.single.phase == FolderTransferPhase.completed,
      () => pair.diagnostics,
    );
    pair.destination = task.targetCollectionId!;
  }

  Future<VideoItem> add(
    String id,
    String parent,
    String title,
    int seed,
  ) async {
    final path = p.join(root.path, '$id.mp4');
    await File(
      path,
    ).writeAsBytes(List.generate(64 * 1024, (index) => (index + seed) % 251));
    final video = VideoItem(
      id: id,
      path: path,
      title: title,
      durationMs: 60000,
      lastUpdated: 1,
      parentId: parent,
      hasProbedChapters: true,
    );
    await library.addSingleVideo(video, useOriginalPath: true);
    return video;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await a.setEnabled(false);
    await b.setEnabled(false);
    a.dispose();
    b.dispose();
  }

  bool _closed = false;
}
