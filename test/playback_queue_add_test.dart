import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/cloud_drive_source_ref.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_queue_add_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';

class _Store extends PlaybackStateStore {
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> read() async => saved;
  @override
  Future<void> write(Map<String, dynamic> value) async {
    saved = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }
}

VideoItem item(String id, {String? path, MediaSourceRef? source}) => VideoItem(
  id: id,
  path: path ?? '/media/$id.mp4',
  title: id,
  durationMs: 60000,
  lastPositionMs: 12345,
  lastUpdated: 1,
  sourceRef: source,
);

PlaylistManager _queue([_Store? store]) => PlaylistManager(
  modeStore: store ?? _Store(),
  queuePolicy: PlaybackQueuePolicy(
    sourceExists: (path) => !path.contains('missing'),
  ),
);

String? move(PlaylistManager queue, int direction, {bool wrap = false}) {
  final next = queue.planNavigation([direction], wrap: wrap);
  if (next == null) return null;
  queue.prepareNavigation(next);
  queue.anchorCurrentItem(next.item);
  return next.item.id;
}

void main() {
  test('additions never select the first item of an idle queue', () {
    final q = _queue();
    q.addToPlaybackQueue([item('a'), item('b')]);
    expect(q.playlist.map((e) => e.id), ['a', 'b']);
    expect(q.currentItem, isNull);
    expect(q.anchoredItemId, isNull);
    expect(q.playbackIndex, -1);
    expect(q.hasManualQueue, isTrue);
  });

  for (final mode in PlaybackMode.values) {
    test('$mode: preserve cursor, bookmark and mode while appending', () {
      final current = item('a');
      final q = _queue()..setPlaylist([current, item('b')]);
      q.setPlaybackMode(mode);
      final result = q.addToPlaybackQueue([item('c'), item('d')]);
      expect(result.added, ['c', 'd']);
      expect(q.currentItem, same(current));
      expect(current.lastPositionMs, 12345);
      expect(q.playbackMode, mode);
      expect(q.playlist.map((e) => e.id), ['a', 'b', 'c', 'd']);
    });
  }

  test('deduplicates aliases and batch repeats, never by title', () {
    final q = _queue()..setPlaylist([item('a')]);
    final result = q.addToPlaybackQueue([
      item('alias', path: '/media/a.mp4'),
      item('b'),
      item('b'),
      item('missing'),
      item('c')..isRecycled = true,
    ]);
    expect(result.added, ['b']);
    expect(result.duplicates, 2);
    expect(result.failed, ['missing', 'c']);
    expect(q.playlist.map((e) => e.id), ['a', 'b']);
    final revision = q.revision;
    q.addToPlaybackQueue([item('a')]);
    expect(q.revision, revision);
  });

  test('different pages deduplicate by stable Bilibili and cloud identity', () {
    const bili = MediaSourceRef(
      value: 'BV1xx411c7mD',
      kind: MediaSourceKind.bilibiliStream,
      bvid: 'BV1xx411c7mD',
      cid: 100,
      page: 1,
    );
    const cloud = MediaSourceRef(
      value: 'cloud',
      kind: MediaSourceKind.cloudDrive,
      cloudDrive: CloudDriveSourceRef(
        providerId: 'quark',
        remoteAccountId: 'account',
        driveId: 'drive',
        fileId: 'file',
      ),
    );
    final q = _queue();
    final result = q.addToPlaybackQueue([
      item('bili1', source: bili),
      item('bili2', source: bili),
      item('bili3', source: bili.copyWith(cid: 101, page: 2)),
      item('cloud1', source: cloud),
      item('cloud2', source: cloud),
    ]);
    expect(result.added, ['bili1', 'bili3', 'cloud1']);
    expect(result.duplicates, 2);
  });

  test('shuffle preserves old upcoming order and actual previous history', () {
    final q = _queue()
      ..setPlaylist([for (var i = 0; i < 8; i++) item('old$i')]);
    q.setPlaybackMode(PlaybackMode.shuffle);
    final first = move(q, 1);
    final second = move(q, 1);
    final upcoming = q.playbackQueue
        .skip(q.playbackIndex + 1)
        .map((e) => e.id)
        .toList();
    q.addToPlaybackQueue([item('new1'), item('new2'), item('new3')]);
    final after = q.playbackQueue
        .skip(q.playbackIndex + 1)
        .map((e) => e.id)
        .toList();
    expect(after.take(upcoming.length), upcoming);
    expect(after.skip(upcoming.length).toSet(), {'new1', 'new2', 'new3'});
    expect(move(q, -1), first);
    expect(move(q, 1), second);
    final played = <String>{'old0', first!, second!};
    while (true) {
      final next = move(q, 1);
      if (next == null) break;
      expect(played.add(next), isTrue);
    }
    expect(played.length, 11);
    expect(move(q, 1, wrap: true), isNotNull);
    q.setPlaybackMode(PlaybackMode.sequential);
    expect(q.playbackQueue.map((e) => e.id), [
      for (var i = 0; i < 8; i++) 'old$i',
      'new1',
      'new2',
      'new3',
    ]);
  });

  test(
    'custom order keeps additions at the end and undo preserves edits/current',
    () {
      final q = _queue()..setPlaylist([item('a'), item('b')]);
      q.reorderQueue(['b', 'a']);
      q.addToPlaybackQueue([item('c'), item('d')]);
      expect(q.playbackQueue.map((e) => e.id), ['b', 'a', 'c', 'd']);
      q.anchorCurrentItem(q.playlist.firstWhere((e) => e.id == 'c'));
      q.reorderQueue(['d', 'b', 'c', 'a']);
      expect(q.undoLastQueueAddition(), isTrue);
      expect(q.playbackQueue.map((e) => e.id), ['b', 'c', 'a']);
      expect(q.currentItem?.id, 'c');
      expect(q.hasCustomOrder, isTrue);
    },
  );

  test('freezes source ownership; explicit queue switch invalidates undo', () {
    final owner = Object();
    final q = _queue()..setPlaylist([item('a')], owner: owner);
    final epoch = q.queueEpoch;
    q.addToPlaybackQueue([item('b')]);
    expect(q.queueOwner, isNull);
    expect(q.queueEpoch, epoch);
    q.setPlaylist([item('other')]);
    expect(q.queueEpoch, isNot(epoch));
    expect(q.canUndoQueueAddition, isFalse);
  });

  test('reopening the former source is a new queue even with the same current item', () {
    final q = _queue()..setPlaylist([item('a'), item('b')], owner: Object());
    q.addToPlaybackQueue([item('c')]);
    final epoch = q.queueEpoch;
    q.setPlaylist([item('a'), item('b')], currentItemId: 'a', owner: Object());
    expect(q.hasManualQueue, isFalse);
    expect(q.queueEpoch, greaterThan(epoch));
    expect(q.playlist.map((e) => e.id), ['a', 'b']);
  });

  test(
    'slow batches commit in click order and keep the latest selected mode',
    () async {
      final q = _queue()..setPlaylist([item('a')]);
      final gate = Completer<void>();
      final progress1 = QueueAddProgress(), progress2 = QueueAddProgress();
      final service = PlaybackQueueAddService.of(q);
      final first = service.add((_) async {
        await gate.future;
        return QueueAddBatch(items: [item('b')]);
      }, progress1);
      final second = service.add(
        (_) async => QueueAddBatch(items: [item('c')]),
        progress2,
      );
      q.setPlaybackMode(PlaybackMode.repeatOne);
      gate.complete();
      expect((await first).added, ['b']);
      expect((await second).added, ['c']);
      expect(q.playlist.map((e) => e.id), ['a', 'b', 'c']);
      expect(q.playbackMode, PlaybackMode.repeatOne);
      progress1.dispose();
      progress2.dispose();
    },
  );

  test('cancel and queue switch discard prepared items atomically', () async {
    for (final cancel in [true, false]) {
      final q = _queue()..setPlaylist([item('a')]);
      final gate = Completer<void>(), started = Completer<void>();
      final progress = QueueAddProgress();
      final job = PlaybackQueueAddService.of(q).add((_) async {
        started.complete();
        await gate.future;
        return QueueAddBatch(items: [item('unwanted')]);
      }, progress);
      await started.future;
      if (cancel) {
        progress.cancel();
      } else {
        q.setPlaylist([item('other')]);
      }
      gate.complete();
      final result = await job;
      expect(cancel ? result.cancelled : result.queueChanged, isTrue);
      expect(q.playlist.map((e) => e.id), [cancel ? 'a' : 'other']);
      progress.dispose();
    }
  });

  test(
    'restart restores the mixed queue, shuffle history and upcoming order',
    () async {
      final store = _Store();
      final q = _queue(store);
      await q.initializePlaybackModes();
      q.setPlaylist([item('a'), item('b'), item('c')]);
      q.setPlaybackMode(PlaybackMode.shuffle);
      move(q, 1);
      q.addToPlaybackQueue([item('d'), item('e')]);
      await q.flushPlaybackModes();
      final restored = _queue(store);
      await restored.initializePlaybackModes();
      expect(restored.hasManualQueue, isTrue);
      expect(restored.playbackMode, PlaybackMode.shuffle);
      expect(restored.currentItem?.id, q.currentItem?.id);
      expect(
        restored.playbackQueue.map((e) => e.id),
        q.playbackQueue.map((e) => e.id),
      );
      expect(move(restored, -1), move(q, -1));
      expect(move(restored, 1), move(q, 1));
    },
  );

  test(
    'an unplayed queue restores without choosing a current media item',
    () async {
      final store = _Store();
      final q = _queue(store);
      await q.initializePlaybackModes();
      q.addToPlaybackQueue([item('a'), item('b')]);
      await q.flushPlaybackModes();
      final restored = _queue(store);
      await restored.initializePlaybackModes();
      expect(restored.playlist.length, 2);
      expect(restored.anchoredItemId, isNull);
      expect(restored.currentItem, isNull);
    },
  );
}
