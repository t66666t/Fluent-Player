import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/progress_sync/folder_transfer_models.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/settings_service.dart';

import 'test_dir_cleanup.dart';

class _DirectHttp extends HttpOverrides {
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

Future<void> _until(bool Function() predicate, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail(reason ?? 'operation timed out');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LibraryService library;
  final originalPaths = PathProviderPlatform.instance;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('folder_sync_link_');
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    library.skipImportSidecarWorkForTesting = true;
  });
  tearDown(() async {
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    PathProviderPlatform.instance = originalPaths;
    await deleteTestTempDir(root);
  });

  test(
    'receive imports the real pack and automatically links both progress directions',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final source = await library.createCollection('课程', null);
        final nested = await library.createCollection('第一章', source.id);
        final file = await File(
          p.join(root.path, 'lesson.mp4'),
        ).writeAsBytes(List.generate(256 * 1024, (index) => index % 251));
        final video = VideoItem(
          id: 'source-video',
          path: file.path,
          title: '课程视频',
          durationMs: 100000,
          lastPositionMs: 42000,
          lastUpdated: 1,
          parentId: nested.id,
          hasProbedChapters: true,
        );
        await library.addSingleVideo(video, useOriginalPath: true);
        final senderStore = MemoryProgressSyncStore();
        final receiverStore = MemoryProgressSyncStore();
        final sender = ProgressSyncService(
          library: library,
          store: senderStore,
        );
        final receiver = ProgressSyncService(
          library: library,
          store: receiverStore,
        );
        try {
          await sender.init();
          await receiver.init();
          await sender.renameDevice('电脑');
          await receiver.renameDevice('手机');
          await sender.setEnabled(true);
          await receiver.setEnabled(true);
          final peer = await sender.lan!.connectAddress(
            '127.0.0.1:${receiver.lan!.port}',
          );
          final pairing = await sender.lan!.requestPair(peer);
          await sender.lan!.approvePair(pairing.id, expectedCode: pairing.code);
          await receiver.lan!.approvePair(
            pairing.id,
            expectedCode: pairing.code,
          );
          await sender.sendFolder(source.id, peer.id);
          await _until(() => receiver.folderTransfers.isNotEmpty);
          final incoming = receiver.folderTransfers.single;
          expect(incoming.phase, FolderTransferPhase.offered);
          expect(sender.bindings, isEmpty);
          expect(receiver.bindings, isEmpty);
          expect(library.storageVideos.length, 1);
          await receiver.acceptFolderTransfer(incoming.id);
          await _until(
            () => incoming.phase == FolderTransferPhase.completed,
            reason: 'receiver: ${incoming.phase} ${incoming.error}',
          );
          await _until(
            () =>
                sender.folderTransfers.single.phase ==
                FolderTransferPhase.completed,
          );
          final destinationId = incoming.targetCollectionId!;
          expect(destinationId, isNot(source.id));
          expect(receiver.bindings.single.collectionId, destinationId);
          expect(sender.bindings.single.collectionId, source.id);
          final receivedVideo = library.mediaInFolderTree(destinationId).single;
          expect(
            await File(receivedVideo.path).readAsBytes(),
            await file.readAsBytes(),
          );
          expect(receivedVideo.lastPositionMs, 42000);
          expect(receiver.conflicts, isEmpty);
          expect(incoming.completedBytes, incoming.totalBytes);

          // The delivered copy now owns the same logical progress stream.
          await library.updateVideoProgress(receivedVideo.id, 9000);
          await receiver.flush();
          await receiver.syncNow();
          expect(video.lastPositionMs, 9000);
          await library.updateVideoProgress(video.id, 18000);
          await sender.flush();
          await sender.syncNow();
          expect(receivedVideo.lastPositionMs, 18000);

          // Sending again reuses the receiving folder and keeps the linked item.
          await sender.sendFolder(source.id, peer.id);
          await _until(() => receiver.folderTransfers.length == 2);
          final repeat = receiver.folderTransfers.firstWhere(
            (t) => t.id != incoming.id,
          );
          await receiver.acceptFolderTransfer(repeat.id);
          await _until(
            () => repeat.phase == FolderTransferPhase.completed,
            reason: 'repeat: ${repeat.phase} ${repeat.error}',
          );
          expect(repeat.targetCollectionId, destinationId);
          expect(repeat.totalBytes, lessThan(incoming.totalBytes ~/ 2));
          expect(
            library.mediaInFolderTree(destinationId).single.id,
            receivedVideo.id,
          );
          expect(library.storageVideos.length, 2);
          expect(receiver.conflicts, isEmpty);
        } finally {
          await sender.setEnabled(false);
          await receiver.setEnabled(false);
          sender.dispose();
          receiver.dispose();
        }
      }, _DirectHttp());
    },
    timeout: const Timeout(Duration(seconds: 65)),
  );

  test(
    'disabled restart retains received offers and allows offline rejection',
    () async {
      final offer = FolderTransferTask(
        id: 'transfer-pending-123',
        direction: FolderTransferDirection.receive,
        peerId: 'my-computer',
        peerName: '电脑',
        sourceCollectionId: 'course',
        folderName: '课程',
        createdAt: DateTime.now(),
        phase: FolderTransferPhase.offered,
        mediaCount: 1,
        estimatedBytes: 4000,
      );
      final store = MemoryProgressSyncStore()
        ..value = {
          'version': 1,
          'enabled': false,
          'folderTransfers': {
            'tasks': [offer.toJson()],
            'targets': <String, String>{},
          },
        };
      final sync = ProgressSyncService(library: library, store: store);
      try {
        await sync.init();
        expect(sync.enabled, isFalse);
        expect(sync.folderTransfers.single.phase, FolderTransferPhase.offered);
        await sync.rejectFolderTransfer(offer.id);
        expect(sync.enabled, isFalse);
        expect(
          sync.folderTransfers.single.phase,
          FolderTransferPhase.cancelled,
        );
        expect(
          ((store.value!['folderTransfers'] as Map)['tasks'] as List)
              .single['phase'],
          'cancelled',
        );
        expect(sync.lan?.isRunning, isFalse);
      } finally {
        sync.dispose();
      }
    },
  );
}
