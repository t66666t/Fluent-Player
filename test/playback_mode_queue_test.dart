import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/playback_queue_order.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/system_media_session_service.dart';

class _MemoryModeStore extends PlaybackStateStore {
  Map<String, dynamic>? value;

  @override
  Future<Map<String, dynamic>?> read() async => value;

  @override
  Future<void> write(Map<String, dynamic> snapshot) async {
    value = snapshot;
  }
}

class _DelayedModeStore extends _MemoryModeStore {
  final ready = Completer<Map<String, dynamic>?>();
  @override
  Future<Map<String, dynamic>?> read() => ready.future;
}

List<VideoItem> items(String prefix, [int count = 8]) => [
  for (var i = 0; i < count; i++)
    VideoItem(
      id: '$prefix$i',
      path: '/$prefix/$i.mp4',
      title: 'Episode $i',
      durationMs: 60000,
      lastUpdated: 0,
    ),
];

PlaylistManager manager([PlaybackStateStore? store]) => PlaylistManager(
  queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
  modeStore: store,
);

String? move(PlaylistManager queue, int direction, {bool wrap = false}) {
  final navigation = queue.planNavigation([direction], wrap: wrap);
  if (navigation == null) return null;
  queue.prepareNavigation(navigation);
  queue.anchorCurrentItem(navigation.item);
  return navigation.item.id;
}

void main() {
  test('a newly selected overlapping playlist starts in sequential mode', () {
    final first = items('overlap');
    final queue = manager()..setPlaylist(first);
    queue.setPlaybackMode(PlaybackMode.shuffle);
    queue.setPlaylist([...first.skip(1), ...items('new', 2)]);
    expect(queue.playbackMode, PlaybackMode.sequential);
    expect(queue.currentItem, first[1]);
  });

  test('a late disk restore cannot overwrite a newly selected mode', () async {
    final source = items('late');
    final saved = _MemoryModeStore();
    final original = manager(saved);
    await original.initializePlaybackModes();
    original.setPlaylist(source);
    original.setPlaybackMode(PlaybackMode.shuffle);
    await original.flushPlaybackModes();
    final delayed = _DelayedModeStore();
    final restored = manager(delayed)..setPlaylist(source);
    final loading = restored.initializePlaybackModes();
    restored.setPlaybackMode(PlaybackMode.repeatOne);
    delayed.ready.complete(saved.value);
    await loading;
    expect(restored.playbackMode, PlaybackMode.repeatOne);
    expect(restored.currentItem, source.first);
  });

  test(
    'long queue previews stay stable and returning sources remain navigable',
    () {
      final source = items('large', 10000);
      final queue = manager()..setPlaylist(source);
      queue.setPlaybackMode(PlaybackMode.shuffle);
      final next = queue.relativeItem(next: true);
      for (var i = 0; i < 1000; i++) {
        expect(queue.relativeItem(next: true), same(next));
      }
      queue.setPlaylist(
        source.skip(1).toList(),
        currentItemId: source.first.id,
      );
      expect(queue.currentItem, isNull);
      queue.appendPlaylistItems([source.first]);
      expect(queue.currentItem, source.first);
      expect(queue.relativeItem(next: true), isNotNull);
      expect(queue.relativeItem(next: true)!.id, isNot(source.first.id));
    },
  );
  test(
    'random order is consumed once, while source order and previews stay stable',
    () {
      for (var seed = 0; seed < 30; seed++) {
        final order = PlaybackQueueOrder(seed: seed);
        final source = List.generate(18, (i) => '$i');
        order.synchronize(source, '0');
        order.setMode(PlaybackMode.shuffle);
        final seen = <String>{'0'};
        while (true) {
          final queue = order.queueIds;
          final preview = order.copy().move(1, wrap: false);
          expect(order.copy().move(1, wrap: false), preview);
          expect(order.queueIds, queue);
          if (preview == null) break;
          expect(queue[queue.indexOf(order.currentId!) + 1], preview);
          expect(seen.add(order.move(1, wrap: false)!), isTrue);
        }
        expect(seen, source.toSet());
        final last = order.currentId;
        final expected = order.copy().move(1, wrap: true);
        expect(order.move(1, wrap: true), expected);
        expect(order.currentId, isNot(last));
        seen.clear();
        seen.add(order.currentId!);
        while (true) {
          final id = order.move(1, wrap: false);
          if (id == null) break;
          expect(seen.add(id), isTrue);
        }
        expect(seen, source.toSet());
      }
    },
  );

  test('previous follows actual history and next returns to the same item', () {
    final queue = manager()..setPlaylist(items('history'));
    queue.setPlaybackMode(PlaybackMode.shuffle);
    expect(
      SystemMediaSessionService.instance.buildQueueItemIdsForTesting(
        playlistManager: queue,
      ),
      queue.playbackQueue.map((item) => item.id),
    );
    final original = queue.currentItem!.id;
    final first = move(queue, 1);
    final second = move(queue, 1);
    expect(move(queue, -1), first);
    expect(move(queue, -1), original);
    expect(move(queue, -1, wrap: true), isNull);
    expect(move(queue, 1), first);
    expect(move(queue, 1), second);
    expect(
      queue.playbackQueue[queue.playbackIndex + 1].id,
      queue.relativeItem(next: true)!.id,
    );
  });

  test(
    'mode switches preserve selection; repeat-one manual skips use source order',
    () {
      final source = items('source');
      final queue = manager()..setPlaylist(source, startIndex: 3);
      queue.setPlaybackMode(PlaybackMode.shuffle);
      expect(queue.currentItem, source[3]);
      expect(queue.playlist, source);
      queue.setPlaybackMode(PlaybackMode.repeatOne);
      expect(queue.currentItem, source[3]);
      expect(queue.playbackQueue, source);
      expect(move(queue, 1), source[4].id);
      expect(move(queue, -1), source[3].id);
      queue.setPlaybackMode(PlaybackMode.sequential);
      expect(queue.playbackQueue, source);
      expect(queue.currentItem, source[3]);
    },
  );

  test(
    'direct selection consumes the item without reshuffling the remainder',
    () {
      final queue = manager()..setPlaylist(items('direct'));
      queue.setPlaybackMode(PlaybackMode.shuffle);
      final before = queue.playbackQueue.skip(queue.playbackIndex + 1).toList();
      final selected = before[3];
      queue.anchorCurrentItem(selected);
      final after = queue.playbackQueue.skip(queue.playbackIndex + 1).toList();
      expect(after, before.where((item) => item.id != selected.id));
      expect(queue.relativeItem(next: true)!.id, after.first.id);
      expect(move(queue, -1), 'direct0');
      expect(move(queue, 1), selected.id);
    },
  );

  test(
    'queue edits keep the random remainder in order and append new items',
    () {
      final source = items('edit');
      final queue = manager()..setPlaylist(source);
      queue.setPlaybackMode(PlaybackMode.shuffle);
      move(queue, 1);
      final before = queue.playbackQueue.skip(queue.playbackIndex + 1).toList();
      final removed = before[2];
      final added = items('added', 2);
      queue.setPlaylist([
        ...source.where((item) => item.id != removed.id),
        ...added,
      ], currentItemId: queue.currentItem!.id);
      final after = queue.playbackQueue.skip(queue.playbackIndex + 1).toList();
      expect(
        after.take(before.length - 1),
        before.where((item) => item.id != removed.id),
      );
      expect(
        after.skip(before.length - 1).map((item) => item.id).toSet(),
        added.map((item) => item.id).toSet(),
      );
      expect(
        queue.playbackQueue.map((item) => item.id).toSet().length,
        queue.playbackQueue.length,
      );
    },
  );

  test(
    'queue modes, random history and upcoming order survive restore',
    () async {
      final store = _MemoryModeStore();
      final source = items('restore');
      final queue = manager(store);
      await queue.initializePlaybackModes();
      queue.setPlaylist(source);
      queue.setPlaybackMode(PlaybackMode.shuffle);
      move(queue, 1);
      final previous = queue.currentItem!.id;
      move(queue, 1);
      final selected = queue.currentItem!.id;
      final expected = queue.playbackQueue.map((item) => item.id).toList();
      await queue.flushPlaybackModes();
      final restored = manager(store);
      await restored.initializePlaybackModes();
      restored.setPlaylist(source, currentItemId: selected);
      expect(restored.playbackMode, PlaybackMode.shuffle);
      expect(restored.playbackQueue.map((item) => item.id), expected);
      expect(move(restored, -1), previous);
      expect(move(restored, 1), selected);
      restored.setPlaylist(items('another'));
      expect(restored.playbackMode, PlaybackMode.sequential);
      restored.setPlaylist(source, currentItemId: selected);
      expect(restored.playbackMode, PlaybackMode.shuffle);
    },
  );

  test(
    'batched plans do not publish a cursor before the player accepts them',
    () {
      final queue = manager()..setPlaylist(items('batch'));
      queue.setPlaybackMode(PlaybackMode.shuffle);
      final before = queue.currentItem;
      final expected = queue.playbackQueue[queue.playbackIndex + 3];
      final plan = queue.planNavigation([1, 1, 1])!;
      expect(plan.item, expected);
      expect(queue.currentItem, before);
      queue.prepareNavigation(plan);
      expect(queue.currentItem, before);
      queue.anchorCurrentItem(plan.item);
      expect(queue.currentItem, expected);
      expect(move(queue, -1), before!.id);
    },
  );

  test('one-item and detached queues never enable manual skips', () {
    final queue = manager()..setPlaylist(items('one', 1));
    for (final mode in PlaybackMode.values) {
      queue.setPlaybackMode(mode);
      expect(queue.relativeItem(next: true, wrap: true), isNull);
      expect(queue.relativeItem(next: false, wrap: true), isNull);
      expect(
        queue.relativeItem(
          next: true,
          wrap: true,
          includeCurrentAfterWrap: true,
        ),
        queue.currentItem,
      );
    }
    queue.anchorCurrentItem(items('detached', 1).first);
    expect(queue.currentItem, isNull);
    expect(queue.relativeItem(next: true, wrap: true), isNull);
  });
}
