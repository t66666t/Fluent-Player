import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_models.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/models/import_card_placement.dart';
import 'package:video_player_app/models/media_source_ref.dart';
import 'package:video_player_app/models/video_item.dart';
import 'package:video_player_app/services/bilibili/bilibili_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_collection_import.dart';
import 'package:video_player_app/services/bilibili/bilibili_download_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_part_playback.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_uploader_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_cards.dart';
import 'package:video_player_app/services/bilibili/bilibili_watch_playlist.dart';
import 'package:video_player_app/services/library_service.dart';
import 'package:video_player_app/services/playlist_manager.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_collection_import_button.dart';

import 'test_dir_cleanup.dart';

const _bvid = 'BV1LpD3YsETa';
const _bvid2 = 'BV1xx411c7mD';
const _bvid3 = 'BV1bb411c7mB';
const _source = BilibiliCollectionImportSource(
  mid: 7,
  collection: BilibiliUploaderCollection(
    id: 9,
    isSeason: true,
    title: '完整合集',
    videoCount: 3,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late LibraryService library;
  late BilibiliDownloadService service;
  late _Api api;
  late _Uploader uploader;
  late BilibiliVideoInfo info;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    SettingsService().importCardPlacement =
        ImportCardPlacement.libraryRoot.storageValue;
    BilibiliHistoryService.instance.resetForTest();
    root = await Directory.systemTemp.createTemp('bilibili_collection_parts_');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SettingsService().largeDataRootPath = root.path;
    library = LibraryService()..resetLibraryForTesting();
    await library.init();
    // The supplied reference video's real response has two parts, including
    // a deliberately long P2 title. It stays a fixture for offline regression.
    final json =
        jsonDecode(
              File(
                'test/fixtures/bilibili_multipart_reference.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    info = BilibiliVideoInfo.fromJson(json);
    api = _Api({_bvid: info, _bvid2: _single(_bvid2), _bvid3: _single(_bvid3)});
    service = BilibiliDownloadService(
      apiService: api,
      publicApi: _PublicApi(api),
    );
    uploader = _Uploader();
  });

  tearDown(() async {
    await service.waitForPendingStreamCardData();
    await service.shutdown();
    library.resetLibraryForTesting();
    SettingsService().resetForTest();
    SettingsService().largeDataRootPath = null;
    BilibiliHistoryService.instance.resetForTest();
    PathProviderPlatform.instance = originalPaths;
    await deleteTestTempDir(root);
  });

  test(
    'collection import loads every page and persists video/part folders',
    () async {
      final count = await importBilibiliCollection(
        service: service,
        library: library,
        uploader: uploader,
        source: _source,
      );
      expect(count, 4);
      expect(uploader.pages, [1, 2]);
      expect(api.requested, [_bvid, _bvid2, _bvid3]);
      expect(library.bilibiliStreamItems, hasLength(4));
      final collection = library.collections.single;
      expect(collection.name, '完整合集');
      final parts = library.bilibiliStreamItems
          .where((item) => item.sourceRef?.bvid == _bvid)
          .toList();
      expect(parts.map((item) => item.sourceRef?.page), [1, 2]);
      final folder = library.getCollection(parts.first.parentId!)!;
      expect(folder.name, info.title);
      expect(folder.parentId, collection.id);
      expect(
        parts.every((part) => !part.isTransient && part.parentId == folder.id),
        isTrue,
      );
      await service.waitForPendingStreamCardData();
      final ids = library.bilibiliStreamItems.map((item) => item.id).toSet();
      library.resetLibraryForTesting();
      await library.init();
      expect(library.bilibiliStreamItems.map((item) => item.id).toSet(), ids);
      expect(library.getCollection(folder.id)?.parentId, collection.id);
    },
  );

  test(
    'series use their own complete member list, including multipart videos',
    () async {
      const series = BilibiliCollectionImportSource(
        mid: 7,
        collection: BilibiliUploaderCollection(
          id: 10,
          isSeason: false,
          title: '系列',
        ),
      );
      final task = await prepareBilibiliCollectionImport(
        service: service,
        uploader: uploader,
        source: series,
      );
      expect(uploader.seasons, [false, false]);
      expect(task.videos.map((video) => video.videoInfo.bvid), [
        _bvid,
        _bvid2,
        _bvid3,
      ]);
      expect(task.videos.first.episodes.map((ep) => ep.page.cid), [
        26635208162,
        27351058982,
      ]);
    },
  );

  test('detail collection import keeps the collection own cover', () async {
    final detail = BilibiliVideoDetail.tryParse({
      'bvid': _bvid,
      'pic': 'https://i0.hdslb.com/bfs/archive/video.jpg',
      'owner': {'mid': 7},
      'ugc_season': {
        'id': 9,
        'title': '合集封面',
        'cover': '//i0.hdslb.com/bfs/archive/collection.jpg',
      },
    })!;
    expect(
      detail.season?.coverUrl,
      'https://i0.hdslb.com/bfs/archive/collection.jpg',
    );
    final task = await prepareBilibiliCollectionImport(
      service: service,
      uploader: uploader,
      source: BilibiliCollectionImportSource.fromDetail(detail),
    );
    expect(task.collectionInfo!.cover, detail.season!.coverUrl);
    expect(task.collectionInfo!.cover, isNot(detail.coverUrl));
  });

  test(
    'missing collection covers fall back to an available member cover',
    () async {
      api.infos[_bvid2] = _single(
        _bvid2,
        pic: 'http://i0.hdslb.com/bfs/archive/member.jpg',
      );
      final task = await prepareBilibiliCollectionImport(
        service: service,
        uploader: uploader,
        source: _source,
      );
      expect(
        task.collectionInfo!.cover,
        'https://i0.hdslb.com/bfs/archive/member.jpg',
      );
    },
  );

  test(
    'an explicit import folder contains the whole collection tree',
    () async {
      final destination = await library.createCollection('我的课程', null);
      final placement = ImportPlacementRequest.explicit(
        ImportCardFeature.bilibiliPage,
        destination.id,
      );
      final count = await importBilibiliCollection(
        service: service,
        library: library,
        uploader: uploader,
        source: _source,
        placement: placement,
      );
      expect(count, 4);
      final collection = library.getContents(destination.id).single;
      expect(collection.name, _source.collection.title);
      expect(collection.parentId, destination.id);
      expect(library.getContents(null).map((item) => item.id), [
        destination.id,
      ]);
      final multipart = library.bilibiliStreamItems
          .where((item) => item.sourceRef?.bvid == _bvid)
          .toList();
      expect(
        library.getCollection(multipart.first.parentId!)!.parentId,
        collection.id,
      );
    },
  );

  test(
    'a failed or truncated second page never imports a partial collection',
    () async {
      uploader.failSecond = true;
      await expectLater(
        importBilibiliCollection(
          service: service,
          library: library,
          uploader: uploader,
          source: _source,
        ),
        throwsA(isA<BilibiliCollectionImportException>()),
      );
      expect(library.bilibiliStreamItems, isEmpty);
      expect(library.collections, isEmpty);
      expect(service.tasks, isEmpty);
      uploader.failSecond = false;
      uploader.truncateSecond = true;
      await expectLater(
        prepareBilibiliCollectionImport(
          service: service,
          uploader: uploader,
          source: _source,
        ),
        throwsA(isA<BilibiliCollectionImportException>()),
      );
      expect(library.bilibiliStreamItems, isEmpty);
    },
  );

  test(
    'whole-collection import continues beyond the browsing page limit',
    () async {
      uploader.longCollection = true;
      final ids = await loadBilibiliCollectionBvids(
        source: _source,
        uploader: uploader,
      );
      expect(ids, hasLength(55));
      expect(ids.toSet(), hasLength(55));
      expect(uploader.pages.last, 55);
    },
  );

  test('unavailable video info leaves the library untouched', () async {
    api.infos.remove(_bvid2);
    await expectLater(
      importBilibiliCollection(
        service: service,
        library: library,
        uploader: uploader,
        source: _source,
      ),
      throwsStateError,
    );
    expect(library.bilibiliStreamItems, isEmpty);
    expect(service.tasks, isEmpty);
  });

  test(
    'collection import falls back to public details when the direct API is rejected',
    () async {
      api.rejectInfoRequests = true;
      final task = await prepareBilibiliCollectionImport(
        service: service,
        uploader: uploader,
        source: _source,
      );
      expect(task.videos, hasLength(3));
      expect(task.videos.first.episodes.map((ep) => ep.page.cid), [
        26635208162,
        27351058982,
      ]);
    },
  );

  test(
    'selecting an unimported part never imports, even with auto import enabled',
    () async {
      SettingsService().bilibiliAutoImportOnPlay = true;
      final original = _card('original', page: 1)..lastPositionMs = 45000;
      await library.addSingleVideo(original, reuseExistingItem: false);
      final before = _card('before', bvid: _bvid2);
      final after = _card('after', bvid: _bvid3);
      final queue = [before, original, after];
      final plan = await prepareBilibiliPartSwitch(
        service: service,
        library: library,
        info: info,
        page: 2,
        existingQueue: queue,
      );
      expect(plan.item.isTransient, isTrue);
      expect(plan.item.sourceRef?.cid, 27351058982);
      expect(plan.item.lastPositionMs, 0);
      expect(plan.imported, isFalse);
      expect(library.bilibiliStreamItems, [original]);
      expect(library.collections, isEmpty);
      expect(plan.queue!.map((item) => item.sourceRef?.page), [1, 2]);
      expect(plan.queue!.first, same(original));
      final projected = projectBilibiliPartsQueue(
        queue: queue,
        bvid: _bvid,
        parts: plan.queue!,
      );
      expect(projected, [before, original, plan.item, after]);

      plan.item.lastPositionMs = 12000;
      final back = await prepareBilibiliPartSwitch(
        service: service,
        library: library,
        info: info,
        page: 1,
        existingQueue: projected,
      );
      expect(back.item, same(original));
      expect(back.item.lastPositionMs, 45000);
      final again = await prepareBilibiliPartSwitch(
        service: service,
        library: library,
        info: info,
        page: 2,
        existingQueue: projected,
      );
      expect(again.item, same(plan.item));
      expect(again.item.lastPositionMs, 12000);
      expect(library.transientVideos, hasLength(1));
    },
  );

  test(
    'part switching preserves the playing copy when the BV was imported twice',
    () async {
      final otherCopy = _card('other-copy')..lastPositionMs = 1000;
      final playingCopy = _card('playing-copy')..lastPositionMs = 45000;
      await library.addSingleVideo(otherCopy, reuseExistingItem: false);
      await library.addSingleVideo(playingCopy, reuseExistingItem: false);
      final plan = await prepareBilibiliPartSwitch(
        service: service,
        library: library,
        info: info,
        page: 2,
        existingQueue: [otherCopy, playingCopy],
        currentItem: playingCopy,
      );
      expect(plan.queue!.first, same(playingCopy));
      expect(plan.queue!.first.lastPositionMs, 45000);
      expect(library.bilibiliStreamItems, hasLength(2));
    },
  );

  test(
    'cancelled part preparation removes only the new temporary entries',
    () async {
      final original = _card('original');
      await library.addSingleVideo(original, reuseExistingItem: false);
      var checks = 0;
      await expectLater(
        prepareBilibiliPartSwitch(
          service: service,
          library: library,
          info: info,
          page: 2,
          existingQueue: [original],
          isCancelled: () => ++checks > 1,
        ),
        throwsA(isA<BilibiliWatchCancelledException>()),
      );
      expect(library.transientVideos, isEmpty);
      expect(library.bilibiliStreamItems, [original]);
    },
  );

  test(
    'active Bilibili session retains cursor, other videos and part order',
    () async {
      final queue = PlaylistManager()..initialize(libraryService: library);
      final playing = ValueNotifier<VideoItem?>(null);
      final list = BilibiliWatchPlaylist();
      final session = BilibiliWatchPlaylistSession(
        list: list,
        service: service,
        library: library,
        queue: queue,
        playbackChanges: playing,
        currentItem: () => playing.value,
      );
      addTearDown(session.dispose);
      addTearDown(playing.dispose);
      final original = _card('original');
      await library.addSingleVideo(original, reuseExistingItem: false);
      session.opened(
        BilibiliWatchPlan(item: original, videoInfo: info, imported: false),
      );
      playing.value = original;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final plan = await prepareBilibiliPartSwitch(
        service: service,
        library: library,
        info: info,
        page: 2,
        existingQueue: queue.playlist,
      );
      final projected = projectBilibiliPartsQueue(
        queue: queue.playlist,
        bvid: _bvid,
        parts: plan.queue!,
      );
      expect(session.preparePartSwitch(projected, original.id), isTrue);
      expect(
        queue.currentItem,
        same(original),
        reason: 'preparation does not mark an unplayed part as current',
      );
      expect(session.isActive, isTrue);
      queue.anchorCurrentItem(plan.item);
      playing.value = plan.item;
      expect(list.entries, hasLength(1));
      expect(list.entryOf(_bvid)?.page, 2);
      expect(queue.currentIndex, 1);
      expect(queue.getPrevious(), same(original));
      expect(queue.getNext(), isNull);
    },
  );

  testWidgets(
    'collection action keeps its size through busy, error and retry',
    (tester) async {
      final pending = Completer<int>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                const Expanded(child: Text('一个较长的合集标题')),
                BilibiliCollectionImportButton(
                  source: _source,
                  uploader: uploader,
                  onImport: (_, _, {placement}) {
                    calls++;
                    return pending.future;
                  },
                ),
              ],
            ),
          ),
        ),
      );
      final button = find.byType(BilibiliCollectionImportButton);
      final rect = tester.getRect(button);
      await tester.tap(find.text('导入'));
      await tester.pump();
      expect(find.text('导入中'), findsOneWidget);
      expect(tester.getRect(button), rect);
      await tester.tap(find.text('导入中'));
      expect(calls, 1);
      pending.completeError(const BilibiliCollectionImportException('网络中断'));
      await tester.pumpAndSettle();
      expect(find.text('重试'), findsOneWidget);
      expect(tester.getRect(button), rect);
      expect(find.text('网络中断'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'right-hand folder action picks a target and cancellation imports nothing',
    (tester) async {
      final folder = (await tester.runAsync(
        () => library.createCollection('导入到这个位置', null),
      ))!;
      var calls = 0;
      ImportPlacementRequest? captured;
      await tester.pumpWidget(
        ChangeNotifierProvider<LibraryService>.value(
          value: library,
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: BilibiliCollectionImportButton(
                  source: _source,
                  uploader: uploader,
                  onImport: (_, _, {placement}) async {
                    calls++;
                    captured = placement;
                    return 4;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final action = find.byType(BilibiliCollectionImportButton);
      final rect = tester.getRect(action);
      final main = tester.getRect(
        find.byKey(ValueKey('bilibili-collection-import-${_source.key}')),
      );
      final secondary = find.byTooltip('选择导入位置');
      expect(tester.getRect(secondary).left, greaterThan(main.right));
      await tester.tap(secondary);
      await tester.pumpAndSettle();
      expect(find.text('导入合集到…'), findsOneWidget);
      expect(find.text('导入中'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(tester.getRect(action), rect);
      await tester.tap(secondary);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('folder-picker-folder-${folder.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('folder-picker-confirm')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(captured?.feature, ImportCardFeature.bilibiliPage);
      expect(captured?.folderId, folder.id);
      expect(captured?.isResolved, isTrue);
      expect(find.text('已导入'), findsOneWidget);
      expect(tester.getRect(action), rect);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

VideoItem _card(String id, {String bvid = _bvid, int page = 1}) => VideoItem(
  id: id,
  path: 'bilibili://stream/$bvid?cid=${page == 1 ? 26635208162 : 27351058982}',
  title: '$bvid P$page',
  durationMs: 106000,
  lastUpdated: 1,
  isBilibiliExported: true,
  sourceRef: MediaSourceRef(
    value: bvid,
    kind: MediaSourceKind.bilibiliStream,
    bvid: bvid,
    page: page,
    cid: page == 1 ? 26635208162 : 27351058982,
  ),
);

BilibiliVideoInfo _single(String bvid, {String pic = ''}) => BilibiliVideoInfo(
  title: bvid,
  desc: '',
  pic: pic,
  bvid: bvid,
  aid: '1',
  ownerName: 'UP',
  ownerMid: '7',
  pubDate: 0,
  pages: [BilibiliPage(cid: 100, page: 1, part: bvid, duration: 60)],
);

class _Api extends BilibiliApiService {
  _Api(this.infos);
  final Map<String, BilibiliVideoInfo> infos;
  final List<String> requested = [];
  bool rejectInfoRequests = false;
  @override
  Future<void> init() async {}
  @override
  Future<bool> hasCookie() async => false;
  @override
  Future<BilibiliVideoInfo> fetchVideoInfo(String bvid, {String? aid}) async {
    requested.add(bvid);
    if (rejectInfoRequests) throw StateError('direct endpoint rejected');
    return infos[bvid] ?? (throw StateError('video unavailable'));
  }

  @override
  Future<BilibiliPlayerMetadata> fetchPlayerMetadata(
    String bvid,
    int cid, {
    String? aid,
    bool skipAiSubtitles = false,
    int durationSeconds = 0,
  }) async => const BilibiliPlayerMetadata();
  @override
  Future<String> fetchDanmakuXml(int cid) async => '<i></i>';
  @override
  Future<Map<String, dynamic>?> fetchVideoShot(String bvid, int cid) async =>
      null;
}

class _Uploader extends BilibiliUploaderService {
  final List<int> pages = [];
  final List<bool> seasons = [];
  bool failSecond = false;
  bool truncateSecond = false;
  bool longCollection = false;
  @override
  Future<BilibiliUploaderResult<BilibiliUploaderPage<BilibiliUploaderVideo>>>
  fetchCollectionVideos(
    int mid,
    BilibiliUploaderCollection collection, {
    int page = 1,
    bool limitToBrowsePages = true,
  }) async {
    pages.add(page);
    seasons.add(collection.isSeason);
    if (longCollection) {
      expect(limitToBrowsePages, isFalse);
      final bvid = 'BV${page.toString().padLeft(10, '0')}';
      return BilibiliUploaderResult.success(
        BilibiliUploaderPage(
          items: [BilibiliUploaderVideo(bvid: bvid, title: bvid)],
          page: page,
          pageSize: 1,
          total: 55,
        ),
      );
    }
    if (page == 2 && failSecond) {
      return const BilibiliUploaderResult.failure(
        BilibiliUploaderStatus.networkError,
        '网络中断',
      );
    }
    final ids = page == 1
        ? [_bvid, _bvid2]
        : truncateSecond
        ? <String>[]
        : [_bvid3];
    return BilibiliUploaderResult.success(
      BilibiliUploaderPage(
        items: [
          for (final id in ids) BilibiliUploaderVideo(bvid: id, title: id),
        ],
        page: page,
        pageSize: 2,
        total: 3,
      ),
    );
  }
}

class _PublicApi extends BilibiliPublicApiService {
  _PublicApi(this.api);
  final _Api api;
  @override
  Future<BilibiliVideoDetail> fetchVideoDetail({String? bvid, int? aid}) async {
    final info = api.infos[bvid] ?? (throw StateError('video unavailable'));
    return BilibiliVideoDetail(
      bvid: info.bvid,
      title: info.title,
      parts: [
        for (final p in info.pages)
          BilibiliVideoPart(cid: p.cid, page: p.page, title: p.part),
      ],
    );
  }
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
