import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/debug/log_redaction.dart';
import 'package:video_player_app/models/bilibili_browse_models.dart';
import 'package:video_player_app/services/bilibili/bilibili_device_identity.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_request_log.dart';
import 'package:video_player_app/services/bilibili/wbi_signer.dart';

const _bvid = 'BV1GJ411x7h7';

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

const _device = BilibiliDeviceIdentity(
  buvid3: 'DEV-B3infoc',
  buvid4: 'DEV-B4',
  bNut: '1700000000',
  uuid: 'DEV-UUIDinfoc',
);

/// A device id already saved; renewing issues `RENEWED-B3`.
BilibiliDeviceIdentitySource _savedDevice() => BilibiliDeviceIdentitySource(
  fetchFingerprint: () async => (b3: 'RENEWED-B3', b4: 'RENEWED-B4'),
  store: MemoryBilibiliDeviceIdentityStore(_device),
);

Map<String, String> _cookies(RequestOptions r) {
  final header = '${r.headers['Cookie'] ?? r.headers['cookie'] ?? ''}';
  return <String, String>{
    for (final part in header.split('; '))
      if (part.contains('='))
        part.substring(0, part.indexOf('=')): part.substring(
          part.indexOf('=') + 1,
        ),
  };
}

ResponseBody _nav() => _json({
  'code': -101,
  'data': {
    'wbi_img': {
      'img_url': 'https://i0.hdslb.com/bfs/wbi/${'a' * 32}.png',
      'sub_url': 'https://i0.hdslb.com/bfs/wbi/${'b' * 32}.png',
    },
  },
});

void main() {
  setUp(BilibiliRequestLog.instance.clear);

  test('detail carries device id and login, survives tag failure', () async {
    final adapter = _FakeAdapter((options) {
      if (options.path.endsWith('/x/web-interface/view')) {
        return _json({
          'code': 0,
          'data': {'bvid': _bvid, 'title': '标题', 'cid': 5},
        });
      }
      if (options.path.endsWith('/x/tag/archive/tags')) {
        return _json({'code': -500}, status: 500);
      }
      throw StateError('unexpected ${options.uri}');
    });
    final api = BilibiliPublicApiService(
      httpClientAdapter: adapter,
      identitySource: _savedDevice(),
      loginCookies: () async => {'SESSDATA': 'S-SECRET', 'bili_jct': 'J'},
    );

    final detail = await api.fetchVideoDetail(bvid: _bvid);

    expect(detail.title, '标题');
    expect(detail.tags, isEmpty);
    expect(adapter.requests, hasLength(2));
    for (final request in adapter.requests) {
      expect(_cookies(request), {
        'buvid3': 'DEV-B3infoc',
        'buvid4': 'DEV-B4',
        'b_nut': '1700000000',
        '_uuid': 'DEV-UUIDinfoc',
        'SESSDATA': 'S-SECRET',
        'bili_jct': 'J',
      });
      expect(
        request.headers['Referer'],
        'https://www.bilibili.com/video/$_bvid/',
      );
    }
  });

  test('detail error codes become Chinese messages', () async {
    final api = BilibiliPublicApiService(
      httpClientAdapter: _FakeAdapter((_) => _json({'code': -404})),
      identitySource: _savedDevice(),
    );
    await expectLater(
      api.fetchVideoDetail(bvid: _bvid),
      throwsA(
        isA<BilibiliPublicApiException>().having(
          (e) => e.message,
          'message',
          '视频不存在或已被删除',
        ),
      ),
    );
    await expectLater(
      api.fetchVideoDetail(bvid: 'nope'),
      throwsA(isA<BilibiliPublicApiException>()),
    );
  });

  test('detail falls back once to the signed endpoint on HTTP 412', () async {
    final adapter = _FakeAdapter((options) {
      final path = options.path;
      if (path.endsWith('/x/web-interface/view')) {
        return ResponseBody.fromString('<html></html>', 412);
      }
      if (path.endsWith('/x/web-interface/wbi/view')) {
        return _json({
          'code': 0,
          'data': {'bvid': _bvid, 'title': '重试成功'},
        });
      }
      if (path.endsWith('/x/web-interface/nav')) {
        return _json({
          'code': -101,
          'data': {
            'wbi_img': {
              'img_url': 'https://i0.hdslb.com/bfs/wbi/${'a' * 32}.png',
              'sub_url': 'https://i0.hdslb.com/bfs/wbi/${'b' * 32}.png',
            },
          },
        });
      }
      if (path.endsWith('/x/frontend/finger/spi')) {
        return _json({
          'code': 0,
          'data': {'b_3': 'ANON-ID'},
        });
      }
      return _json({'code': 0, 'data': []});
    });
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);

    final detail = await api.fetchVideoDetail(bvid: _bvid);

    expect(detail.title, '重试成功');
    final first = adapter.requests.firstWhere(
      (r) => r.path.endsWith('/x/web-interface/view'),
    );
    final retry = adapter.requests.singleWhere(
      (r) => r.path.endsWith('/wbi/view'),
    );
    // No saved id: the fingerprint endpoint issues it before the first
    // request; the retry renews it.
    expect(_cookies(first)['buvid3'], 'ANON-ID');
    expect(_cookies(first)['b_nut'], isNotEmpty);
    expect(_cookies(first)['_uuid'], endsWith('infoc'));
    expect(_cookies(retry)['buvid3'], 'ANON-ID');
    expect(
      adapter.requests.where((r) => r.path.endsWith('/finger/spi')),
      hasLength(2),
    );
    expect(retry.queryParameters['w_rid'], isA<String>());
  });

  test('video search is signed from the first try with device id', () async {
    final adapter = _FakeAdapter((options) {
      if (options.path.endsWith('/x/web-interface/nav')) return _nav();
      return _json({
        'code': 0,
        'data': {
          'numPages': 99,
          'result': [
            {'bvid': _bvid, 'title': '<em class="keyword">猫</em>'},
            {'bvid': _bvid, 'title': 'dup'},
            {'title': 'no id'},
          ],
        },
      });
    });
    final api = BilibiliPublicApiService(
      httpClientAdapter: adapter,
      identitySource: _savedDevice(),
    );

    final page = await api.searchVideos(
      ' 猫 ',
      page: 80,
      filter: const BilibiliVideoSearchFilter(
        order: BilibiliVideoSearchOrder.pubdate,
        duration: BilibiliVideoDurationFilter.from10To30,
        published: BilibiliPublishedFilter.lastDay,
      ),
      now: DateTime.utc(2026, 1, 2),
    );

    final search = adapter.requests.singleWhere(
      (r) => r.path.endsWith('/wbi/search/type'),
    );
    final query = search.queryParameters;
    expect(query['keyword'], '猫');
    expect(query['page'], 50);
    expect(query['order'], 'pubdate');
    expect(query['duration'], 2);
    expect(query['search_type'], 'video');
    expect(query['pubtime_end_s'] - query['pubtime_begin_s'], 86400);
    expect(query['w_rid'], hasLength(32));
    expect(query['wts'], isA<int>());
    expect(page.items.single.title, '猫');
    expect(page.hasMore, isFalse);
    expect(_cookies(search), _device.cookies);
    expect(search.headers['Origin'], 'https://search.bilibili.com');
    expect(
      search.headers['Referer'],
      startsWith('https://search.bilibili.com/all?keyword='),
    );
  });

  test('risk control renews keys and device id, retries once', () async {
    var searchCalls = 0;
    final adapter = _FakeAdapter((options) {
      final path = options.path;
      if (path.endsWith('/wbi/search/type')) {
        searchCalls++;
        if (searchCalls == 1) return _json({'code': -412});
        return _json({
          'code': 0,
          'data': {
            'numPages': 1,
            'result': [
              {'mid': 3, 'uname': 'UP'},
            ],
          },
        });
      }
      if (path.endsWith('/x/web-interface/nav')) {
        return _json({
          'code': -101,
          'data': {
            'wbi_img': {
              'img_url': 'https://i0.hdslb.com/bfs/wbi/${'a' * 32}.png',
              'sub_url': 'https://i0.hdslb.com/bfs/wbi/${'b' * 32}.png',
            },
          },
        });
      }
      throw StateError('unexpected ${options.uri}');
    });
    final api = BilibiliPublicApiService(
      httpClientAdapter: adapter,
      identitySource: _savedDevice(),
    );

    final page = await api.searchUsers('up');

    expect(page.items.single.name, 'UP');
    expect(searchCalls, 2);
    final searches = adapter.requests
        .where((r) => r.path.endsWith('/wbi/search/type'))
        .toList();
    expect(_cookies(searches.first)['buvid3'], 'DEV-B3infoc');
    expect(_cookies(searches.last)['buvid3'], 'RENEWED-B3');
    expect(_cookies(searches.last)['buvid4'], 'RENEWED-B4');
    for (final search in searches) {
      expect(search.queryParameters['w_rid'], isA<String>());
      expect(search.queryParameters['wts'], isA<int>());
    }
    // nav once for the first signature, once more to renew the keys.
    expect(
      adapter.requests.where((r) => r.path.endsWith('/web-interface/nav')),
      hasLength(2),
    );
    final logged = BilibiliRequestLog.instance.records
        .where((r) => r.path.endsWith('/wbi/search/type'))
        .toList();
    expect([for (final r in logged) r.code], [-412, 0]);
    expect([for (final r in logged) r.attempt], [1, 2]);
  });

  test('search still refused after the retry names the reason', () async {
    for (final refusal in <ResponseBody Function()>[
      () => _json({'code': -352, 'message': '风控校验失败'}),
      () => ResponseBody.fromString('<html></html>', 412),
      () => _json({
        'code': 0,
        'data': {'v_voucher': 'voucher_x'},
      }),
    ]) {
      var searchCalls = 0;
      final adapter = _FakeAdapter((options) {
        if (options.path.endsWith('/x/web-interface/nav')) return _nav();
        if (options.path.endsWith('/finger/spi')) {
          return _json({
            'code': 0,
            'data': {'b_3': 'NEW'},
          });
        }
        searchCalls++;
        return refusal();
      });
      final api = BilibiliPublicApiService(
        httpClientAdapter: adapter,
        identitySource: _savedDevice(),
      );
      await expectLater(
        api.searchVideos('猫'),
        throwsA(
          isA<BilibiliPublicApiException>().having(
            (e) => e.message,
            'message',
            allOf(contains('搜索被 B 站风控拦截'), contains('重试一次')),
          ),
        ),
      );
      expect(searchCalls, 2, reason: 'one retry only');
    }
  });

  test('request log keeps code and message but no cookie values', () async {
    final adapter = _FakeAdapter((options) {
      if (options.path.endsWith('/x/web-interface/nav')) return _nav();
      return _json({'code': -400, 'message': '请求错误'});
    });
    final api = BilibiliPublicApiService(
      httpClientAdapter: adapter,
      identitySource: _savedDevice(),
      loginCookies: () async => {
        'SESSDATA': 'S-SECRET',
        'bili_jct': 'J-SECRET',
      },
    );
    await expectLater(api.searchVideos('猫'), throwsA(anything));

    final record = BilibiliRequestLog.instance.records.lastWhere(
      (r) => r.path.endsWith('/wbi/search/type'),
    );
    expect(record.code, -400);
    expect(record.message, '请求错误');
    expect(record.hasDeviceId, isTrue);
    expect(record.hasLogin, isTrue);
    expect(record.signed, isTrue);
    for (final r in BilibiliRequestLog.instance.records) {
      final text = r.describe();
      for (final secret in [
        'S-SECRET',
        'J-SECRET',
        'DEV-B3infoc',
        'DEV-B4',
        'DEV-UUIDinfoc',
      ]) {
        expect(text, isNot(contains(secret)));
      }
    }
  });

  test('log redaction also masks device ids and csrf', () {
    final text = redactSensitiveLogText(
      'Cookie: buvid3=B3V; buvid4=B4V; _uuid=UV; b_nut=170; '
      'SESSDATA=SV; bili_jct=JV body csrf=CV&csrf_token=CT',
    );
    for (final value in ['B3V', 'B4V', 'UV', '170', 'SV', 'JV', 'CV', 'CT']) {
      expect(text, isNot(contains('=$value')));
    }
    expect(text, contains('buvid3=***'));
  });

  test('a device id is issued once, saved, and reused', () async {
    final store = MemoryBilibiliDeviceIdentityStore();
    var asked = 0;
    final source = BilibiliDeviceIdentitySource(
      fetchFingerprint: () async {
        asked++;
        return (b3: 'FP-B3', b4: 'FP-B4');
      },
      store: store,
      clock: () => DateTime.fromMillisecondsSinceEpoch(1700000000123),
    );
    final first = await source.ensure();
    expect(first.buvid3, 'FP-B3');
    expect(first.buvid4, 'FP-B4');
    expect(first.bNut, '1700000000');
    expect(first.uuid, matches(RegExp(r'^[0-9A-F-]{36}\d{5}infoc$')));
    expect(store.value!.cookies, first.cookies);
    expect(identical(await source.ensure(), first), isTrue);
    expect(asked, 1);

    // Without the fingerprint endpoint the id is generated locally.
    final offline = BilibiliDeviceIdentitySource(
      fetchFingerprint: () async => throw StateError('offline'),
      store: MemoryBilibiliDeviceIdentityStore(),
    );
    final generated = await offline.ensure();
    expect(generated.buvid3, endsWith('infoc'));
    expect(generated.isComplete, isTrue);
  });

  test('suggestions are capped at 10 and tolerate text/plain bodies', () async {
    final tags = [
      for (var i = 0; i < 15; i++) {'value': 'k$i'},
    ];
    final api = BilibiliPublicApiService(
      httpClientAdapter: _FakeAdapter(
        (_) => ResponseBody.fromString(
          jsonEncode({
            'code': 0,
            'result': {'tag': tags},
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain'],
          },
        ),
      ),
      identitySource: _savedDevice(),
    );
    final result = await api.suggestKeywords('k');
    expect(result, hasLength(10));
    expect(result.first, 'k0');

    expect(
      BilibiliPublicApiService.parseBilibiliSuggestions({'result': {}}),
      isEmpty,
    );
    final failing = BilibiliPublicApiService(
      httpClientAdapter: _FakeAdapter((_) => _json({}, status: 503)),
      identitySource: _savedDevice(),
    );
    expect(await failing.suggestKeywords('k'), isEmpty);
  });

  test('short link follows https redirects to a video', () async {
    final adapter = _FakeAdapter((options) {
      return ResponseBody.fromString(
        '',
        302,
        headers: {
          'location': ['https://www.bilibili.com/video/$_bvid?p=2&share=1'],
        },
      );
    });
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    final result = await api.resolveShortLink(Uri.parse('https://b23.tv/abc'));
    expect(result.target!.bvid, _bvid);
    expect(result.target!.page, 2);
    expect(adapter.requests.single.headers.containsKey('cookie'), isFalse);
    expect(adapter.requests.single.followRedirects, isFalse);

    // An http start is upgraded; the request itself goes out over https.
    final http = await api.resolveShortLink(Uri.parse('http://b23.tv/abc'));
    expect(http.target!.bvid, _bvid);
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.last.uri.scheme, 'https');
  });

  test('wbi signing keeps ascii-only parameters unchanged', () {
    final signed = WbiSigner.sign(
      {'bvid': _bvid, 'cid': 123, 'keyword': "it's(1)"},
      'a' * 32,
      'b' * 32,
    );
    expect(signed['bvid'], _bvid);
    expect(signed['cid'], 123);
    expect(signed['keyword'], 'its1');
    expect(signed['w_rid'], hasLength(32));
  });
}
