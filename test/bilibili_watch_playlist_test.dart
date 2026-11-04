import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_collection.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cover_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_open_timeline.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_playlist.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/episode_picker_panel.dart';
import 'package:video_player_app/widgets/playlist_bottom_sheet.dart';

import 'test_dir_cleanup.dart';

void main() {
  group('the list', () {
    test('a newly opened video goes to the end; an opened one is gone back '
        'to, never listed twice', () {
      final list = BilibiliWatchPlaylist();
      list.open(bvid: 'BVa', page: 1, info: _info('BVa'));
      list.open(bvid: 'BVb', page: 1, info: _info('BVb', parts: 3));
      list.open(bvid: 'BVc', page: 1, info: _info('BVc'));
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb', 'BVc']);
      expect(list.currentBvid, 'BVc');

      list.open(bvid: 'BVb', page: 2, info: _info('BVb', parts: 3));
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb', 'BVc']);
      expect(list.currentBvid, 'BVb');
      expect(list.entryOf('BVb')!.page, 2);
    });

    test('a video with several parts is one entry', () {
      final list = BilibiliWatchPlaylist();
      list.open(bvid: 'BVb', page: 1, info: _info('BVb', parts: 3));
      expect(list.select('BVb', 3), isTrue);
      expect(list.entries, hasLength(1));
      expect(list.entryOf('BVb')!.page, 3);
    });

    test('at most 50: the oldest goes, the one after it when the oldest '
        'plays', () {
      final list = BilibiliWatchPlaylist();
      for (var i = 0; i < 50; i++) {
        list.open(bvid: 'BV$i', page: 1, info: _info('BV$i'));
      }
      list.open(
        bvid: 'BVnew',
        page: 1,
        info: _info('BVnew'),
        playingBvid: 'BV49',
      );
      expect(list.entries, hasLength(50));
      expect(list.entryOf('BV0'), isNull);
      expect(list.entries.first.bvid, 'BV1');
      expect(list.entries.last.bvid, 'BVnew');

      // The oldest one plays: the next oldest goes instead.
      list.select('BV1', 1);
      list.open(
        bvid: 'BVlast',
        page: 1,
        info: _info('BVlast'),
        playingBvid: 'BV1',
      );
      expect(list.entries, hasLength(50));
      expect(list.entries.first.bvid, 'BV1');
      expect(list.entryOf('BV2'), isNull);
    });

    test('clear keeps the video that plays', () {
      final list = BilibiliWatchPlaylist();
      list.open(bvid: 'BVa', page: 1, info: _info('BVa'));
      list.open(bvid: 'BVb', page: 1, info: _info('BVb'));
      list.clear(keepBvid: 'BVa');
      expect(list.entries.map((e) => e.bvid), ['BVa']);
      list.clear();
      expect(list.entries, isEmpty);
      expect(list.currentBvid, isNull);
    });

    test('it lives in memory only: a new app run starts empty', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final list = BilibiliWatchPlaylist();
      list.open(bvid: 'BVa', page: 1, info: _info('BVa'));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
      expect(BilibiliWatchPlaylist().entries, isEmpty);
    });
  });

  group('playing the list', () {
    late Directory root;
    late PathProviderPlatform originalPaths;
    late LibraryService library;
    late BilibiliDownloadService service;
    late PlaylistManager queue;
    late BilibiliWatchPlaylist list;
    late BilibiliWatchPlaylistSession session;
    late ValueNotifier<VideoItem?> playing;
    final history = BilibiliHistoryService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      history.resetForTest();
      root = await Directory.systemTemp.createTemp('bilibili_watch_list_');
      originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      SettingsService().largeDataRootPath = root.path;
      library = LibraryService()..resetLibraryForTesting();
      await library.init();
      service = BilibiliDownloadService(apiService: _Api());
      queue = PlaylistManager()..initialize(libraryService: library);
      list = BilibiliWatchPlaylist();
      playing = ValueNotifier<VideoItem?>(null);
      session = BilibiliWatchPlaylistSession(
        list: list,
        service: service,
        library: library,
        queue: queue,
        playbackChanges: playing,
        currentItem: () => playing.value,
      );
    });

    tearDown(() async {
      session.dispose();
      await service.shutdown();
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      SettingsService().largeDataRootPath = null;
      history.resetForTest();
      PathProviderPlatform.instance = originalPaths;
      await deleteTestTempDir(root);
    });

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(done(), isTrue);
    }

    /// Gets [bvid] ready as the loading page does and opens it: the list
    /// takes it, then it plays.
    Future<BilibiliWatchPlan> open(String bvid, {int? page}) async {
      final plan = await BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: bvid,
        page: page,
        history: history,
        fetchInfo: (id) async => _infos[id]!,
      )(BilibiliWatchAttempt(BilibiliOpenTimeline(bvid)));
      session.opened(plan);
      playing.value = plan.item;
      return plan;
    }

    List<String> titles() => <String>[
      for (final item in queue.playlist) item.title,
    ];

    Future<void> settled() =>
        until(() => queue.playlist.length == _expectedLength(list));

    test('opened videos line up; the playing one lists its parts', () async {
      await open('BVa');
      final b = await open('BVb');
      await settled();
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb']);
      expect(titles(), ['视频 BVa', 'BVb 第1部分', 'BVb 第2部分', 'BVb 第3部分']);
      expect(queue.currentItem!.id, b.item.id);
      expect(session.isActive, isTrue);

      // Going back to A: B shrinks to one entry, nothing is added.
      await open('BVa');
      await settled();
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb']);
      expect(titles(), ['视频 BVa', 'BVb 第1部分']);
      expect(list.currentBvid, 'BVa');
    });

    test('remove a video and one part without losing the watch session', () async {
      await open('BVa');
      final current = await open('BVb');
      await settled();
      final other = queue.playlist.first;
      expect(session.removeFromQueue(other.id), isTrue);
      expect(list.entryOf('BVa'), isNull);
      expect(session.isActive, isTrue);
      final part = queue.playlist.last;
      expect(session.removeFromQueue(part.id), isTrue);
      expect(queue.playlist, hasLength(2));
      expect(queue.currentItem?.id, current.item.id);
      session.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(queue.playlist, hasLength(2));
      expect(queue.playlist.map((item) => item.sourceRef?.page), [1, 2]);
      expect(session.isActive, isTrue);
      expect(session.removeFromQueue(current.item.id), isTrue);
      expect(playing.value?.id, current.item.id);
      expect(queue.isCurrentItemDetached, isTrue);
      expect(queue.playlist.single.sourceRef?.page, 2);
      expect(session.isActive, isTrue);
      expect(session.removeFromQueue(queue.playlist.single.id), isTrue);
      expect(queue.playlist, isEmpty);
      expect(list.entries, isEmpty);
    });

    test('removed parts stay removed when the watch queue is restored', () async {
      session.dispose();
      final file = File(p.join(root.path, 'removed-watch-parts.json'));
      session = BilibiliWatchPlaylistSession(
        list: list, service: service, library: library, queue: queue,
        playbackChanges: playing, currentItem: () => playing.value, persistenceFile: file,
      );
      final current = await open('BVb');
      await settled();
      session.removeFromQueue(queue.playlist.last.id);
      await session.flushPersistenceForTesting();
      session.dispose();
      await session.flushPersistenceForTesting();
      list = BilibiliWatchPlaylist();
      queue = PlaylistManager()..initialize(libraryService: library);
      session = BilibiliWatchPlaylistSession(
        list: list, service: service, library: library, queue: queue,
        playbackChanges: playing, currentItem: () => playing.value, persistenceFile: file,
      );
      expect(await session.restoreWatchQueue(current.item), isTrue);
      expect(queue.playlist.map((item) => item.sourceRef?.page), [1, 2]);
    });

    test('watch queue sorting survives part projection and placeholder rebuild', () async {
      final a = await open('BVa');
      final b = await open('BVb');
      await settled();
      final reversed = queue.playbackQueue.reversed.map((item) => item.id).toList();
      expect(session.reorderQueue(reversed), isTrue);
      expect(session.isActive, isTrue);
      expect(queue.currentItem?.id, b.item.id);
      expect(queue.playlist.map((item) => item.title), ['BVb 第3部分', 'BVb 第2部分', 'BVb 第1部分', '视频 BVa']);
      session.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(queue.playlist.map((item) => item.id), reversed);
      await library.discardTransientVideo(a.item.id);
      await until(() => queue.playlist.last.id != a.item.id);
      expect(queue.playlist.last.sourceRef?.bvid, 'BVa');
      expect(queue.playlist.take(3).map((item) => item.title), ['BVb 第3部分', 'BVb 第2部分', 'BVb 第1部分']);
      expect(session.isActive, isTrue);
      expect(session.resetQueueOrder(), isTrue);
      expect(queue.playlist.first.sourceRef?.bvid, 'BVa');
      expect(queue.playlist.skip(1).map((item) => item.title), ['BVb 第1部分', 'BVb 第2部分', 'BVb 第3部分']);
    });

    test('watch queue restores custom part order across sessions', () async {
      session.dispose();
      final file = File(p.join(root.path, 'ordered-watch-parts.json'));
      session = BilibiliWatchPlaylistSession(
        list: list, service: service, library: library, queue: queue,
        playbackChanges: playing, currentItem: () => playing.value, persistenceFile: file,
      );
      final current = await open('BVb');
      await settled();
      session.reorderQueue(queue.playbackQueue.reversed.map((item) => item.id).toList());
      await session.flushPersistenceForTesting();
      session.dispose();
      await session.flushPersistenceForTesting();
      list = BilibiliWatchPlaylist();
      queue = PlaylistManager()..initialize(libraryService: library);
      session = BilibiliWatchPlaylistSession(
        list: list, service: service, library: library, queue: queue,
        playbackChanges: playing, currentItem: () => playing.value, persistenceFile: file,
      );
      expect(await session.restoreWatchQueue(current.item), isTrue);
      expect(queue.playlist.map((item) => item.sourceRef?.page), [3, 2, 1]);
      expect(queue.currentItem?.id, current.item.id);
      expect(session.isActive, isTrue);
      session.resetQueueOrder();
      expect(queue.playlist.map((item) => item.sourceRef?.page), [1, 2, 3]);
    });

    test(
      'next and previous follow the list, into the next video\'s parts',
      () async {
        await open('BVa');
        await open('BVb');
        await open('BVc');
        await settled();
        queue.setCurrentIndex(queue.indexOfItem(playing.value!.id));
        // Previous from C is B (one entry), then A.
        final b = queue.getPrevious()!;
        expect(b.sourceRef!.bvid, 'BVb');
        queue.setCurrentIndex(queue.indexOfItem(b.id));
        playing.value = b;
        await until(() => queue.playlist.length == 5);
        expect(list.currentBvid, 'BVb');
        expect(titles(), [
          '视频 BVa',
          'BVb 第1部分',
          'BVb 第2部分',
          'BVb 第3部分',
          '视频 BVc',
        ]);
        // Within B the parts come next, then C.
        final p2 = queue.getNext()!;
        expect(p2.title, 'BVb 第2部分');
        queue.setCurrentIndex(queue.indexOfItem(p2.id));
        playing.value = p2;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(list.entryOf('BVb')!.page, 2);
        expect(queue.playlist.length, 5);
        // Switching to B was a watch: it is in the history.
        expect(history.watchEntryOf('BVb'), isNotNull);
      },
    );

    test('the list stays when the playback page closes; cleaned-up cards '
        'come back as entries without files', () async {
      final a = await open('BVa');
      final b = await open('BVb');
      await settled();
      // The page closed and the clean-up removed A's card (B plays on).
      await library.discardTransientVideo(a.item.id);
      await until(
        () =>
            queue.playlist.length == 4 && queue.playlist.first.id != a.item.id,
      );
      final again = queue.playlist.first;
      expect(again.sourceRef!.bvid, 'BVa');
      expect(again.thumbnailPath, isNull);
      expect(service.isWatchPlaceholder(again.id), isTrue);
      expect(session.placeholderIds(), contains(again.id));
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb']);
      expect(queue.currentItem!.id, b.item.id);
    });

    test('a cleaned-up card keeps its cover for the list', () async {
      final a = await open('BVa');
      await open('BVb');
      await settled();
      final thumb = File(p.join(root.path, 'thumbnails', '${a.item.id}.jpg'));
      await thumb.parent.create(recursive: true);
      await thumb.writeAsBytes(const <int>[1, 2, 3, 4]);
      a.item.thumbnailPath = thumb.path;
      await library.discardTransientVideo(a.item.id);
      await until(
        () => queue.playlist.isNotEmpty && queue.playlist.first.id != a.item.id,
      );
      final again = queue.playlist.first;
      expect(again.sourceRef!.bvid, 'BVa');
      expect(again.thumbnailPath, isNotNull);
      expect(File(again.thumbnailPath!).existsSync(), isTrue);
      expect(
        BilibiliCoverCache.isSharedCoverPath(again.thumbnailPath!),
        isTrue,
      );
      expect(thumb.existsSync(), isFalse);
    });

    test(
      'startup reads a shared cover before the watch session is installed',
      () async {
        final a = await open('BVa');
        final cover = File(p.join(root.path, 'thumbnails', 'original.jpg'));
        await cover.parent.create(recursive: true);
        await cover.writeAsBytes([1, 2, 3, 4]);
        final remembered = await BilibiliCoverCache(
          root,
        ).remember('BVa', cover.path);
        expect(remembered, isNotNull);
        a.item.thumbnailPath = p.join(root.path, 'removed-cover.jpg');
        expect(BilibiliWatchPlaylistSession.instance, isNull);
        expect(
          BilibiliWatchPlaylistSession.thumbnailFileFor(a.item),
          remembered,
        );

        // The fallback is just a reference to the existing cache. Clearing that
        // cache still works, and showing Mini does not rebuild or redownload it.
        await library.clearThumbnailDiskCache();
        expect(BilibiliWatchPlaylistSession.thumbnailFileFor(a.item), isNull);
        expect(File(remembered!).existsSync(), isFalse);
      },
    );

    test(
      'the list is written down and restores the queue next start',
      () async {
        session.dispose();
        final file = File(p.join(root.path, 'bilibili_watch_playlist.json'));
        list = BilibiliWatchPlaylist();
        queue = PlaylistManager()..initialize(libraryService: library);
        session = BilibiliWatchPlaylistSession(
          list: list,
          service: service,
          library: library,
          queue: queue,
          playbackChanges: playing,
          currentItem: () => playing.value,
          persistenceFile: file,
        );
        final b = await open('BVb');
        await open('BVa');
        await settled();
        await session.flushPersistenceForTesting();
        expect(file.existsSync(), isTrue);
        final saved =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        expect(saved['active'], isTrue);
        expect(saved['currentItemId'], playing.value!.id);

        final writer = session;
        final restoredList = BilibiliWatchPlaylist();
        final restoredQueue = PlaylistManager()
          ..initialize(libraryService: library);
        final restored = BilibiliWatchPlaylistSession(
          list: restoredList,
          service: service,
          library: library,
          queue: restoredQueue,
          playbackChanges: playing,
          currentItem: () => playing.value,
          persistenceFile: file,
        );
        writer.dispose();
        session = restored;
        expect(restoredList.entries.map((entry) => entry.bvid), ['BVb', 'BVa']);
        expect(restored.shouldRestoreWatchQueue(b.item), isTrue);
        expect(await restored.restoreWatchQueue(b.item), isTrue);
        expect(restoredQueue.currentItem!.id, b.item.id);
        expect(restored.isActive, isTrue);
        expect(
          restoredQueue.playlist.map((item) => item.sourceRef!.bvid),
          containsAll(<String>['BVa', 'BVb']),
        );
      },
    );

    test(
      'playlist snapshots cannot overtake a delayed earlier write',
      () async {
        session.dispose();
        final file = _DelayedPlaylistFile(
          File(p.join(root.path, 'ordered-list.json')),
        );
        session = BilibiliWatchPlaylistSession(
          list: list,
          service: service,
          library: library,
          queue: queue,
          playbackChanges: playing,
          currentItem: () => playing.value,
          persistenceFile: file,
        );
        VideoItem item(String id) => VideoItem(
          id: id,
          path: '$id.mp4',
          title: id,
          durationMs: 1000,
          lastUpdated: 0,
        );
        playing.value = item('older');
        final first = session.flushPersistenceForTesting();
        await file.firstWriteStarted.future;
        playing.value = item('newer');
        final second = session.flushPersistenceForTesting();
        try {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            file.writeCount,
            1,
            reason: 'the second snapshot must wait for the first writer',
          );
        } finally {
          file.releaseFirstWrite.complete();
          await Future.wait([first, second]);
        }
        final saved =
            jsonDecode(await file.backing.readAsString())
                as Map<String, dynamic>;
        expect(saved['currentItemId'], 'newer');
      },
    );

    test('a library queue takes over without the list touching it', () async {
      await open('BVa');
      await open('BVb');
      await settled();
      final local1 = VideoItem(
        id: 'local-1',
        path: '${root.path}/1.mp4',
        title: 'local 1',
        durationMs: 0,
        lastUpdated: 0,
        parentId: 'folder',
      );
      final local2 = VideoItem(
        id: 'local-2',
        path: '${root.path}/2.mp4',
        title: 'local 2',
        durationMs: 0,
        lastUpdated: 0,
        parentId: 'folder',
      );
      File(local1.path).writeAsStringSync('x');
      File(local2.path).writeAsStringSync('x');
      library
        ..seedVideoForTesting(local1)
        ..seedVideoForTesting(local2)
        ..seedCollectionForTesting(
          VideoCollection(
            id: 'folder',
            name: 'folder',
            createTime: 0,
            childrenIds: <String>['local-1', 'local-2'],
          ),
        );

      queue.prepareLibraryPlayback(local1);
      playing.value = local1;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.isActive, isFalse);
      expect(session.placeholderIds(), isEmpty);
      expect(queue.playlist.map((item) => item.id), ['local-1', 'local-2']);
      expect(queue.getNext()!.id, 'local-2');
      queue.setCurrentIndex(1);
      playing.value = local2;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(queue.playlist.map((item) => item.id), ['local-1', 'local-2']);
      // The list itself is untouched and comes back with the next video.
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb']);
      await library.discardTransientVideo(queue.playlist.first.id);
      await open('BVc');
      await settled();
      expect(session.isActive, isTrue);
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb', 'BVc']);
    });

    testWidgets('「清空」 in the list keeps only the playing video', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await open('BVa');
        await open('BVb');
        await settled();
      });
      BilibiliWatchPlaylistSession.install(session);
      // install(null) disposes it; the group's tear-down may again.
      addTearDown(() => BilibiliWatchPlaylistSession.install(null));
      Provider.debugCheckInvalidValueType = null;
      addTearDown(() => Provider.debugCheckInvalidValueType = _valueTypeCheck);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlaylistManager>.value(value: queue),
            Provider<MediaPlaybackService>.value(value: MediaPlaybackService()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: EpisodePickerPanel(
                panelWidth: 480,
                panelHeight: 600,
                onClose: () {},
              ),
            ),
          ),
        ),
      );
      final clear = find.byKey(const ValueKey('bilibili-playlist-clear'));
      expect(clear, findsOneWidget);
      await tester.tap(clear);
      await tester.runAsync(() => until(() => queue.playlist.length == 3));
      await tester.pump();
      expect(list.entries.map((e) => e.bvid), ['BVb']);
      expect(titles(), ['BVb 第1部分', 'BVb 第2部分', 'BVb 第3部分']);
      // The 撤销 offer runs out.
      await tester.pump(session.undoWindow + const Duration(seconds: 1));
      expect(session.canUndoClear, isFalse);

      // Not shown for a library queue.
      queue.setPlaylist(<VideoItem>[
        VideoItem(
          id: 'local',
          path: '/videos/local.mp4',
          title: 'local',
          durationMs: 0,
          lastUpdated: 0,
        ),
      ]);
      await tester.pump();
      expect(clear, findsNothing);
    });

    test('清空, its entries cleaned up, then 撤销: the whole list comes back '
        'in order, playable', () async {
      final a = await open('BVa');
      final b = await open('BVb');
      final c = await open('BVc');
      await settled();
      // A and B were watched: their cards are cleaned up and come back as
      // lightweight entries.
      await library.discardTransientVideo(a.item.id);
      await library.discardTransientVideo(b.item.id);
      await until(
        () =>
            queue.playlist.length == 3 &&
            queue.playlist
                .take(2)
                .every((item) => service.isWatchPlaceholder(item.id)),
      );

      await session.clear();
      await until(() => queue.playlist.length == 1);
      expect(list.entries.map((e) => e.bvid), ['BVc']);
      expect(session.canUndoClear, isTrue);
      // The cleaner removes what left the queue.
      for (final item in library.transientVideos.toList()) {
        if (item.id != c.item.id) await library.discardTransientVideo(item.id);
      }
      expect(library.transientVideos.map((v) => v.id), [c.item.id]);

      expect(await session.undoClear(), isTrue);
      await until(() => queue.playlist.length == 3);
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb', 'BVc']);
      // The list shows a collapsed multi-part video under its own title.
      BilibiliWatchPlaylistSession.install(session);
      addTearDown(() => BilibiliWatchPlaylistSession.install(null));
      expect(
        queue.playlist.map(BilibiliWatchPlaylistSession.titleOf).toList(),
        ['视频 BVa', '视频 BVb', '视频 BVc'],
      );
      expect(queue.currentItem!.id, c.item.id);
      for (final (index, bvid) in ['BVa', 'BVb'].indexed) {
        final item = queue.playlist[index];
        expect(item.sourceRef?.bvid, bvid);
        expect(
          service.isWatchPlaceholder(item.id),
          isTrue,
          reason: 'made again as an entry that gets its data when played',
        );
      }
      // Playable: switching to it moves the list there.
      playing.value = queue.playlist.first;
      await until(() => list.currentBvid == 'BVa');
      expect(await session.undoClear(), isFalse, reason: 'used once only');
    });

    test('after the hint is gone 撤销 does nothing', () async {
      session.dispose();
      session = BilibiliWatchPlaylistSession(
        list: list,
        service: service,
        library: library,
        queue: queue,
        playbackChanges: playing,
        currentItem: () => playing.value,
        undoWindow: const Duration(milliseconds: 50),
      );
      await open('BVa');
      await open('BVb');
      await settled();
      await session.clear();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(session.canUndoClear, isFalse);
      expect(await session.undoClear(), isFalse);
      expect(list.entries.map((e) => e.bvid), ['BVb']);
    });

    testWidgets('迷你播放器的播放列表也显示「清空」, keeps the playing video '
        'and does not restart it', (tester) async {
      VideoItem? playingItem;
      await tester.runAsync(() async {
        await open('BVa');
        playingItem = (await open('BVb')).item;
        await settled();
      });
      expect(playingItem, isNotNull);
      final keptId = playingItem!.id;
      BilibiliWatchPlaylistSession.install(session);
      addTearDown(() => BilibiliWatchPlaylistSession.install(null));
      // The player itself: clearing must not ask it for anything.
      final playback = MediaPlaybackService();
      final positionBefore = playback.position;
      final playerItemBefore = playback.currentItem?.id;
      final stateBefore = playback.state;
      var tapped = 0;

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: Scaffold(
            body: PlaylistBottomSheet(
              playlist: queue.playlist,
              currentItemId: keptId,
              onItemTap: (_) => tapped++,
            ),
          ),
        ),
      );
      final clear = find.byKey(const ValueKey('bilibili-playlist-clear'));
      expect(clear, findsOneWidget);
      await tester.tap(clear);
      await tester.runAsync(() => until(() => list.entries.length == 1));
      await tester.pump();
      expect(list.entries.map((e) => e.bvid), ['BVb']);
      expect(queue.currentItem!.id, keptId);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('已清空播放列表'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);
      // Nothing was played, stopped or sought: the position stays.
      expect(tapped, 0);
      expect(playback.position, positionBefore);
      expect(playback.currentItem?.id, playerItemBefore);
      expect(playback.state, stateBefore);
      expect(playing.value?.id, keptId);
      // The playing card is still the queue's current entry.
      expect(queue.currentIndex, queue.indexOfItem(keptId));

      // 「撤销」 in the hint brings the list back, order and all.
      await tester.tap(find.text('撤销'));
      await tester.runAsync(() => until(() => list.entries.length == 2));
      await tester.runAsync(() => until(() => queue.playlist.length == 4));
      await tester.pump();
      expect(list.entries.map((e) => e.bvid), ['BVa', 'BVb']);
      expect(queue.currentItem!.id, keptId);
      expect(playback.position, positionBefore);
      await AppToast.dismiss(immediate: true);
      await tester.pump(const Duration(seconds: 1));

      // A library queue never shows the button.
      queue.setPlaylist(<VideoItem>[
        VideoItem(
          id: 'local',
          path: '/videos/local.mp4',
          title: 'local',
          durationMs: 0,
          lastUpdated: 0,
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaylistBottomSheet(
              playlist: queue.playlist,
              currentItemId: 'local',
              onItemTap: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('bilibili-playlist-clear')),
        findsNothing,
      );
    });
  });
}

final _valueTypeCheck = Provider.debugCheckInvalidValueType;

int _expectedLength(BilibiliWatchPlaylist list) {
  var length = 0;
  for (final entry in list.entries) {
    length += entry.bvid == list.currentBvid ? entry.info.pages.length : 1;
  }
  return length;
}

final Map<String, BilibiliVideoInfo> _infos = <String, BilibiliVideoInfo>{
  'BVa': _info('BVa'),
  'BVb': _info('BVb', parts: 3),
  'BVc': _info('BVc'),
};

BilibiliVideoInfo _info(String bvid, {int parts = 1}) {
  final base = bvid.hashCode.abs() % 1000 * 10;
  return BilibiliVideoInfo(
    title: '视频 $bvid',
    desc: '',
    pic: 'https://i0.hdslb.com/bfs/archive/$bvid.jpg',
    bvid: bvid,
    aid: '1',
    ownerName: 'UP',
    ownerMid: '1',
    pubDate: 0,
    pages: <BilibiliPage>[
      for (var i = 1; i <= parts; i++)
        BilibiliPage(cid: base + i, page: i, part: '$bvid 第$i部分', duration: 60),
    ],
  );
}

class _DelayedPlaylistFile implements File {
  _DelayedPlaylistFile(this.backing);
  final File backing;
  final firstWriteStarted = Completer<void>();
  final releaseFirstWrite = Completer<void>();
  int writeCount = 0;

  @override
  String get path => backing.path;
  @override
  File get absolute => this;
  @override
  Directory get parent => backing.parent;
  @override
  bool existsSync() => backing.existsSync();

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    writeCount++;
    if (writeCount == 1) {
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    return backing.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends BilibiliApiService {
  @override
  Future<void> init() async {}

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async =>
      _infos[bvid]!;
}

class _Paths extends PathProviderPlatform {
  _Paths(this.root);

  final String root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}
