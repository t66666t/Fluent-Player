import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_device_identity.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_uploader_service.dart';

const _mid = 2233;
const _imgKey = '7cd084941338484aae1ad9425b84077c';
const _subKey = '4932caff0ff746eab6f01bf08b70ac45';

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);

/// Fake Bilibili: per-path answers, every request recorded. Unknown paths
/// fail the test.
class _FakeBili implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];
  final Map<String, FutureOr<ResponseBody> Function(RequestOptions)> routes = {
    '/x/web-interface/nav': (_) => _json({
      'code': -101,
      'data': {
        'wbi_img': {
          'img_url': 'https://i0.hdslb.com/bfs/wbi/$_imgKey.png',
          'sub_url': 'https://i0.hdslb.com/bfs/wbi/$_subKey.png',
        },
      },
    }),
    '/x/frontend/finger/spi': (_) => _json({
      'code': 0,
      'data': {'b_3': 'ANON-B3', 'b_4': 'x'},
    }),
  };

  List<String> get paths => [for (final r in requests) r.uri.path];

  List<RequestOptions> to(String path) => [
    for (final r in requests)
      if (r.uri.path == path) r,
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final route = routes[options.uri.path];
    if (route == null) throw StateError('unexpected ${options.uri.path}');
    return route(options);
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _card() => {
  'code': 0,
  'data': {
    'card': {
      'mid': '$_mid',
      'name': '名片UP',
      'face': '//i0.hdslb.com/bfs/face/a.jpg',
      'sign': '签名',
      'level_info': {'current_level': 6},
      'Official': {'title': '知名UP主'},
      'attention': 10,
      'fans': 100,
    },
    'follower': 100,
    'archive_count': 42,
    'like_num': 9000,
  },
};

List<Map<String, dynamic>> _vlist(int count, {int start = 0}) => [
  for (var i = 0; i < count; i++)
    {
      'bvid': 'BV1xx411c7m${String.fromCharCode(65 + (start + i) % 26)}',
      'aid': 1000 + start + i,
      'title': '视频<em class="keyword">$i</em>',
      'pic': 'http://i0.hdslb.com/bfs/archive/$i.jpg',
      'play': 10 + i,
      'comment': 2,
      'length': '01:05',
      'created': 1700000000,
    },
];

Map<String, dynamic> _videos({int count = 20, int total = 2000}) => {
  'code': 0,
  'data': {
    'list': {'vlist': _vlist(count)},
    'page': {'pn': 1, 'ps': 20, 'count': total},
  },
};

void main() {
  late _FakeBili bili;
  late BilibiliUploaderService service;

  setUp(() {
    bili = _FakeBili();
    service = BilibiliUploaderService(
      api: BilibiliPublicApiService(
        httpClientAdapter: bili,
        identitySource: BilibiliDeviceIdentitySource(
          fetchFingerprint: () async => (b3: 'RENEWED-B3', b4: 'RENEWED-B4'),
          store: MemoryBilibiliDeviceIdentityStore(
            const BilibiliDeviceIdentity(
              buvid3: 'DEV-B3',
              buvid4: 'DEV-B4',
              bNut: '1700000000',
              uuid: 'DEV-UUID',
            ),
          ),
        ),
        loginCookies: () async => {'SESSDATA': 'S', 'bili_jct': 'J'},
      ),
    );
  });

  String cookieOf(RequestOptions r) => r.headers.entries
      .where((e) => e.key.toLowerCase() == 'cookie')
      .map((e) => '${e.value}')
      .join();

  /// Every space request carries the device id and the login, like the
  /// space page in a browser, and names that page as Referer and Origin.
  void expectBrowserSession() {
    for (final r in bili.requests) {
      if (r.uri.path == '/x/web-interface/nav') continue;
      final cookie = cookieOf(r);
      for (final part in [
        'buvid3=',
        'buvid4=',
        'b_nut=',
        '_uuid=',
        'SESSDATA=S',
        'bili_jct=J',
      ]) {
        expect(cookie, contains(part), reason: r.uri.path);
      }
      expect(r.headers['Origin'], 'https://space.bilibili.com');
      expect(
        '${r.headers['Referer']}',
        startsWith('https://space.bilibili.com/$_mid'),
      );
    }
  }

  group('profile', () {
    test(
      'publishes a usable card while supplementary counts are pending',
      () async {
        final stat = Completer<ResponseBody>();
        final preview = Completer<BilibiliUploaderProfile>();
        bili.routes['/x/web-interface/card'] = (_) => _json(_card());
        bili.routes['/x/relation/stat'] = (_) => stat.future;
        final pending = service.fetchProfile(_mid, onProfile: preview.complete);

        final card = await preview.future;
        expect(card.name, '名片UP');
        expect(card.follower, 100);
        expect(stat.isCompleted, isFalse);

        stat.complete(
          _json({
            'code': 0,
            'data': {'following': 11, 'follower': 123},
          }),
        );
        final complete = await pending;
        expect(complete.data!.follower, 123);
        expect(complete.data!.following, 11);
      },
    );

    test('card works: no signing, then follower stat fills counts', () async {
      bili.routes['/x/web-interface/card'] = (_) => _json(_card());
      bili.routes['/x/relation/stat'] = (_) => _json({
        'code': 0,
        'data': {'mid': _mid, 'following': 11, 'follower': 123},
      });

      final result = await service.fetchProfile(_mid);

      expect(result.isSuccess, isTrue);
      final p = result.data!;
      expect(p.name, '名片UP');
      expect(p.avatarUrl, 'https://i0.hdslb.com/bfs/face/a.jpg');
      expect(p.level, 6);
      expect(p.officialTitle, '知名UP主');
      expect(p.following, 11);
      expect(p.follower, 123);
      expect(p.archiveCount, 42);
      expect(bili.paths, isNot(contains('/x/space/wbi/acc/info')));
      expect(bili.to('/x/web-interface/card').single.uri.queryParameters, {
        'mid': '$_mid',
        'photo': 'false',
      });
      expect(bili.to('/x/relation/stat').single.uri.queryParameters, {
        'vmid': '$_mid',
      });
      expectBrowserSession();
    });

    test('card failure falls back to the WBI-signed account info', () async {
      bili.routes['/x/web-interface/card'] = (_) => _json({'code': -352});
      bili.routes['/x/space/wbi/acc/info'] = (_) => _json({
        'code': 0,
        'data': {
          'mid': _mid,
          'name': '兜底UP',
          'face': 'https://i1.hdslb.com/bfs/face/b.jpg',
          'level': 5,
          'official': {'title': ''},
        },
      });
      bili.routes['/x/relation/stat'] = (_) => _json({
        'code': 0,
        'data': {'following': 3, 'follower': 456},
      });

      final result = await service.fetchProfile(_mid);

      expect(result.isSuccess, isTrue);
      expect(result.data!.name, '兜底UP');
      expect(result.data!.level, 5);
      expect(result.data!.follower, 456);
      expect(result.data!.following, 3);
      final acc = bili.to('/x/space/wbi/acc/info').single;
      expect(acc.uri.queryParameters['mid'], '$_mid');
      expect(
        acc.uri.queryParameters['w_rid'],
        matches(RegExp(r'^[0-9a-f]{32}$')),
      );
      expect(acc.uri.queryParameters['wts'], isNotEmpty);
      expect(acc.uri.queryParameters['web_location'], '1550101');
      expect(acc.uri.queryParameters['platform'], 'web');
      expect(acc.uri.queryParameters['dm_img_list'], '[]');
      expect(acc.uri.queryParameters['dm_img_inter'], isNotEmpty);
      // The card is not retried: the account info is its fallback.
      expect(bili.to('/x/web-interface/card'), hasLength(1));
      expectBrowserSession();
    });

    test('card network error also falls back', () async {
      bili.routes['/x/web-interface/card'] = (_) => _json({}, status: 500);
      bili.routes['/x/space/wbi/acc/info'] = (_) => _json({
        'code': 0,
        'data': {'mid': _mid, 'name': '兜底UP'},
      });
      bili.routes['/x/relation/stat'] = (_) => _json({'code': -400});
      final result = await service.fetchProfile(_mid);
      expect(result.data!.name, '兜底UP');
      expect(result.data!.follower, isNull);
    });

    test('a failed follower stat keeps the profile fields', () async {
      bili.routes['/x/web-interface/card'] = (_) => _json(_card());
      bili.routes['/x/relation/stat'] = (_) => _json({}, status: 412);

      final result = await service.fetchProfile(_mid);

      expect(result.isSuccess, isTrue);
      expect(result.data!.name, '名片UP');
      expect(result.data!.sign, '签名');
      // The card's own counts survive the failed supplement.
      expect(result.data!.follower, 100);
      expect(result.data!.following, 10);
    });

    test('both profile sources failing gives a clear result', () async {
      bili.routes['/x/web-interface/card'] = (_) => _json({'code': -352});
      bili.routes['/x/space/wbi/acc/info'] = (_) => _json({'code': -412});
      final result = await service.fetchProfile(_mid);
      expect(result.isSuccess, isFalse);
      expect(result.status, BilibiliUploaderStatus.riskControlled);
      expect(result.message, contains('UP 主资料被 B 站风控拦截（错误码 -412）'));
      expect(bili.to('/x/space/wbi/acc/info'), hasLength(2));
      expect(bili.paths, isNot(contains('/x/relation/stat')));
    });

    test('invalid mid sends nothing', () async {
      final result = await service.fetchProfile(0);
      expect(result.isSuccess, isFalse);
      expect(bili.requests, isEmpty);
    });
  });

  group('videos', () {
    test('20 per page, signed, sort and keyword parameters', () async {
      bili.routes['/x/space/wbi/arc/search'] = (_) => _json(_videos());

      final result = await service.fetchVideos(
        _mid,
        page: 3,
        order: BilibiliUploaderVideoOrder.mostPlayed,
        keyword: '  教程 ',
      );

      expect(result.isSuccess, isTrue);
      final page = result.data!;
      expect(page.items, hasLength(20));
      expect(page.items.first.title, '视频0');
      expect(
        page.items.first.coverUrl,
        'https://i0.hdslb.com/bfs/archive/0.jpg@320w_200h_1c.webp',
      );
      expect(page.items.first.durationSeconds, 65);
      expect(page.page, 3);
      expect(page.pageCount, kBilibiliUploaderMaxPages);
      expect(page.hasMore, isTrue);

      final q = bili.to('/x/space/wbi/arc/search').single.uri.queryParameters;
      expect(q['mid'], '$_mid');
      expect(q['ps'], '20');
      expect(q['pn'], '3');
      expect(q['order'], 'click');
      expect(q['keyword'], '教程');
      expect(q['w_rid'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(q['web_location'], '333.1387');
      expect(q['platform'], 'web');
      expect(q['order_avoided'], 'true');
      for (final key in [
        'dm_img_list',
        'dm_img_str',
        'dm_cover_img_str',
        'dm_img_inter',
      ]) {
        expect(q[key], isNotEmpty, reason: key);
      }
      expect(
        bili.to('/x/space/wbi/arc/search').single.headers['Referer'],
        'https://space.bilibili.com/$_mid/video',
      );
      expectBrowserSession();
    });

    test('each sort maps to its parameter', () async {
      bili.routes['/x/space/wbi/arc/search'] = (_) => _json(_videos());
      for (final order in BilibiliUploaderVideoOrder.values) {
        await service.fetchVideos(_mid, order: order);
      }
      expect(
        [
          for (final r in bili.to('/x/space/wbi/arc/search'))
            r.uri.queryParameters['order'],
        ],
        ['pubdate', 'click', 'stow'],
      );
      expect(
        bili.to('/x/space/wbi/arc/search').first.uri.queryParameters['keyword'],
        '',
      );
    });

    test('pages stop at 50', () async {
      bili.routes['/x/space/wbi/arc/search'] = (_) => _json(_videos());
      final result = await service.fetchVideos(_mid, page: 99);
      expect(
        bili.to('/x/space/wbi/arc/search').single.uri.queryParameters['pn'],
        '50',
      );
      expect(result.data!.page, 50);
      expect(result.data!.hasMore, isFalse);

      await service.fetchVideos(_mid, page: 0);
      expect(
        bili.to('/x/space/wbi/arc/search').last.uri.queryParameters['pn'],
        '1',
      );

      const short = BilibiliUploaderPage<int>(items: [1], page: 2, total: 40);
      expect(short.pageCount, 2);
      expect(short.hasMore, isFalse);
    });

    test('risk control renews keys and device id, retries once', () async {
      var calls = 0;
      bili.routes['/x/space/wbi/arc/search'] = (_) =>
          ++calls == 1 ? _json({'code': -352}) : _json(_videos(count: 5));

      final result = await service.fetchVideos(_mid, keyword: 'k');

      expect(result.isSuccess, isTrue);
      expect(result.data!.items, hasLength(5));
      final tries = bili.to('/x/space/wbi/arc/search');
      expect(tries, hasLength(2));
      expect(cookieOf(tries.first), contains('buvid3=DEV-B3'));
      expect(cookieOf(tries.last), contains('buvid3=RENEWED-B3'));
      expect(tries.last.uri.queryParameters['keyword'], 'k');
      expect(tries.last.uri.queryParameters['w_rid'], isNotEmpty);
      expect(bili.to('/x/web-interface/nav'), hasLength(2));
      expect(bili.paths, isNot(contains('/x/space/arc/search')));
    });

    test('still blocked after the one retry: clear risk result', () async {
      for (final refusal in [
        () => _json({}, status: 412),
        () => _json({'code': -799, 'message': '请求过于频繁'}),
      ]) {
        bili.requests.clear();
        bili.routes['/x/space/wbi/arc/search'] = (_) => refusal();

        final result = await service.fetchVideos(_mid);

        expect(result.isSuccess, isFalse);
        expect(result.status, BilibiliUploaderStatus.riskControlled);
        expect(result.message, startsWith('投稿列表被 B 站风控拦截'));
        expect(result.message, contains('重试一次'));
        expect(bili.to('/x/space/wbi/arc/search'), hasLength(2));
        expect(bili.paths, isNot(contains('/x/space/arc/search')));
      }
    });

    test('other errors are not retried', () async {
      bili.routes['/x/space/wbi/arc/search'] = (_) => _json({'code': -400});
      final result = await service.fetchVideos(_mid);
      expect(result.status, BilibiliUploaderStatus.failed);
      expect(bili.to('/x/space/wbi/arc/search'), hasLength(1));
    });
  });

  group('articles and collections', () {
    test('articles page parses and failures come back as results', () async {
      bili.routes['/x/space/wbi/article'] = (_) => _json({
        'code': 0,
        'data': {
          'articles': [
            {
              'id': 77,
              'title': '专栏一',
              'summary': '摘要',
              'banner_url': 'https://i0.hdslb.com/bfs/article/x.jpg',
              'publish_time': 1700000000,
              'stats': {'view': 9, 'like': 3},
            },
            {'id': 0, 'title': '无效'},
          ],
          'pn': 2,
          'ps': 20,
          'count': 21,
        },
      });
      final ok = await service.fetchArticles(_mid, page: 2);
      expect(ok.isSuccess, isTrue);
      expect(ok.data!.items.single.title, '专栏一');
      expect(ok.data!.items.single.viewCount, 9);
      expect(ok.data!.hasMore, isFalse);
      final q = bili.to('/x/space/wbi/article').single.uri.queryParameters;
      expect(q['pn'], '2');
      expect(q['ps'], '20');
      expect(q['w_rid'], isNotNull);

      bili.routes['/x/space/wbi/article'] = (_) => _json({}, status: 503);
      final bad = await service.fetchArticles(_mid);
      expect(bad.isSuccess, isFalse);
      expect(bad.status, BilibiliUploaderStatus.networkError);
      expect(bad.message, isNotEmpty);
    });

    test('collections page lists seasons then series', () async {
      bili.routes['/x/polymer/web-space/seasons_series_list'] = (_) => _json({
        'code': 0,
        'data': {
          'items_lists': {
            'page': {'page_num': 1, 'page_size': 20, 'total': 45},
            'seasons_list': [
              {
                'meta': {
                  'season_id': 5,
                  'name': '合集A',
                  'cover': '//i0.hdslb.com/bfs/c.jpg',
                  'total': 12,
                },
              },
            ],
            'series_list': [
              {
                'meta': {'series_id': 8, 'name': '系列B', 'total': 3},
              },
            ],
          },
        },
      });
      final result = await service.fetchCollections(_mid);
      expect(result.isSuccess, isTrue);
      final items = result.data!.items;
      expect(items.map((c) => c.title), ['合集A', '系列B']);
      expect(items.first.isSeason, isTrue);
      expect(items.first.videoCount, 12);
      expect(items.last.isSeason, isFalse);
      expect(result.data!.hasMore, isTrue);
      final q = bili
          .to('/x/polymer/web-space/seasons_series_list')
          .single
          .uri
          .queryParameters;
      expect(q['page_num'], '1');
      expect(q['page_size'], '20');
      expectBrowserSession();
    });

    test('collections failures never throw', () async {
      bili.routes['/x/polymer/web-space/seasons_series_list'] = (_) =>
          _json({'code': -352});
      final risk = await service.fetchCollections(_mid);
      expect(risk.status, BilibiliUploaderStatus.riskControlled);

      bili.routes['/x/polymer/web-space/seasons_series_list'] = (_) =>
          throw DioException.connectionError(
            requestOptions: RequestOptions(),
            reason: 'offline',
          );
      final offline = await service.fetchCollections(_mid);
      expect(offline.status, BilibiliUploaderStatus.networkError);
      expect(offline.message, isNotEmpty);
    });

    test('collection videos: season and series pages', () async {
      bili.routes['/x/polymer/web-space/seasons_archives_list'] = (_) => _json({
        'code': 0,
        'data': {
          'archives': [
            {
              'bvid': 'BV1xx411c7mA',
              'title': '合集一',
              'duration': 125,
              'pubdate': 1700000000,
              'stat': {'view': 321, 'reply': 4},
            },
          ],
          'page': {'page_num': 2, 'page_size': 20, 'total': 41},
        },
      });
      bili.routes['/x/series/archives'] = (_) => _json({'code': -400});

      const season = BilibiliUploaderCollection(
        id: 5,
        isSeason: true,
        title: '合集A',
      );
      final ok = await service.fetchCollectionVideos(_mid, season, page: 2);
      expect(ok.isSuccess, isTrue);
      final video = ok.data!.items.single;
      expect(video.title, '合集一');
      expect(video.playCount, 321);
      expect(video.commentCount, 4);
      expect(video.durationSeconds, 125);
      expect(ok.data!.hasMore, isTrue);
      final q = bili
          .to('/x/polymer/web-space/seasons_archives_list')
          .single
          .uri
          .queryParameters;
      expect(q['mid'], '$_mid');
      expect(q['season_id'], '5');
      expect(q['page_num'], '2');
      expect(q['page_size'], '20');

      const series = BilibiliUploaderCollection(
        id: 8,
        isSeason: false,
        title: '系列B',
      );
      final bad = await service.fetchCollectionVideos(_mid, series, page: 99);
      expect(bad.isSuccess, isFalse);
      expect(bad.status, BilibiliUploaderStatus.failed);
      final sq = bili.to('/x/series/archives').single.uri.queryParameters;
      expect(sq['series_id'], '8');
      expect(sq['pn'], '50');
      expect(sq['ps'], '20');
      expectBrowserSession();

      final none = await service.fetchCollectionVideos(
        _mid,
        const BilibiliUploaderCollection(id: 0, isSeason: true, title: 'x'),
      );
      expect(none.isSuccess, isFalse);
    });
  });
}
