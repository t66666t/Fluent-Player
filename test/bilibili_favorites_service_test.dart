import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_favorites_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_selection.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_favorites_service.dart';

import 'support/bilibili_favorites_support.dart';

void main() {
  late FavoriteTestAdapter adapter;
  late BilibiliFavoritesService service;
  setUp(() {
    adapter = FavoriteTestAdapter();
    service = BilibiliFavoritesService(api: favoriteTestApi(adapter));
  });

  test(
    'reads private folders with the shared session and browser headers using GET',
    () async {
      adapter.routes[favoriteFoldersPath] = (_) => favoriteJson(
        favoriteFoldersAnswer(folders: [favoriteFolderJson(attr: 257)]),
      );
      final result = await service.fetchFolders(7);
      expect(result.isSuccess, isTrue);
      final folder = result.data!.items.single;
      expect(folder.isPublic, isFalse);
      expect(
        folder.coverUrl,
        'https://i0.hdslb.com/bfs/archive/folder.jpg@320w_200h_1c.webp',
      );
      final request = adapter.to(favoriteFoldersPath).single;
      expect(request.queryParameters, {'up_mid': 7, 'pn': 1, 'ps': 20});
      expect(
        request.headers['Cookie'],
        allOf(contains('SESSDATA=test-session'), contains('buvid3=DEVICE')),
      );
      expect(request.headers['Cookie'], isNot(contains('bili_jct')));
      expect(
        request.headers['Referer'],
        'https://space.bilibili.com/7/favlist',
      );
      expect(request.headers['Origin'], 'https://space.bilibili.com');
      expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
    },
  );

  test(
    'video rows preserve unavailable and non-video entries and normalize thumbnails',
    () async {
      adapter.routes[favoriteVideosPath] = (_) => favoriteJson(
        favoriteVideosAnswer(
          videos: [
            favoriteVideoJson(),
            favoriteVideoJson(id: 92, attr: 9),
            favoriteVideoJson(id: 93, type: 12),
            {
              ...favoriteVideoJson(id: 94),
              'bvid': null,
              'bv_id': favoriteTestBvid,
            },
          ],
        ),
      );
      final result = await service.fetchVideos(7, 41, page: 2);
      expect(result.isSuccess, isTrue);
      final rows = result.data!.items;
      expect(rows, hasLength(4));
      expect(rows.map((v) => v.canPlay), [true, false, false, true]);
      expect(
        rows.first.coverUrl,
        'https://i0.hdslb.com/bfs/archive/video.jpg@320w_200h_1c.webp',
      );
      expect(rows.first.durationSeconds, 125);
      expect(rows.first.ownerName, '视频作者');
      expect(result.data!.hasMoreHint, isFalse);
      expect(adapter.to(favoriteVideosPath).single.queryParameters['pn'], 2);
      expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
    },
  );

  test('honors explicit pagination and clamps the requested page', () async {
    adapter.routes[favoriteFoldersPath] = (_) =>
        favoriteJson(favoriteFoldersAnswer(count: 80, more: true));
    final first = await service.fetchFolders(7, page: -1);
    expect(first.data!.hasMoreHint, isTrue);
    await service.fetchFolders(7, page: 9999);
    expect(
      adapter.to(favoriteFoldersPath).map((r) => r.queryParameters['pn']),
      [1, 50],
    );
  });

  test('accepts truly empty folders and lists', () async {
    adapter.routes[favoriteFoldersPath] = (_) =>
        favoriteJson(favoriteFoldersAnswer(folders: [], count: 0));
    adapter.routes[favoriteVideosPath] = (_) => favoriteJson({
      'code': 0,
      'data': {
        'info': favoriteFolderJson(count: 0),
        'medias': null,
        'has_more': false,
      },
    });
    expect((await service.fetchFolders(7)).data!.items, isEmpty);
    expect((await service.fetchVideos(7, 41)).data!.items, isEmpty);
  });

  for (final payload in [
    {'code': -101},
    {'code': -403},
    {'code': 11203},
    {'code': 0, 'data': null},
    {
      'code': 0,
      'data': {'count': 5, 'list': null},
    },
    {
      'code': 0,
      'data': {
        'count': 1,
        'list': [favoriteFolderJson(mid: 8)],
      },
    },
  ]) {
    test(
      'does not turn an unavailable folder response into an empty success: $payload',
      () async {
        adapter.routes[favoriteFoldersPath] = (_) => favoriteJson(payload);
        expect((await service.fetchFolders(7)).isSuccess, isFalse);
      },
    );
  }

  test(
    'rejects another account or a different folder in video responses',
    () async {
      for (final folder in [
        favoriteFolderJson(mid: 8),
        favoriteFolderJson(id: 99),
      ]) {
        adapter.routes[favoriteVideosPath] = (_) =>
            favoriteJson(favoriteVideosAnswer(folder: folder));
        expect((await service.fetchVideos(7, 41)).isSuccess, isFalse);
      }
    },
  );

  test('retries risk control once through the existing renewal path', () async {
    var attempts = 0;
    adapter.routes[favoriteFoldersPath] = (_) => favoriteJson(
      ++attempts == 1 ? {'code': -352} : favoriteFoldersAnswer(),
    );
    expect((await service.fetchFolders(7)).isSuccess, isTrue);
    expect(attempts, 2);
    expect(adapter.to('/x/web-interface/nav'), hasLength(1));
    expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
  });

  test('does not keep retrying blocked requests', () async {
    adapter.routes[favoriteFoldersPath] = (_) => favoriteJson({'code': -352});
    final result = await service.fetchFolders(7);
    expect(result.status, BilibiliUploaderStatus.riskControlled);
    expect(adapter.to(favoriteFoldersPath), hasLength(2));
  });

  test('network failures become a retryable result', () async {
    adapter.routes[favoriteFoldersPath] = (request) => throw DioException(
      requestOptions: request,
      type: DioExceptionType.connectionTimeout,
    );
    expect(
      (await service.fetchFolders(7)).status,
      BilibiliUploaderStatus.networkError,
    );
    expect(adapter.to(favoriteFoldersPath), hasLength(1));
  });

  test('invalid inputs never start a request', () async {
    expect((await service.fetchFolders(0)).isSuccess, isFalse);
    expect((await service.fetchVideos(7, 0)).isSuccess, isFalse);
    expect(adapter.requests, isEmpty);
  });

  group('full folder reads and selection', () {
    test('reads past page fifty without altering the browsing cap', () async {
      adapter.routes[favoriteVideosPath] = (request) {
        final page = request.queryParameters['pn'] as int;
        return favoriteJson(
          favoriteVideosAnswer(
            folder: favoriteFolderJson(count: 55),
            videos: [
              favoriteVideoJson(
                id: page,
                bvid: 'BV${page.toString().padLeft(10, '0')}',
              ),
            ],
            more: page < 55,
          ),
        );
      };
      final progress = <int>[];
      final contents = await service.fetchAllVideos(
        7,
        41,
        onProgress: (loaded, total) {
          progress.add(loaded);
          expect(total, 55);
        },
      );
      expect(contents.playable, hasLength(55));
      expect(progress.last, 55);
      expect(
        adapter.to(favoriteVideosPath).map((r) => r.queryParameters['pn']),
        List.generate(55, (i) => i + 1),
      );
      await service.fetchVideos(7, 41, page: 999);
      expect(adapter.to(favoriteVideosPath).last.queryParameters['pn'], 50);
    });

    test('rejects repeated pages and truncated final pages', () async {
      adapter.routes[favoriteVideosPath] = (_) => favoriteJson(
        favoriteVideosAnswer(
          folder: favoriteFolderJson(count: 4),
          videos: [favoriteVideoJson()],
          more: true,
        ),
      );
      await expectLater(
        service.fetchAllVideos(7, 41),
        throwsA(isA<BilibiliFavoritesException>()),
      );
      expect(adapter.to(favoriteVideosPath), hasLength(2));
      adapter.routes[favoriteVideosPath] = (_) => favoriteJson(
        favoriteVideosAnswer(
          folder: favoriteFolderJson(count: 4),
          videos: [favoriteVideoJson()],
          more: false,
        ),
      );
      await expectLater(
        service.fetchAllVideos(7, 41),
        throwsA(isA<BilibiliFavoritesException>()),
      );
    });

    test(
      'all selection covers remaining pages and excludes unavailable rows',
      () async {
        adapter.routes[favoriteVideosPath] = (request) {
          final page = request.queryParameters['pn'] as int;
          return favoriteJson(
            favoriteVideosAnswer(
              folder: favoriteFolderJson(count: 4),
              videos: page == 1
                  ? [favoriteVideoJson(), favoriteVideoJson(id: 92, attr: 9)]
                  : [
                      favoriteVideoJson(id: 93, type: 12),
                      favoriteVideoJson(id: 94, bvid: 'BV1xx411c7mD'),
                    ],
              more: page == 1,
            ),
          );
        };
        final selection = BilibiliFavoritesSelection()..enter();
        addTearDown(selection.dispose);
        await selection.selectAll(service, 7, 41);
        expect(selection.count, 2);
        expect(selection.videos.map((v) => v.id), [91, 94]);
        expect(selection.allSelected, isTrue);
        selection.toggle(selection.videos.first);
        expect(selection.allSelected, isFalse);
        await selection.selectAll(service, 7, 41);
        expect(selection.count, 2);
        expect(adapter.to(favoriteVideosPath), hasLength(2));
        await selection.selectAll(service, 7, 41);
        expect(selection.count, 0);
        expect(selection.active, isTrue);
      },
    );

    test('a failed full read preserves the earlier selection', () async {
      adapter.routes[favoriteVideosPath] = (request) => favoriteJson(
        request.queryParameters['pn'] == 1
            ? favoriteVideosAnswer(
                folder: favoriteFolderJson(count: 3),
                videos: [favoriteVideoJson()],
                more: true,
              )
            : {'code': -500},
      );
      final selected = BilibiliFavoriteVideo.tryParse(
        favoriteVideoJson(id: 999),
      )!;
      final selection = BilibiliFavoritesSelection()..enter(selected);
      addTearDown(selection.dispose);
      await selection.selectAll(service, 7, 41);
      expect(selection.videos, [selected]);
      expect(selection.error, isNotNull);
      expect(selection.allSelected, isFalse);
      expect(selection.loading, isFalse);
    });

    test(
      'exiting during a full read prevents a late selection or next page',
      () async {
        final pending = Completer<ResponseBody>();
        adapter.routes[favoriteVideosPath] = (_) => pending.future;
        final selection = BilibiliFavoritesSelection()..enter();
        addTearDown(selection.dispose);
        final job = selection.selectAll(service, 7, 41);
        await Future<void>.delayed(Duration.zero);
        selection.exit();
        pending.complete(
          favoriteJson(
            favoriteVideosAnswer(
              folder: favoriteFolderJson(count: 3),
              videos: [favoriteVideoJson()],
              more: true,
            ),
          ),
        );
        await job;
        expect(selection.count, 0);
        expect(selection.active, isFalse);
        expect(adapter.to(favoriteVideosPath).length, lessThanOrEqualTo(1));
      },
    );
  });

  group('shared pager refresh', () {
    BilibiliUploaderResult<BilibiliUploaderPage<int>> page(
      List<int> items, {
      bool more = false,
    }) => BilibiliUploaderResult.success(
      BilibiliUploaderPage(
        items: items,
        page: 1,
        total: 100,
        hasMoreHint: more,
      ),
    );

    test(
      'keeps visible rows on failed refresh and retries page one after the end',
      () async {
        final calls = <int>[];
        var answer = page([1, 2]);
        final pager = BilibiliUploaderPager<int>((pn) async {
          calls.add(pn);
          return answer;
        }, keyOf: (n) => n);
        addTearDown(pager.dispose);
        await pager.loadNext();
        expect(pager.hasMore, isFalse);
        answer = const BilibiliUploaderResult.failure(
          BilibiliUploaderStatus.networkError,
          '断网',
        );
        await pager.refresh();
        expect(pager.items, [1, 2]);
        expect(pager.failure, isNotNull);
        pager.loadMoreIfIdle();
        expect(calls, [1, 1]);
        answer = page([3]);
        await pager.loadNext();
        expect(calls, [1, 1, 1]);
        expect(pager.items, [3]);
        expect(pager.failure, isNull);
      },
    );

    test('drops a superseded page when refresh completes first', () async {
      final pending =
          Completer<BilibiliUploaderResult<BilibiliUploaderPage<int>>>();
      var calls = 0;
      final pager = BilibiliUploaderPager<int>(
        (pn) => ++calls == 1 ? pending.future : Future.value(page([9])),
        keyOf: (n) => n,
      );
      addTearDown(pager.dispose);
      final old = pager.loadNext();
      await pager.refresh();
      pending.complete(page([1]));
      await old;
      expect(pager.items, [9]);
    });

    test(
      'uses explicit continuation even for short or deduplicated pages',
      () async {
        var calls = 0;
        final pager = BilibiliUploaderPager<int>(
          (pn) async => page(++calls == 1 ? [1] : [1, 2], more: calls == 1),
          keyOf: (n) => n,
        );
        addTearDown(pager.dispose);
        await pager.loadNext();
        expect(pager.hasMore, isTrue);
        await pager.loadNext();
        expect(pager.items, [1, 2]);
        expect(pager.hasMore, isFalse);
      },
    );
  });
}
