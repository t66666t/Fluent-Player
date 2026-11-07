import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video_player_app/features/progress_sync/progress_sync_service.dart';
import 'package:video_player_app/features/progress_sync/progress_sync_store.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

/// Separate in-memory libraries model two installations. The production merge
/// service, encrypted LAN transport, pairing and filesystem digests are real.
class _DeviceLibrary extends ChangeNotifier implements LibraryService {
  _DeviceLibrary(this.folder, this.video);
  final VideoCollection folder;
  final VideoItem video;
  final _records = <String, MediaActivityRecord>{};
  final _observers = <LibraryProgressObserver>[];
  int remoteApplications = 0;

  // This deliberately minimal library adapter models progress persistence;
  // complete directory behavior is exercised by the real-library sync tests.
  @override
  bool get isInitialized => false;

  @override
  final activityRevision = ValueNotifier<int>(0);
  @override
  List<VideoCollection> get collections => [folder];
  @override
  List<VideoCollection> get storageCollections => [folder];
  @override
  List<VideoItem> get storageVideos => [video];
  @override
  List<ImportBatchRecord> get importBatches => [];
  @override
  VideoCollection? getCollection(String id) => id == folder.id ? folder : null;
  @override
  VideoItem? getVideo(String id) => id == video.id ? video : null;
  @override
  List<VideoItem> mediaInFolderTree(String id) =>
      id == folder.id ? [video] : [];
  @override
  MediaActivityRecord? mediaActivity(String id) => _records[id];
  @override
  void addProgressObserver(LibraryProgressObserver observer) =>
      _observers.add(observer);
  @override
  void removeProgressObserver(LibraryProgressObserver observer) =>
      _observers.remove(observer);
  @override
  Future<void> updateVideoProgress(String id, int positionMs) async {
    video.lastPositionMs = positionMs;
    for (final observer in List<LibraryProgressObserver>.of(_observers)) {
      observer(video, positionMs);
    }
  }

  @override
  Future<void> applySyncedPlaybackProgress({
    required String mediaId,
    required int positionMs,
    required bool completed,
    required bool continueEnrolled,
    required int accumulatedWatchMs,
    int? lastPlayedAtMs,
    bool persist = true,
  }) async {
    remoteApplications++;
    video.lastPositionMs = positionMs;
    final record = _records.putIfAbsent(
      mediaId,
      () => MediaActivityRecord(mediaId: mediaId),
    );
    record.completed = completed;
    record.continueEnrolled = continueEnrolled;
    record.accumulatedWatchMs = accumulatedWatchMs;
    record.lastPlayedAtMs = lastPlayedAtMs;
    if (persist) notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'two independent libraries pair, bind, continue, seek backward and resolve an offline conflict',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final root = await Directory.systemTemp.createTemp(
          'progress_sync_two_devices_',
        );
        final desktopFile = File(p.join(root.path, 'desktop-video.mp4'));
        final phoneFile = File(p.join(root.path, 'renamed-phone-video.mp4'));
        await desktopFile.writeAsBytes(
          List<int>.generate(8192, (i) => i % 251),
        );
        await desktopFile.copy(phoneFile.path);
        _DeviceLibrary device(String id, File file, int position) =>
            _DeviceLibrary(
              VideoCollection(
                id: '$id-folder',
                name: '$id课程',
                createTime: 1,
                childrenIds: ['$id-video'],
              ),
              VideoItem(
                id: '$id-video',
                path: file.path,
                title: '$id 中的标题',
                durationMs: 3600000,
                lastUpdated: 1,
                lastPositionMs: position,
                parentId: '$id-folder',
              ),
            );
        final desktopLibrary = device('desktop', desktopFile, 600000);
        final phoneLibrary = device('phone', phoneFile, 0);
        final desktopStore = MemoryProgressSyncStore();
        final phoneStore = MemoryProgressSyncStore();
        final desktop = ProgressSyncService(
          library: desktopLibrary,
          store: desktopStore,
        );
        final phone = ProgressSyncService(
          library: phoneLibrary,
          store: phoneStore,
        );
        try {
          await desktop.init();
          await phone.init();
          await desktop.renameDevice('电脑');
          await phone.renameDevice('手机');
          await desktop.setEnabled(true);
          await phone.setEnabled(true);
          expect(desktop.lan!.isRunning, isTrue);
          expect(phone.lan!.isRunning, isTrue);
          final peer = await desktop.lan!.connectAddress(
            '127.0.0.1:${phone.lan!.port}',
          );
          final pairing = await desktop.lan!.requestPair(peer);
          expect(phone.lan!.pairings.single.code, pairing.code);
          await desktop.lan!.approvePair(
            pairing.id,
            expectedCode: pairing.code,
          );
          await phone.lan!.approvePair(pairing.id, expectedCode: pairing.code);
          expect(desktop.pairedDevices.values, contains('手机'));
          expect(phone.pairedDevices.values, contains('电脑'));

          await desktop.shareFolder(desktopLibrary.folder.id, peer.id);
          final invitation = phone.invitations.single;
          await phone.acceptInvitation(
            invitation.groupId,
            phoneLibrary.folder.id,
          );
          expect(phoneLibrary.video.lastPositionMs, 600000);
          expect(phone.conflicts, isEmpty);
          final firstApplyCount = phoneLibrary.remoteApplications;
          final firstEventId =
              (phoneStore.value!['envelopes'] as List).single['eventId'];
          await phone.flush();
          await phone.syncNow();
          expect(
            (phoneStore.value!['envelopes'] as List).single['eventId'],
            firstEventId,
          );
          expect(phoneLibrary.remoteApplications, firstApplyCount);

          await desktopLibrary.updateVideoProgress(
            desktopLibrary.video.id,
            660000,
          );
          await desktop.flush();
          await desktop.syncNow();
          expect(phoneLibrary.video.lastPositionMs, 660000);
          await phoneLibrary.updateVideoProgress(phoneLibrary.video.id, 120000);
          await phone.flush();
          await phone.syncNow();
          expect(desktopLibrary.video.lastPositionMs, 120000);
          expect(desktop.conflicts, isEmpty);

          // Both devices watch offline from the same last accepted checkpoint.
          await desktop.setEnabled(false);
          await phone.setEnabled(false);
          await desktopLibrary.updateVideoProgress(
            desktopLibrary.video.id,
            180000,
          );
          await phoneLibrary.updateVideoProgress(phoneLibrary.video.id, 240000);
          await desktop.setEnabled(true);
          await desktop.syncNow();
          await phone.setEnabled(true);
          await phone.syncNow();
          await desktop.lan!.connectAddress('127.0.0.1:${phone.lan!.port}');
          await desktop.syncNow();
          final conflict = desktop.conflicts.single;
          expect(
            conflict.choices.map((event) => event.value.positionMs),
            unorderedEquals([180000, 240000]),
          );
          expect(phone.conflicts, hasLength(1));
          final choice = conflict.choices.firstWhere(
            (event) => event.value.positionMs == 240000,
          );
          await desktop.resolveConflict(conflict.id, choice.id);
          expect(desktopLibrary.video.lastPositionMs, 240000);
          expect(phoneLibrary.video.lastPositionMs, 240000);
          expect(desktop.conflicts, isEmpty);
          expect(phone.conflicts, isEmpty);
        } finally {
          await desktop.setEnabled(false);
          await phone.setEnabled(false);
          desktop.dispose();
          phone.dispose();
          desktopLibrary.dispose();
          phoneLibrary.dispose();
          await root.delete(recursive: true);
        }
      }, _RealHttpOverrides());
    },
    timeout: const Timeout(Duration(seconds: 35)),
  );
}
