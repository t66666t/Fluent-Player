import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/widgets/video_controls_overlay.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/screens/bilibili/bilibili_card_actions.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_loading_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_page_layout.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_open_timeline.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_launch.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_orientation.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_playlist.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/media_playback_service.dart';
import 'package:video_player_app/services/playback_navigation_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/utils/app_toast.dart';
import 'package:video_player_app/widgets/bilibili_cover_image.dart';

import 'test_dir_cleanup.dart';

const _bvid = 'BV1xx411c7mD';
const _cover = 'https://i0.hdslb.com/bfs/archive/cover.jpg';

/// Texts of the floating notice the tap used to show while loading.
const _oldLoadingNotices = <String>['正在加载播放', '正在准备播放'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('signing keys and device id are asked once', () {
    test('logged-in API: one nav for many play addresses, again after '
        'the key lifetime', () async {
      var now = DateTime(2026, 10, 8, 12);
      final adapter = _FakeAdapter((options) {
        if (options.path.endsWith('/x/web-interface/nav')) return _navJson();
        if (options.path.endsWith('/x/player/wbi/playurl')) {
          return _json(_playUrlPayload());
        }
        throw StateError('unexpected ${options.uri}');
      });
      final api = BilibiliApiService(
        httpClientAdapter: adapter,
        clock: () => now,
      );
      int navCalls() =>
          adapter.requests.where((r) => r.path.endsWith('/nav')).length;

      // Two at the same time share one nav request.
      await Future.wait([
        api.fetchPlayUrl(_bvid, 1),
        api.fetchPlayUrl(_bvid, 2),
      ]);
      expect(navCalls(), 1);
      await api.fetchPlayUrl(_bvid, 3);
      expect(navCalls(), 1, reason: 'the keys are reused');

      now = now.add(BilibiliApiService.wbiKeyLifetime);
      await api.fetchPlayUrl(_bvid, 4);
      expect(navCalls(), 2, reason: 'old keys are asked again');
      expect(
        adapter.requests.where((r) => r.path.endsWith('/wbi/playurl')).length,
        4,
      );
    });

    test('public API: one nav and one device id for many signed '
        'requests', () async {
      var now = DateTime(2026, 10, 8, 12);
      final adapter = _FakeAdapter((options) {
        final path = options.path;
        if (path.endsWith('/x/web-interface/view')) {
          return ResponseBody.fromString('<html></html>', 412);
        }
        if (path.endsWith('/x/web-interface/wbi/view')) {
          final bvid = options.queryParameters['bvid'];
          return _json({
            'code': 0,
            'data': {'bvid': bvid, 'title': '标题 $bvid'},
          });
        }
        if (path.endsWith('/x/web-interface/nav')) return _navJson();
        if (path.endsWith('/x/frontend/finger/spi')) {
          return _json({
            'code': 0,
            'data': {'b_3': 'ANON-ID'},
          });
        }
        return _json({'code': 0, 'data': []});
      });
      final api = BilibiliPublicApiService(
        httpClientAdapter: adapter,
        clock: () => now,
      );
      int calls(String suffix) =>
          adapter.requests.where((r) => r.path.endsWith(suffix)).length;

      await Future.wait([
        api.fetchVideoDetail(bvid: 'BV1aa411c7mA'),
        api.fetchVideoDetail(bvid: 'BV1bb411c7mB'),
      ]);
      await api.fetchVideoDetail(bvid: 'BV1cc411c7mC');
      // One device id before the first request; the risk hits share one
      // renewal of keys and device id.
      expect(calls('/nav'), 1);
      expect(calls('/finger/spi'), 2);
      expect(calls('/wbi/view'), 3);

      now = now.add(BilibiliPublicApiService.wbiKeyLifetime);
      await api.fetchVideoDetail(bvid: 'BV1dd411c7mD');
      expect(calls('/nav'), 2);
      expect(
        calls('/finger/spi'),
        3,
        reason: 'a risk hit long after the last renewal renews again',
      );
    });
  });

  group('play address cache', () {
    test('a second tap on the same part reuses the fetched address', () async {
      final api = _PlayUrlApi(
        deadline: DateTime.now().toUtc().add(const Duration(hours: 2)),
      );
      final service = BilibiliDownloadService(apiService: api);
      addTearDown(service.shutdown);
      final warm = bilibiliPlayUrlWarmer(service);

      await warm(_bvid, 101);
      await warm(_bvid, 101);
      expect(api.playUrlCalls, 1);

      // Another part has its own address.
      await warm(_bvid, 102);
      expect(api.playUrlCalls, 2);
    });

    test('an address about to expire is fetched again', () async {
      final api = _PlayUrlApi(
        deadline: DateTime.now().toUtc().add(const Duration(seconds: 30)),
      );
      final service = BilibiliDownloadService(apiService: api);
      addTearDown(service.shutdown);
      final warm = bilibiliPlayUrlWarmer(service);

      await warm(_bvid, 101);
      await warm(_bvid, 101);
      expect(api.playUrlCalls, 2);
    });
  });

  group('info cache', () {
    test('keeps infos for its lifetime and drops the oldest', () {
      var now = DateTime(2026, 10, 8, 12);
      final cache = BilibiliWatchInfoCache(capacity: 2, clock: () => now);
      cache.put('BV1', _info(bvid: 'BV1'));
      cache.put('BV2', _info(bvid: 'BV2'));
      cache.put('BV3', _info(bvid: 'BV3'));
      expect(cache.get('BV1'), isNull);
      expect(cache.get('BV3')?.bvid, 'BV3');

      now = now.add(cache.lifetime);
      expect(cache.get('BV3'), isNull);
      expect(cache.length, 1);
    });
  });

  group('loader', () {
    late Directory root;
    late LibraryService library;
    late PathProviderPlatform originalPathProvider;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      BilibiliHistoryService.instance.resetForTest();
      root = await Directory.systemTemp.createTemp('bilibili_watch_launch_');
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
      await deleteTestTempDir(root);
    });

    BilibiliDownloadService newService(_WatchApi api) {
      final service = BilibiliDownloadService(apiService: api);
      addTearDown(service.shutdown);
      return service;
    }

    test('the play address is asked next to the panel detail and the card, '
        'and the player data is not waited for', () async {
      final api = _WatchApi();
      final service = newService(api);
      final detailRequest = Completer<BilibiliVideoDetail>();
      var detailCalls = 0;
      final details = BilibiliVideoDetailCache(
        fetch: (_) {
          detailCalls++;
          return detailRequest.future;
        },
      );
      final timeline = BilibiliOpenTimeline(_bvid);
      final signing = Completer<void>();
      var signingStarted = false;
      final warmRequest = Completer<void>();
      List<String>? stepsWhenWarmStarted;
      var detailPendingWhenWarmStarted = false;
      final loader = BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: _bvid,
        details: details,
        infoCache: BilibiliWatchInfoCache(),
        fetchInfo: (_) async {
          // The signing keys are already on their way with the info.
          expect(signingStarted, isTrue);
          return _info();
        },
        warmSigning: () {
          signingStarted = true;
          return signing.future;
        },
        warmPlayUrl: (bvid, cid) {
          stepsWhenWarmStarted = [for (final mark in timeline.marks) mark.step];
          detailPendingWhenWarmStarted = !detailRequest.isCompleted;
          return warmRequest.future;
        },
      );

      var done = false;
      final plan = loader(BilibiliWatchAttempt(timeline))
        ..then((_) => done = true);
      while (stepsWhenWarmStarted == null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // The play address starts right after the video info, before the
      // card exists, while the panel detail is still on its way.
      expect(detailCalls, 1);
      expect(detailPendingWhenWarmStarted, isTrue);
      expect(stepsWhenWarmStarted, contains('video info'));
      expect(stepsWhenWarmStarted, isNot(contains('card ready')));

      // The card gets made while the address is still loading.
      while (!timeline.marks.any((m) => m.step == 'card ready')) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(done, isFalse, reason: 'waits for the address');
      signing.complete();
      warmRequest.complete();
      final ready = await plan;

      expect(timeline.msOf('play address'), isNotNull);
      expect(ready.item.isTransient, isTrue);
      expect(ready.item.sourceRef?.bvid, _bvid);
      expect(ready.item.sourceRef?.cid, 101);
      // Cover, subtitles, danmaku and preview frames come later.
      expect(api.metadataRequests, 0);
      expect(api.danmakuRequests, 0);
      expect(api.videoShotRequests, 0);
      expect(ready.item.danmakuPath, isNull);
      // The panel detail never held the page back.
      expect(detailRequest.isCompleted, isFalse);
      detailRequest.complete(_detail());
    });

    test('the cover finishes asynchronously at the same card path, where it '
        'keeps it', () async {
      final adapter = _FakeAdapter((options) {
        if (options.uri.toString() == _cover) {
          return ResponseBody.fromBytes(const <int>[1, 2, 3], 200);
        }
        throw StateError('unexpected ${options.uri}');
      });
      final service = newService(_WatchApi(httpClientAdapter: adapter));
      await service.init();
      final timeline = BilibiliOpenTimeline(_bvid);
      final plan = await BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: _bvid,
        fetchInfo: (_) async => _info(),
        warmPlayUrl: (_, _) async {},
        warmCover: (item) => service.prefetchWatchCover(library, item.id),
      )(BilibiliWatchAttempt(timeline));

      for (var i = 0; i < 200 && timeline.msOf('cover') == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final path = library.getVideo(plan.item.id)!.thumbnailPath!;
      expect(File(path).readAsBytesSync(), const <int>[1, 2, 3]);
      // The completed card writes its cover to this same file.
      expect(path.split(Platform.pathSeparator).last, '${plan.item.id}.jpg');
      expect(timeline.msOf('cover'), isNotNull);
      expect(adapter.requests, hasLength(1));
    });

    test('a second tap uses the remembered info', () async {
      final api = _WatchApi();
      final service = newService(api);
      final infoCache = BilibiliWatchInfoCache();
      var infoCalls = 0;
      final warmed = <String>[];
      BilibiliWatchLoader loader() => BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: _bvid,
        infoCache: infoCache,
        fetchInfo: (_) async {
          infoCalls++;
          return _info();
        },
        warmPlayUrl: (bvid, cid) async => warmed.add('$bvid#$cid'),
      );

      final first = await loader()(
        BilibiliWatchAttempt(BilibiliOpenTimeline(_bvid)),
      );
      final secondTimeline = BilibiliOpenTimeline(_bvid);
      final second = await loader()(BilibiliWatchAttempt(secondTimeline));

      expect(infoCalls, 1);
      expect(secondTimeline.msOf('info from memory'), isNotNull);
      expect(second.item.id, first.item.id, reason: 'same BV + part card');
      expect(warmed, ['$_bvid#101', '$_bvid#101']);
    });

    test('a known panel detail gives the info without asking', () async {
      final api = _WatchApi();
      final service = newService(api);
      final details = BilibiliVideoDetailCache(fetch: (_) async => _detail());
      await details.get(_bvid);
      var infoCalls = 0;
      final plan = await BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: _bvid,
        details: details,
        fetchInfo: (_) async {
          infoCalls++;
          return _info();
        },
      )(BilibiliWatchAttempt(BilibiliOpenTimeline(_bvid)));

      expect(infoCalls, 0);
      expect(plan.item.sourceRef?.cid, 101);
    });

    test('a cancelled try made no card, or removes the one it made', () async {
      final api = _WatchApi();
      final service = newService(api);
      final info = Completer<BilibiliVideoInfo>();
      final early = BilibiliWatchAttempt(BilibiliOpenTimeline(_bvid));
      final first = BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: _bvid,
        fetchInfo: (_) => info.future,
      )(early);
      early.cancel();
      info.complete(_info());
      await expectLater(first, throwsA(isA<BilibiliWatchCancelledException>()));
      expect(library.transientVideos, isEmpty);

      // Cancelled while the play address loads: the card exists already.
      final warm = Completer<void>();
      final warming = Completer<void>();
      final late = BilibiliWatchAttempt(BilibiliOpenTimeline(_bvid));
      final second = BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: _bvid,
        fetchInfo: (_) async => _info(),
        warmPlayUrl: (_, _) {
          warming.complete();
          return warm.future;
        },
      )(late);
      await warming.future;
      while (!late.timeline.marks.any(
        (mark) => mark.step == 'watch plan ready',
      )) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(library.transientVideos, isNotEmpty);
      late.cancel();
      warm.complete();
      final plan = await second;
      expect(plan.createdItemIds, contains(plan.item.id));
      await discardAbandonedWatch(plan, library: library);
      expect(library.transientVideos, isEmpty);
      expect(library.getVideo(plan.item.id), isNull);
    });

    test('a card that is playing is never removed', () async {
      final api = _WatchApi();
      final service = newService(api);
      final plan = await BilibiliWatchLoader(
        service: service,
        library: library,
        bvid: _bvid,
        fetchInfo: (_) async => _info(),
      )(BilibiliWatchAttempt(BilibiliOpenTimeline(_bvid)));

      await discardAbandonedWatch(
        plan,
        library: library,
        playingItemId: plan.item.id,
      );
      expect(library.getVideo(plan.item.id), isNotNull);
    });
  });

  group('watch history of given-up tries', () {
    late Directory root;
    late LibraryService library;
    late PathProviderPlatform originalPathProvider;
    final history = BilibiliHistoryService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      history.resetForTest();
      root = await Directory.systemTemp.createTemp('bilibili_watch_history_');
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
      history.resetForTest();
      PathProviderPlatform.instance = originalPathProvider;
      await deleteTestTempDir(root);
    });

    BilibiliDownloadService newService() {
      final service = BilibiliDownloadService(apiService: _WatchApi());
      addTearDown(service.shutdown);
      return service;
    }

    /// A launch as the loading page runs it; [opened] gets the plan whose
    /// playback page opens (with its history entry written as on open).
    BilibiliWatchLaunch<BilibiliWatchPlan> launchOf(
      BilibiliDownloadService service, {
      required Future<void> Function(int attempt) warm,
      required List<BilibiliWatchPlan> opened,
      BilibiliVideoInfo? info,
      Duration timeLimit = kBilibiliWatchTimeLimit,
      bool openOnReady = true,
      String? playingItemId,
      Iterable<String> openPageItemIds = const <String>[],
      Iterable<String> Function()? listed,
    }) {
      var tries = 0;
      final launch = BilibiliWatchLaunch<BilibiliWatchPlan>(
        timelineFor: () => BilibiliOpenTimeline(_bvid),
        timeLimit: timeLimit,
        load: (attempt) {
          final number = ++tries;
          return BilibiliWatchLoader(
            service: service,
            library: library,
            bvid: _bvid,
            history: history,
            fetchInfo: (_) async => info ?? _info(),
            warmPlayUrl: (_, _) => warm(number),
          )(attempt);
        },
        onReady: (plan, _) {
          if (!openOnReady) return;
          opened.add(plan);
          unawaited(noteOpenedWatch(plan, history: history));
        },
        discard: (plan, kept) => discardAbandonedWatch(
          plan,
          library: library,
          playingItemId: playingItemId,
          openPageItemIds: openPageItemIds,
          keep: <String>{...?kept?.itemIds, ...?listed?.call()},
        ),
      );
      addTearDown(launch.dispose);
      return launch;
    }

    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 400 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(done(), isTrue);
    }

    int entriesOf(String bvid) =>
        history.watchHistory.where((e) => e.bvid == bvid).length;

    test('back at the moment the video got ready: no entry, no card', () async {
      await history.recordWatch(
        BilibiliWatchHistoryEntry(
          bvid: 'BV1other11111',
          title: 'other',
          ownerName: 'UP',
          coverUrl: '',
          page: 1,
          partTitle: '',
          watchedAt: DateTime(2026, 10, 1),
        ),
      );
      final service = newService();
      final warm = Completer<void>();
      final opened = <BilibiliWatchPlan>[];
      final launch = launchOf(service, warm: (_) => warm.future, opened: opened)
        ..start();
      await until(() => library.transientVideos.isNotEmpty);

      // The answer and back meet: back is handled first.
      warm.complete();
      launch.cancel();
      await until(() => library.transientVideos.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(opened, isEmpty);
      expect(history.watchHistory, hasLength(1));
      expect(entriesOf(_bvid), 0);
    });

    test(
      'a video already in the history keeps one entry, updated on open',
      () async {
        await history.recordWatch(
          BilibiliWatchHistoryEntry(
            bvid: _bvid,
            title: '测试视频',
            ownerName: 'UP',
            coverUrl: _cover,
            page: 1,
            partTitle: '',
            watchedAt: DateTime(2026, 10, 1),
            positionMs: 1000,
          ),
        );
        final service = newService();

        // Given up while getting ready: the entry is left as it was.
        final warm = Completer<void>();
        final opened = <BilibiliWatchPlan>[];
        final first = launchOf(
          service,
          warm: (_) => warm.future,
          opened: opened,
        )..start();
        await until(() => library.transientVideos.isNotEmpty);
        warm.complete();
        first.cancel();
        await until(() => library.transientVideos.isEmpty);
        expect(history.watchHistory.single.watchedAt, DateTime(2026, 10, 1));

        // Opened: the same entry moves up, no second one.
        launchOf(service, warm: (_) async {}, opened: opened).start();
        await until(() => opened.isNotEmpty);
        await until(
          () => history.watchHistory.single.watchedAt != DateTime(2026, 10, 1),
        );
        expect(history.watchHistory, hasLength(1));
        expect(history.watchHistory.single.bvid, _bvid);
        expect(history.watchHistory.single.positionMs, 1000);
      },
    );

    BilibiliVideoInfo twoParts() => BilibiliVideoInfo(
      title: '测试视频',
      desc: '',
      pic: _cover,
      bvid: _bvid,
      aid: '123',
      ownerName: 'UP',
      ownerMid: '1',
      pubDate: 0,
      pages: <BilibiliPage>[
        BilibiliPage(cid: 101, page: 1, part: '上', duration: 600),
        BilibiliPage(cid: 102, page: 2, part: '下', duration: 600),
      ],
    );

    for (final lateFirst in <bool>[true, false]) {
      test('time limit, retry, then back in the instant between ready and '
          'open (the given-up try answers ${lateFirst ? 'before' : 'after'}): '
          'every card goes at once', () async {
        final service = newService();
        final firstWarm = Completer<void>();
        final opened = <BilibiliWatchPlan>[];
        final launch = launchOf(
          service,
          info: twoParts(),
          timeLimit: const Duration(milliseconds: 200),
          warm: (attempt) => attempt == 1 ? firstWarm.future : Future.value(),
          opened: opened,
          openOnReady: false,
        )..start();
        await until(() => library.transientVideos.length == 2);
        await until(() => launch.phase == BilibiliWatchLaunchPhase.failed);
        if (lateFirst) firstWarm.complete();
        launch.retry();
        await until(() => launch.phase == BilibiliWatchLaunchPhase.ready);
        if (!lateFirst) firstWarm.complete();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // The retry took over the cards of the given-up try.
        expect(library.transientVideos, hasLength(2));

        launch.discardReady();
        await until(() => library.transientVideos.isEmpty);
        expect(opened, isEmpty);
        expect(entriesOf(_bvid), 0);
      });
    }

    test('back in that instant spares what plays, what another page shows '
        'and the Bilibili playlist\'s entries', () async {
      final service = newService();
      final firstWarm = Completer<void>();
      final protected = <String>{};
      String? playing;
      final pages = <String>[];
      final launch = launchOf(
        service,
        info: twoParts(),
        timeLimit: const Duration(milliseconds: 200),
        warm: (attempt) => attempt == 1 ? firstWarm.future : Future.value(),
        opened: <BilibiliWatchPlan>[],
        openOnReady: false,
        listed: () => protected,
      )..start();
      await until(() => library.transientVideos.length == 2);
      await until(() => launch.phase == BilibiliWatchLaunchPhase.failed);
      firstWarm.complete();
      launch.retry();
      await until(() => launch.phase == BilibiliWatchLaunchPhase.ready);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final ids = library.transientVideos.map((v) => v.id).toList();
      expect(ids, hasLength(2));
      // Part 2 sits in the Bilibili playlist.
      protected.add(ids.last);
      launch.discardReady();
      await until(() => library.transientVideos.length == 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(library.transientVideos.single.id, ids.last);

      // Playing and open-page cards stay too.
      final plan = BilibiliWatchPlan(
        item: library.transientVideos.single,
        videoInfo: twoParts(),
        imported: false,
        createdItemIds: <String>{ids.last},
      );
      playing = ids.last;
      pages.add(ids.last);
      protected.clear();
      await discardAbandonedWatch(
        plan,
        library: library,
        playingItemId: playing,
      );
      await discardAbandonedWatch(
        plan,
        library: library,
        openPageItemIds: pages,
      );
      expect(library.transientVideos.single.id, ids.last);
    });

    for (final lateFirst in <bool>[true, false]) {
      test('time limit, then retry (the given-up try answers '
          '${lateFirst ? 'before' : 'after'} the retry): one entry, one '
          'card per part', () async {
        final service = newService();
        final firstWarm = Completer<void>();
        final secondWarm = Completer<void>();
        final opened = <BilibiliWatchPlan>[];
        final launch = launchOf(
          service,
          info: twoParts(),
          timeLimit: const Duration(milliseconds: 200),
          warm: (attempt) =>
              attempt == 1 ? firstWarm.future : secondWarm.future,
          opened: opened,
        )..start();
        await until(() => launch.phase == BilibiliWatchLaunchPhase.failed);
        // The first try made the card and the entry of the other part.
        expect(library.transientVideos, hasLength(2));

        launch.retry();
        if (lateFirst) {
          firstWarm.complete();
          await Future<void>.delayed(const Duration(milliseconds: 30));
          secondWarm.complete();
        } else {
          secondWarm.complete();
          await until(() => opened.isNotEmpty);
          firstWarm.complete();
        }
        await until(() => opened.isNotEmpty);
        await until(() => entriesOf(_bvid) == 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final plan = opened.single;
        // The retry reused what the first try made; nothing it plays or
        // lists was removed, and nothing is left twice.
        expect(library.transientVideos, hasLength(2));
        expect(
          library.transientVideos.map((item) => item.id).toSet(),
          plan.itemIds,
        );
        for (final id in plan.itemIds) {
          expect(library.getVideo(id), isNotNull);
        }
        expect(history.watchHistory, hasLength(1));
      });
    }

    test('back after a timed-out try: both tries leave nothing', () async {
      final service = newService();
      final firstWarm = Completer<void>();
      final secondWarm = Completer<void>();
      final opened = <BilibiliWatchPlan>[];
      final launch = launchOf(
        service,
        timeLimit: const Duration(milliseconds: 200),
        warm: (attempt) => attempt == 1 ? firstWarm.future : secondWarm.future,
        opened: opened,
      )..start();
      await until(() => launch.phase == BilibiliWatchLaunchPhase.failed);
      launch.retry();
      firstWarm.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      launch.cancel();
      secondWarm.complete();
      await until(() => library.transientVideos.isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(opened, isEmpty);
      expect(history.watchHistory, isEmpty);
    });
  });

  group('late player data', () {
    VideoItem card({String? subtitle}) => VideoItem(
      id: 'watch-1',
      path: 'bilibili://stream/$_bvid?cid=101',
      title: '测试视频',
      durationMs: 600000,
      lastUpdated: 0,
      subtitlePath: subtitle,
    );

    test('the arrived subtitle is loaded for the card that plays', () async {
      final loaded = <List<String>>[];
      Future<bool> load({
        required String itemId,
        required List<String> paths,
      }) async {
        loaded.add(paths);
        return true;
      }

      await applyCompletedWatchCard(
        item: card(subtitle: '/subs/zh.srt'),
        currentItemId: 'watch-1',
        loadedSubtitlePaths: const <String>[],
        loadSubtitles: load,
      );
      expect(loaded, [
        ['/subs/zh.srt'],
      ]);

      // A subtitle the user already picked stays.
      await applyCompletedWatchCard(
        item: card(subtitle: '/subs/zh.srt'),
        currentItemId: 'watch-1',
        loadedSubtitlePaths: const <String>['/mine.srt'],
        loadSubtitles: load,
      );
      expect(loaded.last, ['/mine.srt']);

      // Another video plays: nothing is touched.
      await applyCompletedWatchCard(
        item: card(subtitle: '/subs/zh.srt'),
        currentItemId: 'other',
        loadedSubtitlePaths: const <String>[],
        loadSubtitles: load,
      );
      expect(loaded, hasLength(2));
    });

    test(
      'subtitles the user turned off stay off when the data arrives',
      () async {
        final loaded = <List<String>>[];
        Future<bool> load({
          required String itemId,
          required List<String> paths,
        }) async {
          loaded.add(paths);
          return true;
        }

        await applyCompletedWatchCard(
          item: card(subtitle: '/subs/zh.srt')
            ..blockAutoAssociatedSubtitleSelection = true,
          currentItemId: 'watch-1',
          loadedSubtitlePaths: const <String>[],
          loadSubtitles: load,
        );
        expect(loaded, isEmpty);
      },
    );
  });

  group('loading page', () {
    setUp(() {
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        details: BilibiliVideoDetailCache(
          fetch: (_) async => throw StateError(
            'Details are independent of loading-route tests',
          ),
        ),
      );
    });
    tearDown(() => BilibiliWatchSources.overrideForTesting = null);
    Future<void> pumpHost(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: AppToast.navigatorKey,
          home: const Scaffold(body: Text('list')),
        ),
      );
    }

    void push(
      Future<BilibiliWatchPlan> Function(BilibiliWatchAttempt) load, {
      required List<BilibiliWatchPlan> opened,
      List<BilibiliWatchPlan>? discarded,
      List<String>? discardLog,
      BilibiliWatchPreview? preview = const BilibiliWatchPreview(
        title: '测试视频',
        coverUrl: _cover,
      ),
      BilibiliWatchPageShape? shape,
      BilibiliWatchOrientation orientation = const _NoOrientation(),
    }) {
      unawaited(
        AppToast.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(
              name: BilibiliWatchLoadingPage.routeName,
            ),
            builder: (_) => BilibiliWatchLoadingPage(
              bvid: _bvid,
              preview: preview,
              timeline: () => BilibiliOpenTimeline(_bvid),
              load: load,
              open: (navigator, page, plan, _) async {
                opened.add(plan);
                navigator.replace(
                  oldRoute: page,
                  newRoute: MaterialPageRoute<void>(
                    builder: (_) => Text('player ${plan.item.id}'),
                  ),
                );
              },
              discard: (plan, kept) async {
                discarded?.add(plan);
                discardLog?.add('${plan.item.id}<-${kept?.item.id}');
              },
              shape: shape,
              orientation: orientation,
            ),
          ),
        ),
      );
    }

    group('skipping the portrait page on a phone', () {
      const phoneLandscape = BilibiliWatchPageShape(
        landscape: true,
        isMobilePlatform: true,
      );

      testWidgets('landscape is asked for on entry and kept into the '
          'player, with no turn back to portrait', (tester) async {
        await pumpHost(tester);
        final orientation = _FakeOrientation();
        final ready = Completer<BilibiliWatchPlan>();
        final opened = <BilibiliWatchPlan>[];
        push(
          (_) => ready.future,
          opened: opened,
          shape: phoneLandscape,
          orientation: orientation,
        );
        await showRoute(tester);
        expect(orientation.calls, ['landscape']);

        ready.complete(_plan('watch-1'));
        await tester.pumpAndSettle();
        expect(find.text('player watch-1'), findsOneWidget);
        expect(orientation.calls, ['landscape']);
      });

      for (final how in const <String>['back button', 'system back']) {
        testWidgets('$how gives the orientation back, once', (tester) async {
          await pumpHost(tester);
          final orientation = _FakeOrientation();
          final opened = <BilibiliWatchPlan>[];
          push(
            (_) => Completer<BilibiliWatchPlan>().future,
            opened: opened,
            shape: phoneLandscape,
            orientation: orientation,
          );
          await showRoute(tester);
          if (how == 'back button') {
            await tapLoadingBack(tester);
          } else {
            await AppToast.navigatorKey.currentState!.maybePop();
          }
          await tester.pumpAndSettle();
          expect(find.text('list'), findsOneWidget);
          expect(orientation.calls, ['landscape', 'restore']);
          expect(opened, isEmpty);
        });
      }

      testWidgets('a retry asks for nothing again; back after it gives the '
          'orientation back', (tester) async {
        await pumpHost(tester);
        final orientation = _FakeOrientation();
        final answers = <Completer<BilibiliWatchPlan>>[];
        push(
          (_) {
            final answer = Completer<BilibiliWatchPlan>();
            answers.add(answer);
            return answer.future;
          },
          opened: <BilibiliWatchPlan>[],
          shape: phoneLandscape,
          orientation: orientation,
        );
        await showRoute(tester);
        answers.single.completeError(StateError('无法播放'));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('bilibili-watch-retry')), findsOne);
        await tester.tap(find.byKey(const ValueKey('bilibili-watch-retry')));
        await tester.pump();
        expect(answers, hasLength(2));
        expect(orientation.calls, ['landscape']);

        await tapLoadingBack(tester);
        await tester.pumpAndSettle();
        expect(orientation.calls, ['landscape', 'restore']);
      });

      testWidgets('the portrait page next, or a desktop: nothing is asked', (
        tester,
      ) async {
        for (final shape in const <BilibiliWatchPageShape>[
          BilibiliWatchPageShape(landscape: false, isMobilePlatform: true),
          BilibiliWatchPageShape(landscape: true, isDesktop: true),
        ]) {
          await pumpHost(tester);
          final orientation = _FakeOrientation();
          push(
            (_) => Completer<BilibiliWatchPlan>().future,
            opened: <BilibiliWatchPlan>[],
            shape: shape,
            orientation: orientation,
          );
          await showRoute(tester);
          await AppToast.navigatorKey.currentState!.maybePop();
          await tester.pumpAndSettle();
          expect(orientation.calls, isEmpty);
        }
      });
    });

    void expectNoLoadingNotice() {
      for (final text in _oldLoadingNotices) {
        expect(find.textContaining(text), findsNothing);
      }
    }

    testWidgets('shows cover, title and spinner at once, then the player '
        'takes its place', (tester) async {
      await pumpHost(tester);
      final ready = Completer<BilibiliWatchPlan>();
      final opened = <BilibiliWatchPlan>[];
      push((_) => ready.future, opened: opened);
      await showRoute(tester);

      expect(find.byKey(const ValueKey('bilibili-watch-loading')), findsOne);
      final cover = tester.widget<BilibiliSharpCoverImage>(
        find.byKey(const ValueKey('bilibili-watch-loading-cover')),
      );
      expect(cover.url, _cover);
      expect(find.text('测试视频'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bilibili-watch-loading-spinner')),
        findsOneWidget,
      );
      expectNoLoadingNotice();

      ready.complete(_plan('watch-1'));
      await tester.pumpAndSettle();
      expect(opened.single.item.id, 'watch-1');
      expect(find.text('player watch-1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bilibili-watch-loading')),
        findsNothing,
      );
      expectNoLoadingNotice();
    });

    testWidgets('after 30 seconds the reason and a retry button show', (
      tester,
    ) async {
      await pumpHost(tester);
      final attempts = <BilibiliWatchAttempt>[];
      final answers = <Completer<BilibiliWatchPlan>>[];
      final opened = <BilibiliWatchPlan>[];
      final discarded = <BilibiliWatchPlan>[];
      push(
        (attempt) {
          attempts.add(attempt);
          final answer = Completer<BilibiliWatchPlan>();
          answers.add(answer);
          return answer.future;
        },
        opened: opened,
        discarded: discarded,
      );
      await showRoute(tester);
      await tester.pump(const Duration(seconds: 29));
      expect(find.byKey(const ValueKey('bilibili-watch-failed')), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('bilibili-watch-failed')), findsOne);
      expect(find.textContaining('加载超时（30 秒）'), findsOneWidget);
      expect(find.byKey(const ValueKey('bilibili-watch-retry')), findsOne);
      expect(
        find.byKey(const ValueKey('bilibili-watch-loading-spinner')),
        findsNothing,
      );
      expect(attempts.single.isCancelled, isTrue);
      expectNoLoadingNotice();

      // The given-up try answers late: nothing opens, and what it made is
      // held until the retry shows what the open page keeps.
      answers.first.complete(_plan('late'));
      await tester.pump();
      expect(opened, isEmpty);
      expect(discarded, isEmpty);

      await tester.tap(find.byKey(const ValueKey('bilibili-watch-retry')));
      await tester.pump();
      expect(attempts, hasLength(2));
      expect(
        find.byKey(const ValueKey('bilibili-watch-loading-spinner')),
        findsOneWidget,
      );
      answers.last.complete(_plan('watch-2'));
      await tester.pumpAndSettle();
      expect(opened.single.item.id, 'watch-2');
      expect(discarded.single.item.id, 'late');
    });

    testWidgets(
      'back racing a ready plan cleans up without waiting for cover decoding',
      (tester) async {
        await pumpHost(tester);
        final answers = <Completer<BilibiliWatchPlan>>[];
        final opened = <BilibiliWatchPlan>[];
        final log = <String>[];
        push(
          (attempt) {
            final answer = Completer<BilibiliWatchPlan>();
            answers.add(answer);
            return answer.future;
          },
          opened: opened,
          discardLog: log,
        );
        await showRoute(tester);
        await tester.pump(kBilibiliWatchTimeLimit);
        await tester.tap(find.byKey(const ValueKey('bilibili-watch-retry')));
        await tester.pump();
        // Back wins the same event-loop turn as the ready answer. Cover decoding
        // is deliberately not a prerequisite for either opening or cleanup.
        answers.last.complete(_plan('watch-2'));
        await AppToast.navigatorKey.currentState!.maybePop();
        answers.first.complete(_plan('late'));
        await tester.pumpAndSettle();
        expect(opened, isEmpty);
        expect(find.text('list'), findsOneWidget);
        expect(log, unorderedEquals(['watch-2<-null', 'late<-null']));
      },
    );

    testWidgets('a failure shows its reason instead of spinning on', (
      tester,
    ) async {
      await pumpHost(tester);
      final opened = <BilibiliWatchPlan>[];
      push(
        (_) async => throw const BilibiliPublicApiException('视频不存在或已被删除'),
        opened: opened,
      );
      await showRoute(tester);
      expect(find.text('视频不存在或已被删除'), findsOneWidget);
      expect(find.byKey(const ValueKey('bilibili-watch-retry')), findsOne);
      await tapLoadingBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('list'), findsOneWidget);
    });

    testWidgets('back leaves at once and the late answer opens nothing', (
      tester,
    ) async {
      await pumpHost(tester);
      final answer = Completer<BilibiliWatchPlan>();
      late BilibiliWatchAttempt attempt;
      final opened = <BilibiliWatchPlan>[];
      final discarded = <BilibiliWatchPlan>[];
      push(
        (a) {
          attempt = a;
          return answer.future;
        },
        opened: opened,
        discarded: discarded,
      );
      await showRoute(tester);
      await tapLoadingBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('list'), findsOneWidget);
      expect(attempt.isCancelled, isTrue);

      answer.complete(_plan('late'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(discarded.single.item.id, 'late');
      expect(find.text('list'), findsOneWidget);
    });
  });

  group('tap on a video', () {
    late Directory root;
    late LibraryService library;
    late PathProviderPlatform originalPathProvider;
    late BilibiliDownloadService service;
    final navigation = PlaybackNavigationService.instance;
    final openedPlayers = <String>[];

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      BilibiliHistoryService.instance.resetForTest();
      root = await Directory.systemTemp.createTemp('bilibili_watch_tap_');
      originalPathProvider = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TempPathProvider(root.path);
      SettingsService().largeDataRootPath = root.path;
      library = LibraryService()..resetLibraryForTesting();
      await library.init();
      service = BilibiliDownloadService(apiService: _WatchApi());
      await service.init();
      openedPlayers.clear();
      PlaybackNavigationService.instance.resetNavigationQueueForTesting();
      PlaybackNavigationService.entryRouteOverrideForTesting = (item) {
        openedPlayers.add(item.id);
        return MaterialPageRoute<void>(
          settings: PlaybackNavigationService.landscapeRouteSettings(item),
          builder: (_) => Text('player ${item.id}'),
        );
      };
    });

    tearDown(() async {
      BilibiliWatchSources.overrideForTesting = null;
      PlaybackNavigationService.entryRouteOverrideForTesting = null;
      await service.shutdown();
      library.resetLibraryForTesting();
      SettingsService().resetForTest();
      SettingsService().largeDataRootPath = null;
      BilibiliHistoryService.instance.resetForTest();
      PathProviderPlatform.instance = originalPathProvider;
      await deleteTestTempDir(root);
    });

    var queue = PlaylistManager();

    /// The temporary Bilibili playlist as the app installs it.
    BilibiliWatchPlaylist installWatchList() {
      final list = BilibiliWatchPlaylist();
      BilibiliWatchPlaylistSession.install(
        BilibiliWatchPlaylistSession(
          list: list,
          service: service,
          library: library,
          queue: queue,
          playbackChanges: MediaPlaybackService(),
          currentItem: () => MediaPlaybackService().currentItem,
        ),
      );
      addTearDown(() => BilibiliWatchPlaylistSession.install(null));
      return list;
    }

    Future<void> pumpList(WidgetTester tester, {bool replace = false}) async {
      queue = PlaylistManager();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<BilibiliDownloadService>.value(
              value: service,
            ),
            ChangeNotifierProvider<LibraryService>.value(value: library),
            ChangeNotifierProvider<MediaPlaybackService>.value(
              value: MediaPlaybackService(),
            ),
            ChangeNotifierProvider<PlaylistManager>.value(value: queue),
          ],
          child: MaterialApp(
            navigatorKey: AppToast.navigatorKey,
            navigatorObservers: [navigation.observer],
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => unawaited(
                    watchBilibiliVideo(
                      context,
                      bvid: _bvid,
                      replaceCurrent: replace,
                      preview: const BilibiliWatchPreview(
                        title: '列表里的标题',
                        coverUrl: _cover,
                      ),
                    ),
                  ),
                  child: const Text('video'),
                ),
              ),
            ),
          ),
        ),
      );
    }

    /// Lets file work started under the test clock finish.
    Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(done(), isTrue);
    }

    testWidgets('back while the info loads: no page later, no card', (
      tester,
    ) async {
      final info = Completer<BilibiliVideoInfo>();
      final warmed = <String>[];
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (_) => info.future,
        warmPlayUrl: (bvid, cid) async => warmed.add('$bvid#$cid'),
      );
      await pumpList(tester);
      await tester.tap(find.text('video'));
      await showRoute(tester);

      // The page is there in the first frame, with what the list showed.
      expect(find.byKey(const ValueKey('bilibili-watch-loading')), findsOne);
      expect(find.text('列表里的标题'), findsOneWidget);
      expect(
        tester
            .widget<BilibiliSharpCoverImage>(
              find.byKey(const ValueKey('bilibili-watch-loading-cover')),
            )
            .url,
        _cover,
      );
      for (final text in _oldLoadingNotices) {
        expect(find.textContaining(text), findsNothing);
      }

      await tapLoadingBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('video'), findsOneWidget);

      info.complete(_info());
      await settleUntil(tester, () => true);
      await tester.pumpAndSettle();
      expect(openedPlayers, isEmpty);
      expect(navigation.hasPlaybackPage, isFalse);
      expect(library.transientVideos, isEmpty);
      expect(warmed, isEmpty);
    });

    testWidgets('back after the card was made: the card is removed', (
      tester,
    ) async {
      final warm = Completer<void>();
      var warmStarted = false;
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (_) async => _info(),
        warmPlayUrl: (_, _) {
          warmStarted = true;
          return warm.future;
        },
      );
      await pumpList(tester);
      await tester.tap(find.text('video'));
      await showRoute(tester);
      await settleUntil(
        tester,
        () => warmStarted && library.transientVideos.isNotEmpty,
      );
      final made = library.transientVideos.single.id;

      await tapLoadingBack(tester);
      await tester.pumpAndSettle();
      warm.complete();
      await settleUntil(tester, () => library.getVideo(made) == null);
      await tester.pumpAndSettle();

      expect(openedPlayers, isEmpty);
      expect(navigation.hasPlaybackPage, isFalse);
      expect(library.transientVideos, isEmpty);
      // A video that never opened is not in the watch history.
      expect(BilibiliHistoryService.instance.watchHistory, isEmpty);
    });

    /// Lets the loading page come in and the video get ready, until the
    /// playback page is about to take its place.
    Future<void> openPlayer(WidgetTester tester) async {
      for (var i = 0; i < 200 && openedPlayers.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(openedPlayers, isNotEmpty);
      await tester.pump();
    }

    /// Ends playback and lets the open-time measuring run out.
    Future<void> closeAll(WidgetTester tester) async {
      // The route observer outlives the test: leave it with no page here.
      AppToast.navigatorKey.currentState!.popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
      await MediaPlaybackService().stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 2));
    }

    testWidgets('the playback page takes the loading page\'s place without '
        'a transition', (tester) async {
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (_) async => _info(),
        warmPlayUrl: (_, _) async {},
      );
      await pumpList(tester);
      await tester.tap(find.text('video'));
      await showRoute(tester);
      await openPlayer(tester);

      final player = find.text('player ${openedPlayers.single}');
      expect(player, findsOneWidget);
      final route = ModalRoute.of(tester.element(player))!;
      expect(route.animation!.status, AnimationStatus.completed);
      expect(route.animation!.value, 1.0);
      expect(
        find.byKey(
          const ValueKey('bilibili-watch-loading'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(
        BilibiliHistoryService.instance.watchHistory.map((e) => e.bvid),
        <String>[_bvid],
      );
      await closeAll(tester);
    });

    testWidgets('from an open playback page: the new one takes the loading '
        'page\'s place without a transition, the old one goes', (tester) async {
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (_) async => _info(),
        warmPlayUrl: (_, _) async {},
      );
      await pumpList(tester, replace: true);
      final old = VideoItem(
        id: 'old-video',
        path: '/videos/old.mp4',
        title: 'old',
        durationMs: 0,
        lastUpdated: 0,
      );
      unawaited(
        AppToast.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            settings: PlaybackNavigationService.landscapeRouteSettings(old),
            builder: (_) => const Text('old player'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final context = tester.element(find.text('video', skipOffstage: false));
      unawaited(watchBilibiliVideo(context, bvid: _bvid, replaceCurrent: true));
      await showRoute(tester);
      await openPlayer(tester);

      final player = find.text('player ${openedPlayers.single}');
      expect(player, findsOneWidget);
      final route = ModalRoute.of(tester.element(player))!;
      expect(route.animation!.status, AnimationStatus.completed);
      expect(route.animation!.value, 1.0);
      expect(find.text('old player', skipOffstage: false), findsNothing);
      expect(
        navigation.observer.routes
            .where(
              (route) => PlaybackNavigationService.isPlaybackRouteName(
                route.settings.name,
              ),
            )
            .length,
        1,
      );
      expect(
        find.byKey(
          const ValueKey('bilibili-watch-loading'),
          skipOffstage: false,
        ),
        findsNothing,
      );
      await closeAll(tester);
    });

    testWidgets('a given-up load never joins the Bilibili playlist', (
      tester,
    ) async {
      final info = Completer<BilibiliVideoInfo>();
      final warm = Completer<void>();
      var infoAsked = 0;
      var warmStarted = false;
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (_) =>
            ++infoAsked == 1 ? info.future : Future.value(_info()),
        warmPlayUrl: (_, _) {
          warmStarted = true;
          return warm.future;
        },
      );
      await pumpList(tester);
      final list = installWatchList();

      // Back while the info loads.
      await tester.tap(find.text('video'));
      await showRoute(tester);
      await tapLoadingBack(tester);
      await tester.pumpAndSettle();
      info.complete(_info());
      await settleUntil(tester, () => true);

      // Back once the card was made, while the play address loads.
      await tester.tap(find.text('video'));
      await showRoute(tester);
      await settleUntil(
        tester,
        () => warmStarted && library.transientVideos.isNotEmpty,
      );
      await tapLoadingBack(tester);
      await tester.pumpAndSettle();
      warm.complete();
      await settleUntil(tester, () => library.transientVideos.isEmpty);

      expect(openedPlayers, isEmpty);
      expect(list.entries, isEmpty);
    });

    testWidgets('time limit, then retry: only the try that opens joins the '
        'Bilibili playlist, once', (tester) async {
      final firstWarm = Completer<void>();
      var warms = 0;
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (_) async => _info(),
        warmPlayUrl: (_, _) => ++warms == 1 ? firstWarm.future : Future.value(),
      );
      await pumpList(tester);
      final list = installWatchList();
      await tester.tap(find.text('video'));
      await showRoute(tester);
      await settleUntil(tester, () => warms == 1);
      await tester.pump(kBilibiliWatchTimeLimit);
      expect(find.byKey(const ValueKey('bilibili-watch-retry')), findsOne);
      expect(list.entries, isEmpty);

      await tester.tap(find.byKey(const ValueKey('bilibili-watch-retry')));
      await openPlayer(tester);
      firstWarm.complete();
      await settleUntil(tester, () => true);

      expect(openedPlayers, hasLength(1));
      expect(list.entries.map((e) => e.bvid), <String>[_bvid]);
      expect(library.transientVideos, hasLength(1));
      await closeAll(tester);
    });

    testWidgets('a video opened from the playback page\'s Bilibili panel '
        '(collection, description link) joins the list too', (tester) async {
      const other = 'BV1yy411c7mE';
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (bvid) async => _info(bvid: bvid),
        warmPlayUrl: (_, _) async {},
      );
      await pumpList(tester);
      final list = installWatchList();
      await tester.tap(find.text('video'));
      await openPlayer(tester);
      expect(list.entries.map((e) => e.bvid), <String>[_bvid]);

      // What the panel's links do: play in place of the open page.
      final context = tester.element(find.text('video', skipOffstage: false));
      openedPlayers.clear();
      unawaited(watchBilibiliVideo(context, bvid: other, replaceCurrent: true));
      await openPlayer(tester);
      expect(list.entries.map((e) => e.bvid), <String>[_bvid, other]);
      expect(list.currentBvid, other);
      await settleUntil(tester, () => queue.playlist.length == 2);
      expect(queue.playlist.map((item) => item.sourceRef?.bvid), <String>[
        _bvid,
        other,
      ]);
      await closeAll(tester);
    });

    testWidgets('a second tap while one loads opens no second page', (
      tester,
    ) async {
      final info = Completer<BilibiliVideoInfo>();
      BilibiliWatchSources.overrideForTesting = BilibiliWatchSources(
        fetchInfo: (_) => info.future,
        warmPlayUrl: (_, _) async {},
      );
      await pumpList(tester);
      await tester.tap(find.text('video'));
      await showRoute(tester);
      final context = tester.element(find.text('video', skipOffstage: false));
      unawaited(
        watchBilibiliVideo(context, bvid: _bvid, replaceCurrent: false),
      );
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey('bilibili-watch-loading'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      await tapLoadingBack(tester);
      await tester.pumpAndSettle();
      info.complete(_info());
      await settleUntil(tester, () => true);
    });
  });
}

/// A pushed route is laid out offstage in its first frame and shows in the
/// next one.
Future<void> showRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> tapLoadingBack(WidgetTester tester) async {
  final overlay = find.byType(VideoControlsOverlay);
  if (overlay.evaluate().isNotEmpty &&
      !tester.state<VideoControlsOverlayState>(overlay).controlsVisible) {
    await tester.tapAt(tester.getCenter(overlay));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 250));
  }
  await tester.tap(find.byKey(const ValueKey('bilibili-watch-loading-back')));
}

BilibiliWatchPlan _plan(String id) => BilibiliWatchPlan(
  item: VideoItem(
    id: id,
    path: 'bilibili://stream/$_bvid?cid=101',
    title: id,
    durationMs: 0,
    lastUpdated: 0,
  ),
  videoInfo: _info(),
  imported: false,
);

BilibiliVideoInfo _info({String bvid = _bvid}) => BilibiliVideoInfo(
  title: '测试视频',
  desc: '',
  pic: _cover,
  bvid: bvid,
  aid: '123',
  ownerName: 'UP',
  ownerMid: '1',
  pubDate: 0,
  pages: <BilibiliPage>[
    BilibiliPage(
      cid: 101,
      page: 1,
      part: '第 1 部分',
      duration: 600,
      bvid: bvid,
      aid: '123',
    ),
  ],
);

BilibiliVideoDetail _detail() => const BilibiliVideoDetail(
  bvid: _bvid,
  aid: 123,
  title: '测试视频',
  coverUrl: _cover,
  parts: <BilibiliVideoPart>[
    BilibiliVideoPart(cid: 101, page: 1, title: '第 1 部分'),
  ],
);

class _WatchApi extends BilibiliApiService {
  _WatchApi({super.httpClientAdapter});

  int metadataRequests = 0;
  int danmakuRequests = 0;
  int videoShotRequests = 0;

  @override
  Future<void> init() async {}

  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async =>
      _info();

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async {
    metadataRequests++;
    return const BilibiliPlayerMetadata();
  }

  @override
  Future<String> fetchDanmakuXml(int cid) async {
    danmakuRequests++;
    return '<i></i>';
  }

  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async {
    videoShotRequests++;
    return null;
  }
}

class _PlayUrlApi extends BilibiliApiService {
  _PlayUrlApi({required this.deadline});

  final DateTime deadline;
  int playUrlCalls = 0;

  @override
  Future<BilibiliStreamInfo> fetchPlayUrl(String bvid, int cid) async {
    playUrlCalls++;
    final expires = deadline.millisecondsSinceEpoch ~/ 1000;
    String url(String name) =>
        'https://upos-test.bilivideo.com/$name.m4s?deadline=$expires';
    return BilibiliStreamInfo(
      durationMs: 120000,
      qualityMap: const {80: '1080P 高清'},
      videoStreams: [
        StreamItem(
          id: 80,
          baseUrl: url('video-$cid'),
          bandwidth: 800000,
          codecs: 'avc1.640028',
          codecid: 7,
          mimeType: 'video/mp4',
          qualityName: '1080P 高清',
          width: 1920,
          height: 1080,
          frameRate: '30',
          initializationRange: '0-999',
          indexRange: '1000-1999',
        ),
      ],
      audioStreams: [
        StreamItem(
          id: 30280,
          baseUrl: url('audio-$cid'),
          bandwidth: 128000,
          codecs: 'mp4a.40.2',
          codecid: 0,
          mimeType: 'audio/mp4',
          initializationRange: '0-899',
          indexRange: '900-1799',
        ),
      ],
    );
  }
}

typedef _Handler = ResponseBody Function(RequestOptions options);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final _Handler handler;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    // Lets requests asked at the same time overlap.
    await Future<void>.delayed(const Duration(milliseconds: 1));
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);

ResponseBody _navJson() => _json({
  'code': -101,
  'data': {
    'wbi_img': {
      'img_url': 'https://i0.hdslb.com/bfs/wbi/${'a' * 32}.png',
      'sub_url': 'https://i0.hdslb.com/bfs/wbi/${'b' * 32}.png',
    },
  },
});

Map<String, Object> _playUrlPayload() => {
  'code': 0,
  'data': {
    'accept_quality': [80],
    'accept_description': ['1080P 高清'],
    'dash': {
      'duration': 120,
      'video': [
        {
          'id': 80,
          'base_url': 'https://upos-test.bilivideo.com/video.m4s',
          'bandwidth': 800000,
          'codecs': 'avc1.640028',
          'codecid': 7,
          'mime_type': 'video/mp4',
          'width': 1920,
          'height': 1080,
        },
      ],
      'audio': [
        {
          'id': 30280,
          'base_url': 'https://upos-test.bilivideo.com/audio.m4s',
          'bandwidth': 128000,
          'codecs': 'mp4a.40.2',
          'codecid': 0,
          'mime_type': 'audio/mp4',
        },
      ],
    },
  },
};

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

/// Records what the loading page asks of the screen orientation.
class _FakeOrientation implements BilibiliWatchOrientation {
  final List<String> calls = <String>[];

  @override
  Future<void> requestLandscape() async => calls.add('landscape');

  @override
  Future<void> restore() async => calls.add('restore');
}

/// Asks nothing (the tests above run as a desktop anyway).
class _NoOrientation implements BilibiliWatchOrientation {
  const _NoOrientation();

  @override
  Future<void> requestLandscape() async {}

  @override
  Future<void> restore() async {}
}
