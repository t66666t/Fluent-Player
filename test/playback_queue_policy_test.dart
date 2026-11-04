import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

VideoItem _item(
  String id,
  String path, {
  MediaSourceRef? sourceRef,
  bool isRecycled = false,
}) {
  return VideoItem(
    id: id,
    path: path,
    title: id,
    durationMs: 0,
    lastUpdated: 0,
    sourceRef: sourceRef,
    isRecycled: isRecycled,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'queue excludes missing locals and all virtual Bilibili streams',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'playback_queue_policy_',
      );
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });

      final localFile = File(
        '${sandbox.path}${Platform.pathSeparator}local.mp4',
      );
      await localFile.writeAsBytes(<int>[0]);
      final local = _item('local', localFile.path);
      final missing = _item(
        'missing',
        '${sandbox.path}${Platform.pathSeparator}missing.mp4',
      );
      final bilibili = _item(
        'bilibili',
        'bilibili://stream/BV1TEST?cid=100',
        sourceRef: const MediaSourceRef(
          value: 'bilibili://stream/BV1TEST?cid=100',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1TEST',
          cid: 100,
        ),
      );
      final invalidBilibili = _item(
        'invalid-bilibili',
        'bilibili://stream/BV1INVALID',
        sourceRef: const MediaSourceRef(
          value: 'bilibili://stream/BV1INVALID',
          kind: MediaSourceKind.bilibiliStream,
          bvid: 'BV1INVALID',
        ),
      );

      final manager = PlaylistManager();
      manager.setPlaylist(<VideoItem>[
        local,
        missing,
        bilibili,
        invalidBilibili,
      ]);

      expect(manager.playlist.map((item) => item.id), <String>['local']);
      expect(manager.currentIndex, 0);
      expect(manager.getNext(), isNull);
      expect(
        SystemMediaSessionService.instance.buildQueueItemIdsForTesting(
          playlistManager: manager,
        ),
        <String>['local'],
      );

      manager.setCurrentIndex(1);
      expect(manager.currentIndex, 0);
      expect(manager.getPrevious(), isNull);
      expect(manager.hasNext, isFalse);
    },
  );

  test('direct-open missing item is detached from the queue', () {
    final existing = <String>{'local-a', 'local-b'};
    final manager = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: existing.contains),
    );
    final first = _item('first', 'local-a');
    final missing = _item('missing', 'missing-path');
    final last = _item('last', 'local-b');

    manager.setPlaylist(<VideoItem>[
      first,
      missing,
      last,
    ], currentItemId: missing.id);

    expect(manager.playlist.map((item) => item.id), <String>['first', 'last']);
    expect(manager.anchoredItemId, missing.id);
    expect(manager.isCurrentItemDetached, isTrue);
    expect(manager.currentIndex, -1);
    expect(manager.hasPrevious, isFalse);
    expect(manager.hasNext, isFalse);

    existing.add('missing-path');
    manager.refreshQueueEligibility();
    expect(manager.playlist.map((item) => item.id), <String>[
      'first',
      'missing',
      'last',
    ]);
    expect(manager.currentIndex, 1);
    expect(manager.isCurrentItemDetached, isFalse);
  });

  test('queue revision and filtered index change atomically', () {
    final existing = <String>{'a', 'b'};
    final manager = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: existing.contains),
    );
    final first = _item('first', 'a');
    final second = _item('second', 'b');
    manager.setPlaylist(<VideoItem>[first, second], startIndex: 1);
    final originalRevision = manager.revision;

    existing.remove('a');
    manager.revalidatePlaylist();

    expect(manager.revision, originalRevision + 1);
    expect(manager.playlist.map((item) => item.id), <String>['second']);
    expect(manager.currentIndex, 0);
    expect(manager.snapshot.indexOf('second'), 0);
  });

  test('recycle-bin directory keeps recycled siblings in the queue', () {
    final existing = <String>{'root-a', 'root-b', 'missing'};
    final manager = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: existing.contains),
    );
    final first = _item('first', 'root-a', isRecycled: true);
    final second = _item('second', 'root-b', isRecycled: true);
    final missing = _item('gone', 'missing-file', isRecycled: true);
    final outsider = _item('outsider', 'root-a', isRecycled: true);

    manager.setPlaylist(<VideoItem>[first, second], currentItemId: first.id);
    expect(manager.playlist, isEmpty);
    expect(manager.isQueueEligible(first), isFalse);

    manager.setRecycleBinPlaylist(
      <VideoItem>[first, missing, second],
      currentItemId: second.id,
      folderId: 'folder',
    );

    expect(manager.playlist.map((item) => item.id), <String>[
      'first',
      'second',
    ]);
    expect(manager.currentIndex, 1);
    expect(manager.getPrevious()?.id, 'first');
    expect(manager.hasNext, isFalse);
    expect(manager.isQueueEligible(first), isTrue);
    expect(manager.isQueueEligible(second), isTrue);
    expect(manager.isQueueEligible(outsider), isFalse);
    expect(manager.snapshot.folderId, 'folder');

    manager.refreshQueueEligibility();
    expect(manager.playlist.map((item) => item.id), <String>[
      'first',
      'second',
    ]);
    expect(manager.currentIndex, 1);

    manager.reloadPlaylist();
    expect(manager.playlist.map((item) => item.id), <String>[
      'first',
      'second',
    ]);

    manager.setPlaylist(<VideoItem>[first, second], currentItemId: first.id);
    expect(manager.playlist, isEmpty);
    expect(manager.isQueueEligible(first), isFalse);
  });
}
