import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/features/cloud_drive/models/cloud_drive_models.dart';
import 'package:video_player_app/features/cloud_drive/services/cloud_drive_launch_coordinator.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/playback_mode.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_queue_policy.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/playlist_manager.dart';

VideoItem _item(String id) => VideoItem(
  id: id,
  title: id,
  path: '/$id.mp4',
  durationMs: 1000,
  lastUpdated: 0,
);

class _Store extends PlaybackStateStore {
  Map<String, dynamic>? value;
  Completer<Map<String, dynamic>?>? gate;
  @override
  Future<Map<String, dynamic>?> read() async =>
      gate == null ? value : gate!.future;
  @override
  Future<void> write(Map<String, dynamic> snapshot) async => value = snapshot;
}

class _Library implements LibraryService {
  List<VideoItem> items = [];
  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #getVideosInFolder) return List<VideoItem>.of(items);
    if (i.memberName == #cloudDriveThumbnails) return null;
    if (i.memberName == #upsertCloudDriveCard) {
      final source = i.namedArguments[#source] as MediaSourceRef;
      final item = _item(source.cloudDrive!.fileId)..sourceRef = source;
      return Future<VideoItem>.value(item);
    }
    return super.noSuchMethod(i);
  }
}

class _Playback implements MediaPlaybackService {
  @override
  Future<List<VideoItem>> Function()? cloudDriveLoadNextPlaylistPage;
  @override
  Future<void> Function()? cloudDrivePreparePlaylist;
  @override
  bool Function()? cloudDriveQueueNeedsCompletion;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

CloudDriveEntry _cloudEntry(String id) => CloudDriveEntry(
  providerId: 'provider',
  accountLocalId: 'account',
  remoteAccountId: 'remote',
  driveId: 'drive',
  fileId: id,
  parentFileId: 'folder',
  name: id,
  kind: CloudDriveEntryKind.video,
);

PlaylistManager _queue({_Store? store}) => PlaylistManager(
  queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => true),
  modeStore: store ?? _Store(),
);

List<String> _ids(PlaylistManager queue) =>
    queue.playlist.map((e) => e.id).toList();

void main() {
  test('empty queue adds and anchors the imported item', () {
    final queue = _queue();
    final item = _item('new');
    expect(queue.prepareImportedPlayback(item), isTrue);
    expect(_ids(queue), ['new']);
    expect(queue.currentItem, same(item));
  });

  for (final mode in PlaybackMode.values) {
    test('$mode keeps the current queue and mode on import', () {
      final a = _item('a'), b = _item('b'), c = _item('c');
      final owner = Object();
      final queue = _queue()..setPlaylist([a, b], owner: owner);
      queue.setPlaybackMode(mode);
      final before = queue.playbackQueue.map((e) => e.id).toList();
      expect(queue.prepareImportedPlayback(c), isTrue);
      expect(_ids(queue), ['a', 'b', 'c']);
      expect(
        queue.playbackQueue.where((e) => e.id != 'c').map((e) => e.id),
        before,
      );
      expect(queue.currentItem, same(c));
      expect(queue.playbackMode, mode);
      expect(queue.queueOwner, isNull);
      queue.anchorCurrentItem(c); // The real player anchors after opening.
      queue.prepareImportedPlayback(c);
      expect(_ids(queue), ['a', 'b', 'c']);
      queue.prepareImportedPlayback(b);
      expect(_ids(queue), ['a', 'b', 'c']);
      expect(queue.currentItem, same(b));
      expect(queue.playbackMode, mode);
    });
  }

  test('an imported item outside a folder freezes its existing queue', () {
    final a = _item('a'), b = _item('b'), c = _item('c');
    final library = _Library()..items = [a, b];
    final queue = _queue()..initialize(libraryService: library);
    queue.loadFolderPlaylist('original-folder', a.id);
    queue.prepareImportedPlayback(c);
    library.items = [_item('unrelated')];
    queue.reloadPlaylist();
    queue.refreshQueueEligibility();
    queue.anchorCurrentItem(c);
    expect(_ids(queue), ['a', 'b', 'c']);
    expect(queue.currentItem, same(c));
    expect(queue.snapshot.folderId, isNull);
  });

  test('opening an existing owned item keeps directory ownership', () {
    final a = _item('a'), b = _item('b');
    final owner = Object();
    final queue = _queue()..setPlaylist([a, b], owner: owner);
    queue.prepareImportedPlayback(b);
    expect(queue.queueOwner, same(owner));
    expect(_ids(queue), ['a', 'b']);
  });

  test(
    'a real pending cloud page cannot replace a mixed imported queue',
    () async {
      final queue = _queue();
      final playback = _Playback();
      final launch = CloudDriveLaunchCoordinator(
        library: _Library(),
        playlist: queue,
        playback: playback,
      );
      final page = Completer<List<CloudDriveEntry>>();
      await launch.prepareEntry(
        entry: _cloudEntry('cloud-a'),
        visibleEntries: [_cloudEntry('cloud-a'), _cloudEntry('cloud-b')],
        loadNextPage: () => page.future,
      );
      final loading = playback.cloudDriveLoadNextPlaylistPage!();
      final imported = _item('imported');
      queue.prepareImportedPlayback(imported);
      page.complete([_cloudEntry('late-cloud-c')]);
      expect(await loading, isEmpty);
      expect(_ids(queue), ['cloud-a', 'cloud-b', 'imported']);
      expect(queue.currentItem, same(imported));
      launch.dispose();
    },
  );

  test('opening an existing item refreshes its data without duplication', () {
    final a = _item('a'), b = _item('b');
    final queue = _queue()..setPlaylist([a, b]);
    final updated = _item('b')..title = 'Renamed in library';
    queue.prepareImportedPlayback(updated);
    expect(_ids(queue), ['a', 'b']);
    expect(queue.currentItem, same(updated));
  });

  test('explicit reopen restores only the requested removed queue item', () {
    final a = _item('a'), b = _item('b'), c = _item('c');
    final owner = Object();
    final queue = _queue()..setPlaylist([a, b, c], owner: owner);
    queue.removeFromQueue(b.id);
    queue.removeFromQueue(c.id);
    queue.prepareImportedPlayback(b);
    queue.appendPlaylistItems([b, c]);
    expect(_ids(queue), ['a', 'b']);
    expect(queue.currentItem, same(b));
  });

  test('shuffle retains committed previous history after an import', () {
    final a = _item('a'), b = _item('b'), c = _item('c');
    final queue = _queue()..setPlaylist([a, b]);
    queue.setPlaybackMode(PlaybackMode.shuffle);
    queue.prepareImportedPlayback(c);
    final previous = queue.planNavigation([-1], wrap: false)!;
    expect(previous.item.id, a.id);
    queue.prepareNavigation(previous);
    queue.anchorCurrentItem(previous.item);
    expect(queue.getNext()?.id, c.id);
  });

  test(
    'late saved modes cannot replace the queue built by a title click',
    () async {
      final a = _item('a'), b = _item('b');
      final saved = _Store();
      final old = _queue(store: saved);
      await old.initializePlaybackModes();
      old.setPlaylist([a, b]);
      old.setPlaybackMode(PlaybackMode.shuffle);
      await old.flushPlaybackModes();
      final store = _Store()..gate = Completer<Map<String, dynamic>?>();
      final queue = _queue(store: store)..setPlaylist([a]);
      final loading = queue.initializePlaybackModes();
      queue.prepareImportedPlayback(b);
      store.gate!.complete(saved.value);
      await loading;
      expect(queue.playbackMode, PlaybackMode.sequential);
      expect(_ids(queue), ['a', 'b']);
      expect(queue.currentItem, same(b));
    },
  );

  test('missing or recycled sources leave the active queue unchanged', () {
    final queue = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(
        sourceExists: (path) => path == '/a.mp4',
      ),
      modeStore: _Store(),
    )..setPlaylist([_item('a')]);
    final revision = queue.revision;
    expect(queue.prepareImportedPlayback(_item('missing')), isFalse);
    final recycled = _item('a')..isRecycled = true;
    expect(queue.prepareImportedPlayback(recycled), isFalse);
    expect(queue.revision, revision);
    expect(_ids(queue), ['a']);
  });

  test('online Bilibili cards are eligible without a local file', () {
    final item = _item('online')
      ..path = 'bilibili://BV-Test/123'
      ..sourceRef = const MediaSourceRef(
        value: 'https://www.bilibili.com/video/BV-Test',
        kind: MediaSourceKind.bilibiliStream,
        bvid: 'BV-Test',
        cid: 123,
      );
    final queue = PlaylistManager(
      queuePolicy: PlaybackQueuePolicy(sourceExists: (_) => false),
      modeStore: _Store(),
    );
    expect(queue.prepareImportedPlayback(item), isTrue);
    expect(queue.currentItem, same(item));
  });
}
