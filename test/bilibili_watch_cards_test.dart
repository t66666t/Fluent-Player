import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/portable_transfer/portable_media_selection.dart';
import 'package:video_player_app/features/portable_transfer/zip_export_plan.dart';
import 'package:video_player_app/models/bilibili_download_task.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/library_activity.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_history_screen.dart';
import 'package:video_player_app/screens/home_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cache_limit_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_cover_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_quick_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_stream_card.dart';
import 'package:video_player_app/services/bilibili/bilibili_streaming_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/playback_state_store.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/bilibili_url_parser.dart';

const _bvid = 'BV1xx411c7mD';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late LibraryService library;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
    root = await Directory.systemTemp.createTemp('bilibili_watch_cards_');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TempPathProvider(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
  });

  tearDown(() async {
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    BilibiliHistoryService.instance.resetForTest();
    PathProviderPlatform.instance = originalPathProvider;
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException {
      // Left to the system temp cleanup.
    }
  });

  BilibiliDownloadService newService(_FakeApi api) {
    final service = BilibiliDownloadService(apiService: api);
    addTearDown(service.shutdown);
    return service;
  }

  Future<VideoItem> addWatchOnlyCard({
    String id = 'watch-1',
    String title = '只看视频',
    int page = 1,
    int? lastUpdated,
  }) async {
    final danmaku = File(p.join(root.path, 'danmaku', '${id}_danmaku.ass'));
    await danmaku.create(recursive: true);
    await danmaku.writeAsString('[Script Info]');
    final item = _streamCard(
      id: id,
      title: title,
      page: page,
      transient: true,
      danmakuPath: danmaku.path,
      lastUpdated: lastUpdated,
    );
    await library.addTransientVideo(item);
    return item;
  }

  group('watch-only cards stay out of every library list', () {
    testWidgets('folders, search, recent, continue, history, recycle bin, '
        'export and library.json skip them', (tester) async {
      await tester.runAsync(() async {
        final formal = _streamCard(id: 'formal-1', title: '只看视频 正式', page: 2);
        await library.addSingleVideo(formal, reuseExistingItem: false);
        final watchOnly = await addWatchOnlyCard();
        final now = DateTime.now().millisecondsSinceEpoch;
        for (final id in [formal.id, watchOnly.id]) {
          library.seedMediaActivityForTesting(
            MediaActivityRecord(mediaId: id)
              ..addedAtMs = now
              ..lastPlayedAtMs = now
              ..accumulatedWatchMs = 30 * 60 * 1000
              ..continueEnrolled = true,
          );
        }
        formal.lastPositionMs = 10000;
        watchOnly.lastPositionMs = 10000;

        // The playback page can still find it by id.
        expect(library.getVideo(watchOnly.id), same(watchOnly));

        // 文件夹
        final rootIds = library
            .getContents(null)
            .map((e) => (e as dynamic).id as String)
            .toList();
        expect(rootIds, isNot(contains(watchOnly.id)));
        expect(
          library.getVideosInFolder(null).map((v) => v.id),
          isNot(contains(watchOnly.id)),
        );
        // 媒体库搜索
        final found = library.searchContents('只看视频');
        expect(found.whereType<VideoItem>().map((v) => v.id), [formal.id]);
        // 最近添加
        final projection = library.activityProjection;
        final recent = projection.recentAddedMediaIds();
        expect([
          ...recent.datedIds,
          ...recent.unknownAddedIds,
        ], isNot(contains(watchOnly.id)));
        expect(
          projection.recentAddedEntries().expand((e) => e.visibleMediaIds),
          isNot(contains(watchOnly.id)),
        );
        // 继续学习
        final continueIds = projection
            .continueLearningGroups()
            .expand((g) => g.mediaIds)
            .toList();
        expect(continueIds, contains(formal.id));
        expect(continueIds, isNot(contains(watchOnly.id)));
        // 播放历史 / 回收站 / 在线卡片列表
        expect(
          projection.playbackHistoryMediaIds(),
          isNot(contains(watchOnly.id)),
        );
        expect(library.getRecycleBinContents(), isEmpty);
        expect(library.bilibiliStreamItems.map((v) => v.id), [formal.id]);
        expect(library.transientVideos.map((v) => v.id), [watchOnly.id]);
        // 备份导出
        final tree = PortableTreeIndex.fromLibrary(library);
        expect(tree.nodes.keys, isNot(contains(watchOnly.id)));
        final zip = enumerateZipCandidates(
          library: library,
          rootIds: <String>[formal.id, watchOnly.id],
        );
        expect(zip.candidates, isEmpty);
        expect(zip.skippedOnline, 1, reason: 'only the library card counts');
        // library.json
        await library.saveLibraryForTesting();
        final saved = await File(
          p.join(root.path, 'library.json'),
        ).readAsString();
        expect(saved, contains(formal.id));
        expect(saved, isNot(contains(watchOnly.id)));
      });
    });

    test('playback activity is never recorded for a watch-only card', () async {
      final watchOnly = await addWatchOnlyCard();
      await library.applyWatchFlush(
        mediaId: watchOnly.id,
        deltaWatchMs: 60000,
        lastPlayedAtMs: DateTime.now().millisecondsSinceEpoch,
        enrolled: true,
      );
      library.recordValidPlaybackProgress(watchOnly.id, deltaWatchMs: 5000);
      await library.recordPlaybackCompleted(watchOnly.id);
      expect(library.mediaActivity(watchOnly.id), isNull);
      expect(library.hasExistingLibraryContent, isFalse);
    });
  });

  group('clean-up', () {
    test(
      'a closed card is removed with its files; a playing one stays',
      () async {
        var clock = DateTime.now().add(const Duration(minutes: 1));
        final playing = await addWatchOnlyCard(id: 'watch-playing');
        final closed = await addWatchOnlyCard(id: 'watch-closed');
        final cacheDir = Directory(
          p.join(
            root.path,
            'bilibili_stream_cache',
            BilibiliStreamingService.cacheEntryName(closed.id),
          ),
        );
        await cacheDir.create(recursive: true);
        await File(p.join(cacheDir.path, 'piece.m4s')).writeAsBytes([1, 2, 3]);
        final discarded = <String>[];
        final janitor = BilibiliTransientCardJanitor(
          library: library,
          inUseIds: () => <String>{playing.id},
          beforeDiscard: (item) async => discarded.add(item.id),
          now: () => clock,
        );
        addTearDown(janitor.dispose);

        expect(await janitor.sweep(), 1);
        expect(discarded, [closed.id]);
        expect(library.getVideo(closed.id), isNull);
        expect(File(closed.danmakuPath!).existsSync(), isFalse);
        expect(cacheDir.existsSync(), isFalse);
        expect(library.getVideo(playing.id), same(playing));
        expect(File(playing.danmakuPath!).existsSync(), isTrue);

        // A library card is never removed by the sweep.
        final formal = _streamCard(id: 'formal-keep', title: '正式');
        await library.addSingleVideo(formal, reuseExistingItem: false);
        expect(await library.discardTransientVideo(formal.id), isFalse);
        expect(await janitor.sweep(), 0);
        expect(library.getVideo(formal.id), same(formal));
        clock = clock.add(const Duration(seconds: 1));
      },
    );

    test('a card just created waits for its page to open', () async {
      final now = DateTime.now();
      final fresh = await addWatchOnlyCard(
        id: 'watch-fresh',
        lastUpdated: now.millisecondsSinceEpoch,
      );
      var clock = now.add(const Duration(seconds: 2));
      final janitor = BilibiliTransientCardJanitor(
        library: library,
        inUseIds: () => const <String>{},
        now: () => clock,
        grace: const Duration(seconds: 15),
      );
      addTearDown(janitor.dispose);
      expect(await janitor.sweep(), 0);
      expect(library.getVideo(fresh.id), same(fresh));
      clock = now.add(const Duration(seconds: 16));
      expect(await janitor.sweep(), 1);
      expect(library.getVideo(fresh.id), isNull);
    });

    test('the app wiring sweeps when the current item changes', () async {
      final playback = _FakePlayback();
      final cards = BilibiliWatchCards.forApp(
        library: library,
        playbackChanges: playback,
        currentItemId: () => playback.currentId,
        openPageItemIds: () => const <String>[],
      );
      addTearDown(cards.dispose);
      final item = await addWatchOnlyCard(
        id: 'watch-app',
        lastUpdated: DateTime.now()
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
      );
      playback.change(item.id);
      await cards.janitor.sweep();
      expect(library.getVideo(item.id), same(item), reason: 'still playing');
      playback.change(null);
      await Future<void>.delayed(
        cards.janitor.sweepDelay + const Duration(milliseconds: 100),
      );
      await cards.janitor.sweep();
      expect(library.getVideo(item.id), isNull);
    });

    testWidgets('closing the playback page saves progress and cleans up', (
      tester,
    ) async {
      final history = BilibiliHistoryService.instance;
      // Items of playback pages on the stack, as the app reads them.
      final openPages = <String>{};
      final cards = BilibiliWatchCards.forApp(
        library: library,
        playbackChanges: _FakePlayback(),
        currentItemId: () => null,
        openPageItemIds: () => openPages,
        history: history,
      );
      BilibiliWatchCards.install(cards);
      addTearDown(() {
        BilibiliWatchCards.install(null);
        cards.dispose();
      });
      late BilibiliWatchPlan plan;
      await tester.runAsync(() async {
        // IO-owning services must be constructed in the real async zone too;
        // their completed futures may receive late teardown listeners.
        final service = newService(_FakeApi(pages: 1));
        plan = await prepareBilibiliWatch(
          service: service,
          library: library,
          bvid: _bvid,
          history: history,
          cards: cards,
        );
      });
      // Back-date the card so the just-created grace does not apply.
      plan.item.lastUpdated = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;

      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [
            BilibiliWatchCards.routeObserver(
              isPlaybackRoute: (name) => name == '/playback/portrait',
            ),
          ],
          home: const Text('home'),
        ),
      );
      openPages.add(plan.item.id);
      unawaited(
        navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            settings: RouteSettings(
              name: '/playback/portrait',
              arguments: plan.item.id,
            ),
            builder: (_) => const Text('playing'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> reportPosition(int ms) async {
        await tester.runAsync(() async {
          await library.updateVideoProgress(plan.item.id, ms);
          await Future<void>.delayed(const Duration(milliseconds: 20));
        });
      }

      await reportPosition(42000);
      expect(history.watchEntryOf(_bvid)?.positionMs, 42000);
      // Within the throttle window: kept pending until the page closes.
      await reportPosition(47000);
      expect(history.watchEntryOf(_bvid)?.positionMs, 42000);

      await tester.pump(const Duration(seconds: 20));
      expect(
        library.getVideo(plan.item.id),
        same(plan.item),
        reason: 'on page',
      );

      openPages.remove(plan.item.id);
      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(BilibiliWatchCards.pageCloseDelay);
      for (
        var i = 0;
        i < 50 &&
            (library.transientVideos.isNotEmpty ||
                history.watchEntryOf(_bvid)?.positionMs != 47000);
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(library.transientVideos, isEmpty);
      expect(history.watchEntryOf(_bvid)?.positionMs, 47000);
    });

    test('closing the mini player saves the position and removes the card '
        'right away', () async {
      final history = BilibiliHistoryService.instance;
      final playback = _FakePlayback();
      final cards = BilibiliWatchCards.forApp(
        library: library,
        playbackChanges: playback,
        currentItemId: () => playback.currentId,
        openPageItemIds: () => const <String>[],
        history: history,
      );
      addTearDown(cards.dispose);
      final service = newService(_FakeApi(pages: 2));
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 2,
        history: history,
        cards: cards,
      );
      // Watched for a while: past the clean-up grace of new cards (the
      // episode-list entry of P1 included).
      for (final entry in plan.queue!) {
        entry.lastUpdated = DateTime.now()
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch;
      }
      // Playing in the mini player, no playback page on screen.
      playback.change(plan.item.id);
      await library.updateVideoProgress(plan.item.id, 20000);
      await pumpEventQueue();
      await library.updateVideoProgress(plan.item.id, 26000);
      await pumpEventQueue();
      expect(
        history.watchEntryOf(_bvid)?.positionMs,
        20000,
        reason: 'throttled',
      );

      // Closing the mini player stops playback: the current item goes away.
      playback.change(null);
      await pumpEventQueue();
      expect(history.watchEntryOf(_bvid)?.positionMs, 26000);
      expect(history.watchEntryOf(_bvid)?.page, 2);
      await Future<void>.delayed(
        cards.janitor.sweepDelay + const Duration(milliseconds: 200),
      );
      expect(library.getVideo(plan.item.id), isNull);
      expect(library.transientVideos, isEmpty);
    });

    test('startup removes cards left by the previous run', () async {
      final left = await addWatchOnlyCard(id: 'watch-left');
      final ledger = library.transientLedgerFileForTesting;
      expect(ledger.existsSync(), isTrue);
      final cacheDir = Directory(
        p.join(
          root.path,
          'bilibili_stream_cache',
          BilibiliStreamingService.cacheEntryName(left.id),
        ),
      );
      await cacheDir.create(recursive: true);
      await File(p.join(cacheDir.path, 'piece.m4s')).writeAsBytes([1]);

      // Next start: memory is gone, the files and the side list are not.
      library.resetLibraryForTesting();
      await library.init();
      expect(library.getVideo(left.id), isNull);
      expect(File(left.danmakuPath!).existsSync(), isFalse);
      expect(cacheDir.existsSync(), isFalse);
      expect(ledger.existsSync(), isFalse);
    });

    test(
      'startup keeps the watch-only card the mini player was showing',
      () async {
        final playing = await addWatchOnlyCard(id: 'watch-playing');
        final other = await addWatchOnlyCard(id: 'watch-other', page: 2);
        final thumb = File(p.join(root.path, 'thumbnails', 'other.jpg'));
        await thumb.parent.create(recursive: true);
        await thumb.writeAsBytes(const <int>[9, 9, 9, 9]);
        other.thumbnailPath = thumb.path;
        await library.noteCardDataChanged(other.id);

        SharedPreferences.setMockInitialValues(<String, Object>{
          'playback_state_snapshot': jsonEncode(<String, Object>{
            'currentItemId': playing.id,
            'positionMs': 5000,
            'wasPlaying': false,
            'timestamp': 1,
          }),
        });
        library.resetLibraryForTesting();
        await library.init();

        final kept = library.getVideo(playing.id);
        expect(kept, isNotNull);
        expect(kept!.isTransient, isTrue);
        expect(kept.parentId, isNull);
        expect(library.transientVideos.map((item) => item.id), [playing.id]);
        expect(library.getVideo(other.id), isNull);
        expect(File(playing.danmakuPath!).existsSync(), isTrue);
        expect(File(other.danmakuPath!).existsSync(), isFalse);
        expect(thumb.existsSync(), isFalse);
        final remembered = BilibiliCoverCache(
          Directory(root.path),
        ).existingPath(_bvid);
        expect(remembered, isNotNull);
        expect(File(remembered!).existsSync(), isTrue);
        expect(library.launchRetainedTransientIds, {playing.id});
        library.releaseLaunchRetainedTransients();
        expect(library.launchRetainedTransientIds, isEmpty);
      },
    );

    for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
      test(
        '$platform retains the file snapshot instead of a stale preference',
        () async {
          final playing = await addWatchOnlyCard(id: 'file-playing');
          final stale = await addWatchOnlyCard(
            id: 'preference-playing',
            page: 2,
          );
          SharedPreferences.setMockInitialValues(<String, Object>{
            PlaybackStateStore.legacyKey: jsonEncode({
              'currentItemId': stale.id,
            }),
          });
          final previousPlatform = debugDefaultTargetPlatformOverride;
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(
            () => debugDefaultTargetPlatformOverride = previousPlatform,
          );
          await PlaybackStateStore.shared.write({
            'currentItemId': playing.id,
            'positionMs': 42000,
            'wasPlaying': false,
            'timestamp': 2,
          });

          library.resetLibraryForTesting();
          await library.init();
          final kept = library.getVideo(playing.id);
          expect(kept?.title, playing.title);
          expect(kept?.sourceRef?.toJson(), playing.sourceRef?.toJson());
          expect(library.launchRetainedTransientIds, {playing.id});
          expect(File(playing.danmakuPath!).existsSync(), isTrue);
          expect(library.getVideo(stale.id), isNull);
          expect(File(stale.danmakuPath!).existsSync(), isFalse);

          // Closing Mini clears the authoritative snapshot. An old preference
          // must not keep resurrecting a card or pinning its temporary files.
          await PlaybackStateStore.shared.write({
            'currentItemId': null,
            'positionMs': 0,
            'wasPlaying': false,
            'timestamp': 3,
          });
          library.resetLibraryForTesting();
          await library.init();
          expect(library.transientVideos, isEmpty);
          expect(library.launchRetainedTransientIds, isEmpty);
          expect(File(playing.danmakuPath!).existsSync(), isFalse);
          expect(library.transientLedgerFileForTesting.existsSync(), isFalse);
        },
      );
    }

    test('the side list empties once the last card is removed', () async {
      final item = await addWatchOnlyCard(id: 'watch-ledger');
      final ledger = library.transientLedgerFileForTesting;
      final listed = jsonDecode(await ledger.readAsString()) as List<dynamic>;
      expect(listed.map((e) => (e as Map)['id']), [item.id]);
      await library.discardTransientVideo(item.id);
      expect(ledger.existsSync(), isFalse);
    });
  });

  group('online cache', () {
    test('watch-only cache counts against the cap and is trimmed', () async {
      final watchOnly = await addWatchOnlyCard(id: 'watch-cache');
      expect(library.onlineCacheItems.map((v) => v.id), [watchOnly.id]);
      expect(library.bilibiliStreamItems, isEmpty);

      final cacheRoot = Directory(p.join(root.path, 'bilibili_stream_cache'));
      final entry = Directory(
        p.join(
          cacheRoot.path,
          BilibiliStreamingService.cacheEntryName(watchOnly.id),
        ),
      );
      await entry.create(recursive: true);
      await File(
        p.join(entry.path, 'piece.m4s'),
      ).writeAsBytes(List<int>.filled(4096, 7));
      final removed = <String>[];
      final limiter = BilibiliCacheLimiter(
        cacheRoot: () async => cacheRoot,
        removeEntry: (name, dir) async {
          removed.add(name);
          for (final item in library.onlineCacheItems) {
            if (BilibiliStreamingService.cacheEntryName(item.id) == name) {
              await library.clearOnlineCacheForItem(item.id);
              return;
            }
          }
        },
      );
      expect((await limiter.usage()).bytes, 4096);
      final kept = await limiter.trim(
        1024,
        protectedEntries: {
          BilibiliStreamingService.cacheEntryName(watchOnly.id),
        },
      );
      expect(kept.removedEntries, isEmpty, reason: 'playing card is kept');
      final trimmed = await limiter.trim(1024);
      expect(removed, [BilibiliStreamingService.cacheEntryName(watchOnly.id)]);
      expect(trimmed.bytesAfter, 0);
      expect(entry.existsSync(), isFalse);
    });
  });

  group('opening a video', () {
    test('an existing library card for the BV + part is used as is', () async {
      final api = _FakeApi(pages: 2);
      final service = newService(api);
      final formal = _streamCard(id: 'formal-p2', title: 'P2', page: 2);
      await library.addSingleVideo(formal, reuseExistingItem: false);

      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 2,
      );
      expect(plan.item, same(formal));
      expect(plan.usesOwnQueue, isFalse);
      expect(library.transientVideos, isEmpty);
      expect(api.metadataRequests, 0, reason: 'no card was built');
    });

    test(
      'auto import off: a watch-only card, nothing in the library',
      () async {
        final api = _FakeApi(pages: 2);
        final service = newService(api);
        final plan = await prepareBilibiliWatch(
          service: service,
          library: library,
          bvid: _bvid,
          page: 2,
        );
        expect(plan.imported, isFalse);
        expect(plan.item.isTransient, isTrue);
        expect(plan.usesOwnQueue, isTrue);
        expect(plan.item.sourceRef?.page, 2);
        expect(plan.queue?.map((v) => v.sourceRef?.page), [1, 2]);
        expect(plan.queue?[1], same(plan.item));
        expect(library.transientVideos, hasLength(2));
        expect(library.transientVideos, contains(plan.item));
        expect(library.bilibiliStreamItems, isEmpty);
        expect(library.getContents(null), isEmpty);

        // A second open while it is alive reuses it.
        final again = await prepareBilibiliWatch(
          service: service,
          library: library,
          bvid: _bvid,
          page: 2,
        );
        expect(again.item, same(plan.item));
        expect(again.queue?.first, same(plan.queue?.first));
        expect(library.transientVideos, hasLength(2));
        expect(api.metadataRequests, 1);
      },
    );

    test('auto import on: the library card is created as before', () async {
      SettingsService().bilibiliAutoImportOnPlay = true;
      final api = _FakeApi(pages: 1);
      final service = newService(api);
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
      );
      expect(plan.imported, isTrue);
      expect(plan.item.isTransient, isFalse);
      expect(plan.usesOwnQueue, isFalse);
      expect(library.transientVideos, isEmpty);
      expect(library.bilibiliStreamItems, [plan.item]);
    });

    test('the switch is a registered setting, off by default', () async {
      final settings = SettingsService();
      await settings.init();
      expect(settings.bilibiliAutoImportOnPlay, isFalse);
      await settings.updateSetting('bilibiliAutoImportOnPlay', true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('bilibiliAutoImportOnPlay'), isTrue);
      settings.resetForTest();
      await settings.init();
      expect(settings.bilibiliAutoImportOnPlay, isTrue);
    });
  });

  group('watch history keeps the progress', () {
    test('records part and position while playing, throttled', () async {
      final history = BilibiliHistoryService.instance;
      var clock = DateTime(2026, 10, 8, 12);
      final recorder = BilibiliWatchProgressRecorder(
        library: library,
        history: history,
        interval: const Duration(seconds: 10),
        now: () => clock,
      )..attach();
      addTearDown(recorder.detach);
      final api = _FakeApi(pages: 3);
      final service = newService(api);
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 3,
        history: history,
      );
      recorder.track(plan.item);
      expect(history.watchEntryOf(_bvid)?.page, 3);

      await library.updateVideoProgress(plan.item.id, 61000);
      await pumpEventQueue();
      expect(history.watchEntryOf(_bvid)?.positionMs, 61000);

      clock = clock.add(const Duration(seconds: 3));
      await library.updateVideoProgress(plan.item.id, 64000);
      await pumpEventQueue();
      expect(
        history.watchEntryOf(_bvid)?.positionMs,
        61000,
        reason: 'within the interval',
      );

      // Closing the page saves the latest position right away.
      await recorder.flush(plan.item.id);
      expect(history.watchEntryOf(_bvid)?.positionMs, 64000);
      expect(history.watchEntryOf(_bvid)?.page, 3);

      final prefs = await SharedPreferences.getInstance();
      final saved =
          (jsonDecode(prefs.getString(BilibiliHistoryService.watchHistoryKey)!)
                      as List<dynamic>)
                  .single
              as Map<String, dynamic>;
      expect(saved['page'], 3);
      expect(saved['pos'], 64000);
    });

    test('opening from history continues at the saved part and second, '
        'also after the card was cleaned', () async {
      final history = BilibiliHistoryService.instance;
      final recorder = BilibiliWatchProgressRecorder(
        library: library,
        history: history,
      )..attach();
      addTearDown(recorder.detach);
      final api = _FakeApi(pages: 3);
      final service = newService(api);
      final first = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 2,
        history: history,
      );
      recorder.track(first.item);
      await library.updateVideoProgress(first.item.id, 125000);

      final janitor = BilibiliTransientCardJanitor(
        library: library,
        inUseIds: () => const <String>{},
        beforeDiscard: (item) => recorder.forget(item.id),
        grace: Duration.zero,
      );
      addTearDown(janitor.dispose);
      // The opened part and the two episode-list entries.
      expect(await janitor.sweep(), 3);
      expect(library.transientVideos, isEmpty);
      final entry = history.watchEntryOf(_bvid)!;
      expect(entry.page, 2);
      expect(entry.positionMs, 125000);
      expect(entry.positionSeconds, 125);

      // From the history list: no part asked, the saved one continues.
      final resumed = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        history: history,
      );
      expect(resumed.item.isTransient, isTrue);
      expect(resumed.item.sourceRef?.page, 2);
      expect(resumed.item.lastPositionMs, 125000);
    });

    test('resolving the start point', () {
      final entry = BilibiliWatchHistoryEntry(
        bvid: _bvid,
        title: 't',
        watchedAt: DateTime(2026),
        page: 2,
        positionMs: 90000,
      );
      expect(
        resolveBilibiliWatchStart(entry: entry, historyEnabled: true),
        const BilibiliWatchStart(page: 2, positionMs: 90000),
      );
      expect(
        resolveBilibiliWatchStart(
          entry: entry,
          requestedPage: 2,
          historyEnabled: true,
        ),
        const BilibiliWatchStart(page: 2, positionMs: 90000),
      );
      expect(
        resolveBilibiliWatchStart(
          entry: entry,
          requestedPage: 3,
          historyEnabled: true,
        ),
        const BilibiliWatchStart(page: 3),
      );
      expect(
        resolveBilibiliWatchStart(entry: entry, historyEnabled: false),
        const BilibiliWatchStart(page: 1),
      );
      expect(
        resolveBilibiliWatchStart(
          entry: entry,
          requestedPage: 2,
          startAt: const Duration(seconds: 5),
          historyEnabled: true,
        ),
        const BilibiliWatchStart(page: 2, positionMs: 5000),
      );
    });

    test('history off: nothing is recorded and nothing resumes', () async {
      final history = BilibiliHistoryService.instance;
      await history.recordWatch(
        BilibiliWatchHistoryEntry(
          bvid: _bvid,
          title: 'old',
          watchedAt: DateTime(2026),
          page: 2,
          positionMs: 90000,
        ),
      );
      SettingsService().bilibiliRecordWatchHistory = false;
      final recorder = BilibiliWatchProgressRecorder(
        library: library,
        history: history,
      )..attach();
      addTearDown(recorder.detach);
      final service = newService(_FakeApi(pages: 2));
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        history: history,
      );
      expect(plan.item.sourceRef?.page, 1);
      expect(plan.item.lastPositionMs, 0);
      recorder.track(plan.item);
      await library.updateVideoProgress(plan.item.id, 30000);
      await recorder.flush(plan.item.id);
      final entry = history.watchEntryOf(_bvid)!;
      expect(entry.positionMs, 90000, reason: 'kept, not updated');
      expect(entry.title, 'old');
    });
  });

  group('multi-part episode list (parts built on demand)', () {
    Future<void> waitFor(bool Function() done) async {
      for (var i = 0; i < 100 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(done(), isTrue);
    }

    Iterable<VideoItem> watchOnlyOf(String bvid) =>
        library.transientVideos.where((v) => bilibiliStreamCardBvid(v) == bvid);

    test('switching parts builds only those parts; closing the page removes '
        'them all with their files', () async {
      final history = BilibiliHistoryService.instance;
      final api = _FakeApi(pages: 3);
      final service = newService(api);
      final playback = _FakePlayback();
      var openPages = <String>[];
      var queue = <VideoItem>[];
      final cards = BilibiliWatchCards.forApp(
        library: library,
        playbackChanges: playback,
        currentItemId: () => playback.currentId,
        openPageItemIds: () => openPages,
        queueItemIds: () => queue.map((v) => v.id),
        prepareCurrentItem: (id) => service.completeWatchPart(library, id),
        history: history,
      );
      addTearDown(cards.dispose);

      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 1,
        history: history,
        cards: cards,
      );
      queue = plan.queue!;
      expect(queue.map((v) => v.sourceRef?.page), [1, 2, 3]);
      expect(queue.first, same(plan.item));
      expect(queue.every((v) => v.isTransient), isTrue);
      expect(api.metadataRequests, 1, reason: 'only the opened part');
      expect(queue[1].danmakuPath, isNull);
      expect(service.isPendingWatchPart(queue[1].id), isTrue);
      expect(service.isPendingWatchPart(queue[2].id), isTrue);

      // The playback page opens on P1 and plays it.
      openPages = <String>[plan.item.id];
      playback.change(plan.item.id);
      await library.updateVideoProgress(plan.item.id, 30000);
      await pumpEventQueue();

      // Episode list: P1 → P3 → P2.
      playback.change(queue[2].id);
      await waitFor(() => queue[2].danmakuPath != null);
      expect(api.metadataRequests, 2);
      expect(service.isPendingWatchPart(queue[1].id), isTrue);
      await library.updateVideoProgress(queue[2].id, 5000);
      playback.change(queue[1].id);
      await waitFor(() => queue[1].danmakuPath != null);
      expect(api.metadataRequests, 3);
      await library.updateVideoProgress(queue[1].id, 12000);
      await pumpEventQueue();
      final danmakuFiles = [for (final v in queue) File(v.danmakuPath!)];
      expect(danmakuFiles.every((f) => f.existsSync()), isTrue);

      // One history entry for the video: the last part and second.
      expect(history.watchHistory.where((e) => e.bvid == _bvid), hasLength(1));
      final entry = history.watchEntryOf(_bvid)!;
      expect(entry.page, 2);
      expect(entry.positionMs, 12000);
      expect(entry.partTitle, '第 2 部分');

      // All their caches count toward the cap.
      expect(
        library.onlineCacheItems.map((v) => v.id).toSet(),
        queue.map((v) => v.id).toSet(),
      );
      // Never in recent / continue / search / folders.
      final projection = library.activityProjection;
      final recent = projection.recentAddedMediaIds();
      final ids = queue.map((v) => v.id).toSet();
      expect(
        {...recent.datedIds, ...recent.unknownAddedIds}.intersection(ids),
        isEmpty,
      );
      expect(
        projection
            .continueLearningGroups()
            .expand((g) => g.mediaIds)
            .toSet()
            .intersection(ids),
        isEmpty,
      );
      expect(library.searchContents('部分'), isEmpty);
      expect(library.getContents(null), isEmpty);
      expect(library.bilibiliStreamItems, isEmpty);

      // While the page is open the whole episode list survives a sweep.
      for (final v in queue) {
        v.lastUpdated = DateTime.now()
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch;
      }
      await cards.janitor.sweep();
      expect(watchOnlyOf(_bvid), hasLength(3));

      // Closing the playback page (and the player) removes every part.
      openPages = <String>[];
      playback.change(null);
      await Future<void>.delayed(
        cards.janitor.sweepDelay + const Duration(milliseconds: 300),
      );
      expect(library.transientVideos, isEmpty);
      expect(danmakuFiles.any((f) => f.existsSync()), isFalse);
      expect(library.transientLedgerFileForTesting.existsSync(), isFalse);
      expect(history.watchEntryOf(_bvid)?.positionMs, 12000);

      // Next start: nothing left.
      library.resetLibraryForTesting();
      await library.init();
      expect(library.transientVideos, isEmpty);
      expect(library.onlineCacheItems, isEmpty);
    });

    test('deferred startup keeps crash cleanup durable until it can run', () async {
      final service = newService(_FakeApi(pages: 3));
      final plan = await prepareBilibiliWatch(service: service, library: library,
        bvid: _bvid, page: 2);
      final file = File(plan.queue![1].danmakuPath!);
      expect(await file.exists(), true);
      library.resetLibraryForTesting();
      await library.init(deferMaintenance: true);
      expect(library.isInitialized, true);
      expect(library.transientVideos, isEmpty);
      expect(await file.exists(), true);
      expect(await library.transientLedgerFileForTesting.exists(), true);
      // A second process death before the home idle period must not orphan it.
      library.resetLibraryForTesting();
      await library.init();
      expect(await file.exists(), false);
      expect(await library.transientLedgerFileForTesting.exists(), false);
    });

    test('parts left by a crash are removed at the next start', () async {
      final api = _FakeApi(pages: 3);
      final service = newService(api);
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 2,
      );
      final queue = plan.queue!;
      expect(await service.completeWatchPart(library, queue[2].id), isTrue);
      final files = [File(queue[1].danmakuPath!), File(queue[2].danmakuPath!)];
      final cacheDirs = <Directory>[];
      for (final v in queue) {
        final dir = Directory(
          p.join(
            root.path,
            'bilibili_stream_cache',
            BilibiliStreamingService.cacheEntryName(v.id),
          ),
        );
        await dir.create(recursive: true);
        await File(p.join(dir.path, 'piece.m4s')).writeAsBytes([1]);
        cacheDirs.add(dir);
      }
      expect(files.every((f) => f.existsSync()), isTrue);

      library.resetLibraryForTesting();
      await library.init();
      expect(library.transientVideos, isEmpty);
      expect(files.any((f) => f.existsSync()), isFalse);
      expect(cacheDirs.any((d) => d.existsSync()), isFalse);
      expect(library.transientLedgerFileForTesting.existsSync(), isFalse);
    });

    test('the arriving data keeps the subtitle the user already chose, '
        'and its tracks keep their language code', () async {
      final service = newService(
        _FakeApi(
          pages: 3,
          subtitles: <BilibiliSubtitle>[
            BilibiliSubtitle(
              id: '1',
              lan: 'zh-CN',
              lanDoc: '中文',
              url: 'https://aisubtitle.hdslb.com/zh.json',
              isAi: false,
            ),
            BilibiliSubtitle(
              id: '2',
              lan: 'ai-en',
              lanDoc: '英语（自动生成）',
              url: 'https://aisubtitle.hdslb.com/ai-en.json',
              isAi: true,
            ),
          ],
        ),
      );
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 1,
      );
      final queue = plan.queue!;
      // No choice yet: the preferred track becomes the subtitle.
      expect(await service.completeWatchPart(library, queue[1].id), isTrue);
      final plain = library.getVideo(queue[1].id)!;
      expect(plain.subtitlePath, isNotNull);
      expect(
        plain.managedSubtitleAssets.map((a) => a.language),
        unorderedEquals(<String>['zh-CN', 'ai-en']),
      );

      // Picked before the data came: it stays.
      final picked = library.getVideo(queue[2].id)!..subtitlePath = '/mine.srt';
      expect(await service.completeWatchPart(library, picked.id), isTrue);
      expect(library.getVideo(picked.id)!.subtitlePath, '/mine.srt');
      expect(library.getVideo(picked.id)!.additionalSubtitles, hasLength(2));
    });

    test('a part turned off before its data came stays off', () async {
      final service = newService(
        _FakeApi(
          pages: 2,
          subtitles: <BilibiliSubtitle>[
            BilibiliSubtitle(
              id: '1',
              lan: 'zh-CN',
              lanDoc: '中文',
              url: 'https://aisubtitle.hdslb.com/zh.json',
              isAi: false,
            ),
          ],
        ),
      );
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 1,
      );
      final off = library.getVideo(plan.queue![1].id)!
        ..blockAutoAssociatedSubtitleSelection = true;
      expect(await service.completeWatchPart(library, off.id), isTrue);
      expect(library.getVideo(off.id)!.subtitlePath, isNull);
    });

    test('a part removed while it was being built leaves no files', () async {
      final service = newService(_FakeApi(pages: 2));
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 1,
      );
      final other = plan.queue![1];
      final building = service.completeWatchPart(library, other.id);
      await library.discardTransientVideo(other.id);
      expect(await building, isFalse);
      expect(library.getVideo(other.id), isNull);
      final danmakuDir = Directory(p.join(root.path, 'danmaku'));
      final names = danmakuDir.existsSync()
          ? danmakuDir.listSync().map((e) => p.basename(e.path)).toList()
          : const <String>[];
      expect(names.where((n) => n.startsWith(other.id)), isEmpty);
    });

    test('importing while watching: watched parts become library cards in '
        'place with their progress, the rest is created, order and folder as '
        'a normal import', () async {
      final history = BilibiliHistoryService.instance;
      // Reference: a normal import of the whole video.
      final reference = await runBilibiliQuickImport(
        service: newService(_FakeApi(pages: 3)),
        library: library,
        bvid: _bvid,
        page: 2,
        target: BilibiliImportTarget.automatic,
        history: history,
      );
      final refFolder = library.getCollection(reference.item.parentId!)!;
      final refFolderName = refFolder.name;
      final refFolderParent = refFolder.parentId;
      final refOrder = library
          .getVideosInFolder(refFolder.id)
          .map((v) => v.sourceRef?.page)
          .toList();
      expect(refOrder, [1, 2, 3]);

      // Fresh library for the same video.
      library.resetLibraryForTesting();
      for (final name in ['library.json', 'library.json.bak']) {
        final file = File(p.join(root.path, name));
        if (file.existsSync()) await file.delete();
      }
      await library.init();
      history.resetForTest();
      expect(library.bilibiliStreamItems, isEmpty);
      expect(library.getContents(null), isEmpty);

      final api = _FakeApi(pages: 3);
      final service = newService(api);
      final plan = await prepareBilibiliWatch(
        service: service,
        library: library,
        bvid: _bvid,
        page: 1,
        history: history,
      );
      final queue = plan.queue!;
      expect(await service.completeWatchPart(library, queue[1].id), isTrue);
      await library.updateVideoProgress(queue[0].id, 40000);
      await library.updateVideoProgress(queue[1].id, 15000);
      expect(service.isPendingWatchPart(queue[2].id), isTrue);

      final result = await runBilibiliQuickImport(
        service: service,
        library: library,
        bvid: _bvid,
        page: 2,
        target: BilibiliImportTarget.automatic,
        history: history,
        playingItemId: queue[1].id,
      );
      expect(result.alreadyImported, isFalse);

      // No watch-only card and no duplicate left for the video.
      expect(watchOnlyOf(_bvid), isEmpty);
      final cardsNow = library.bilibiliStreamItems
          .where((v) => bilibiliStreamCardBvid(v) == _bvid)
          .toList();
      expect(cardsNow, hasLength(3));
      expect(cardsNow.map((v) => v.sourceRef?.page).toSet(), {1, 2, 3});

      // Watched parts: same card, own progress.
      expect(library.getVideo(queue[0].id), same(queue[0]));
      expect(queue[0].isTransient, isFalse);
      expect(queue[0].lastPositionMs, 40000);
      expect(library.getVideo(queue[1].id), same(queue[1]));
      expect(queue[1].lastPositionMs, 15000);
      // The part never opened is a complete library card.
      final third = cardsNow.firstWhere((v) => v.sourceRef?.page == 3);
      expect(third.isTransient, isFalse);
      expect(third.danmakuPath, isNotNull);

      // Same folder and order as the normal import.
      final folder = library.getCollection(queue[0].parentId!)!;
      expect(folder.name, refFolderName);
      expect(folder.parentId, refFolderParent);
      expect(cardsNow.every((v) => v.parentId == folder.id), isTrue);
      expect(
        library
            .getVideosInFolder(folder.id)
            .map((v) => v.sourceRef?.page)
            .toList(),
        refOrder,
      );
      // And they now show up where library cards do.
      final recent = library.activityProjection.recentAddedMediaIds();
      expect({
        ...recent.datedIds,
        ...recent.unknownAddedIds,
      }, containsAll(cardsNow.map((v) => v.id)));
    });
  });

  group('entries play directly', () {
    testWidgets('the watch history list hands the entry to the player', (
      tester,
    ) async {
      final history = BilibiliHistoryService.instance;
      await tester.runAsync(
        () => history.recordWatch(
          BilibiliWatchHistoryEntry(
            bvid: _bvid,
            title: '看过的视频',
            coverUrl: 'https://i0.hdslb.com/a.jpg',
            watchedAt: DateTime.now(),
            page: 2,
            positionMs: 125000,
          ),
        ),
      );
      final opened = <BilibiliWatchHistoryEntry>[];
      await tester.pumpWidget(
        MaterialApp(
          home: BilibiliWatchHistoryScreen(
            history: history,
            fetchCover: (_) async => null,
            onOpen: (context, entry) async => opened.add(entry),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('看到 2:05'), findsOneWidget);
      await tester.tap(find.text('看过的视频'));
      await tester.pumpAndSettle();
      expect(opened.single.page, 2);
      expect(opened.single.positionMs, 125000);
    });

    test('a copied link plays its own video', () {
      expect(
        clipboardWatchBvid(const BilibiliLinkTarget(bvid: _bvid, page: 2)),
        _bvid,
      );
      expect(
        clipboardWatchBvid(
          const BilibiliLinkTarget(bvid: _bvid),
          targetBvid: 'BV1GJ411x7h7',
        ),
        'BV1GJ411x7h7',
      );
      expect(
        clipboardWatchBvid(const BilibiliLinkTarget(aid: 170001)),
        bvidFromAid(170001),
      );
      expect(
        clipboardWatchBvid(const BilibiliLinkTarget(bangumiId: 'ep1')),
        isNull,
      );
    });

    test('position text', () {
      expect(formatBilibiliWatchPosition(0), '0:00');
      expect(formatBilibiliWatchPosition(125000), '2:05');
      expect(formatBilibiliWatchPosition(3723000), '1:02:03');
    });
  });
}

VideoItem _streamCard({
  required String id,
  required String title,
  int page = 1,
  bool transient = false,
  String? danmakuPath,
  int? lastUpdated,
}) {
  final cid = 100 + page;
  return VideoItem(
    id: id,
    path: 'bilibili://stream/$_bvid?cid=$cid',
    title: title,
    durationMs: 600000,
    lastUpdated:
        lastUpdated ??
        DateTime.now()
            .subtract(const Duration(minutes: 10))
            .millisecondsSinceEpoch,
    sourceFingerprint: 'bilibili-stream-card:$id',
    isBilibiliExported: true,
    danmakuPath: danmakuPath,
    isTransient: transient,
    sourceRef: MediaSourceRef(
      value: _bvid,
      kind: MediaSourceKind.bilibiliStream,
      bvid: _bvid,
      cid: cid,
      page: page,
    ),
  );
}

class _FakeApi extends BilibiliApiService {
  _FakeApi({required this.pages, this.subtitles = const <BilibiliSubtitle>[]});

  final int pages;
  final List<BilibiliSubtitle> subtitles;
  int metadataRequests = 0;

  @override
  Future<dynamic> fetchSubtitleContent(String url) async => <String, Object?>{
    'body': <Object?>[
      <String, Object?>{'from': 0.0, 'to': 1.0, 'content': url},
    ],
  };

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    return BilibiliVideoInfo(
      title: '测试视频',
      desc: '',
      pic: '',
      bvid: _bvid,
      aid: '123',
      ownerName: 'UP',
      ownerMid: '1',
      pubDate: 0,
      pages: <BilibiliPage>[
        for (var i = 1; i <= pages; i++)
          BilibiliPage(
            cid: 100 + i,
            page: i,
            part: '第 $i 部分',
            duration: 600,
            bvid: _bvid,
            aid: '123',
          ),
      ],
    );
  }

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async {
    metadataRequests++;
    return BilibiliPlayerMetadata(subtitles: subtitles);
  }

  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _FakePlayback extends ChangeNotifier {
  String? currentId;

  void change(String? id) {
    currentId = id;
    notifyListeners();
  }
}

class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.rootPath);

  final String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;

  @override
  Future<String?> getApplicationSupportPath() async => rootPath;

  @override
  Future<String?> getApplicationCachePath() async => rootPath;

  @override
  Future<String?> getTemporaryPath() async => rootPath;

  @override
  Future<String?> getDownloadsPath() async => rootPath;
}
