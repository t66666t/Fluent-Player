import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/models/bilibili_uploader_models.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_uploader_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_video_detail_cache.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_player_panel.dart';

const _mid = 9527;
const _detailBvid = 'BV1GJ411x7h7';
const _imgKey = '7cd084941338484aae1ad9425b84077c';
const _subKey = '4932caff0ff746eab6f01bf08b70ac45';
const _wbiSearch = '/x/space/wbi/arc/search';
const _oldSearch = '/x/space/arc/search';
const _videosRisk = '投稿列表被 B 站风控拦截（错误码 -352），已自动重试一次，请稍后再试';

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);

String _bvid(int page, int index) =>
    'BV1Up${page.toString().padLeft(2, '0')}'
    '${index.toString().padLeft(2, '0')}abc';

Map<String, dynamic> _videoPage(int page, {int count = 20, int total = 2000}) =>
    {
      'code': 0,
      'data': {
        'list': {
          'vlist': [
            for (var i = 0; i < count; i++)
              {
                'bvid': _bvid(page, i),
                'aid': page * 100 + i,
                'title': '投稿 $page-$i',
                'play': 100,
                'length': '02:00',
                'created': 1700000000,
              },
          ],
        },
        'page': {'pn': page, 'ps': 20, 'count': total},
      },
    };

/// Fake Bilibili for the uploader page. Records every request; a request
/// matching [holdWhen] waits for [hold].
class _FakeBili implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];
  Completer<void>? hold;
  bool Function(RequestOptions r)? holdWhen;

  late final Map<String, ResponseBody Function(RequestOptions)> routes = {
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
      'data': {'b_3': 'ANON-B3'},
    }),
    '/x/web-interface/card': (_) => _json({
      'code': 0,
      'data': {
        'card': {
          'mid': _mid,
          'name': '名片UP',
          'sign': '认真做视频',
          'level_info': {'current_level': 6},
        },
        'archive_count': 42,
      },
    }),
    '/x/relation/stat': (_) => _json({
      'code': 0,
      'data': {'following': 11, 'follower': 123},
    }),
    _wbiSearch: (r) =>
        _json(_videoPage(int.parse('${r.queryParameters['pn']}'))),
    '/x/web-interface/view': (_) => _json({
      'code': 0,
      'data': {
        'bvid': _detailBvid,
        'aid': 170001,
        'title': '详情标题',
        'owner': {'mid': _mid, 'name': '名片UP'},
        'pages': [
          {'cid': 1, 'page': 1, 'part': 'P1'},
        ],
      },
    }),
    '/x/tag/archive/tags': (_) => _json({'code': 0, 'data': []}),
    '/main/suggest': (_) => _json({'result': {}}),
  };

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
    final gate = hold;
    if (gate != null && (holdWhen?.call(options) ?? true)) await gate.future;
    final route = routes[options.uri.path];
    if (route == null) throw StateError('unexpected ${options.uri.path}');
    return route(options);
  }

  @override
  void close({bool force = false}) {}
}

class _Env {
  _Env(this.bili, this.opened, this.watched);

  final _FakeBili bili;
  final List<Uri> opened;

  /// BV ids handed to the play entry, in tap order.
  final List<String> watched;
}

Future<_Env> _pumpUploader(
  WidgetTester tester, {
  void Function(_FakeBili bili)? configure,
}) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final bili = _FakeBili();
  configure?.call(bili);
  final opened = <Uri>[];
  final watched = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: BilibiliUploaderScreen(
        mid: _mid,
        initialName: '名片UP',
        api: BilibiliPublicApiService(httpClientAdapter: bili),
        openExternal: (uri) async {
          opened.add(uri);
          return true;
        },
        onWatch: (context, {required bvid, page, startAt, preview}) async {
          watched.add(bvid);
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Env(bili, opened, watched);
}

/// Lets plain-async fakes complete (outside widget tests).
Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Pumps a few frames without settling (a footer spinner never settles).
Future<void> _frames(WidgetTester tester, [int count = 6]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _dragToEnd(WidgetTester tester) async {
  await tester.drag(
    find.bySubtype<ListView>().first,
    const Offset(0, -3000),
    warnIfMissed: false,
  );
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
  });

  group('pager', () {
    BilibiliUploaderResult<BilibiliUploaderPage<int>> page(
      int pn, {
      int count = kBilibiliUploaderPageSize,
      int total = 0,
    }) => BilibiliUploaderResult.success(
      BilibiliUploaderPage<int>(
        items: [for (var i = 0; i < count; i++) pn * 1000 + i],
        page: pn,
        total: total,
      ),
    );

    test('only one page request at a time', () async {
      final calls = <int>[];
      final pending = Completer<void>();
      final pager = BilibiliUploaderPager<int>((pn) async {
        calls.add(pn);
        await pending.future;
        return page(pn);
      }, keyOf: (i) => i);
      for (var i = 0; i < 5; i++) {
        unawaited(pager.loadNext());
        pager.loadMoreIfIdle();
      }
      expect(calls, [1]);
      pending.complete();
      await _settle();
      expect(pager.page, 1);
      expect(pager.items, hasLength(20));
      pager.dispose();
    });

    test('stops at page 50 and never asks again', () async {
      final calls = <int>[];
      final pager = BilibiliUploaderPager<int>((pn) async {
        calls.add(pn);
        return page(pn);
      }, keyOf: (i) => i);
      for (var i = 0; i < 80; i++) {
        pager.loadMoreIfIdle();
        await _settle();
      }
      expect(calls, [for (var p = 1; p <= 50; p++) p]);
      expect(pager.hasMore, isFalse);
      expect(pager.reachedPageLimit, isTrue);
      await pager.loadNext();
      expect(calls, hasLength(50));
      pager.dispose();
    });

    test('a short or empty page ends the list', () async {
      final calls = <int>[];
      final short = BilibiliUploaderPager<int>((pn) async {
        calls.add(pn);
        return page(pn, count: pn == 1 ? 20 : 7);
      }, keyOf: (i) => i);
      for (var i = 0; i < 5; i++) {
        short.loadMoreIfIdle();
        await _settle();
      }
      expect(calls, [1, 2]);
      expect(short.hasMore, isFalse);

      var emptyCalls = 0;
      final empty = BilibiliUploaderPager<int>((pn) async {
        emptyCalls++;
        return page(pn, count: 0);
      }, keyOf: (i) => i);
      for (var i = 0; i < 5; i++) {
        empty.loadMoreIfIdle();
        await _settle();
      }
      expect(emptyCalls, 1);
      expect(empty.items, isEmpty);
      short.dispose();
      empty.dispose();
    });

    test('after a failure only a manual retry asks again', () async {
      var calls = 0;
      var fail = true;
      final pager = BilibiliUploaderPager<int>((pn) async {
        calls++;
        return fail
            ? const BilibiliUploaderResult.failure(
                BilibiliUploaderStatus.riskControlled,
                BilibiliUploaderResult.riskMessage,
              )
            : page(pn);
      }, keyOf: (i) => i);
      pager.loadMoreIfIdle();
      await _settle();
      expect(calls, 1);
      expect(pager.failure!.status, BilibiliUploaderStatus.riskControlled);
      for (var i = 0; i < 5; i++) {
        pager.loadMoreIfIdle();
        await _settle();
      }
      expect(calls, 1);
      fail = false;
      await pager.loadNext();
      expect(calls, 2);
      expect(pager.failure, isNull);
      expect(pager.items, hasLength(20));
      pager.dispose();
    });
  });

  testWidgets('loads the header and the first page of videos', (tester) async {
    final env = await _pumpUploader(tester);
    final bili = env.bili;

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('bilibili-uploader-name')))
          .data,
      '名片UP',
    );
    expect(find.text('关注 11   粉丝 123   投稿 42'), findsOneWidget);
    expect(find.text('认真做视频'), findsOneWidget);
    expect(find.text('投稿 1-0'), findsOneWidget);
    for (final label in ['投稿', '专栏', '合集']) {
      expect(find.widgetWithText(Tab, label), findsOneWidget);
    }

    final q = bili.to(_wbiSearch).single.uri.queryParameters;
    expect(q['ps'], '20');
    expect(q['pn'], '1');
    expect(q['order'], 'pubdate');
    expect(q['keyword'], '');
    // Articles and collections wait for their tab.
    expect(bili.to('/x/space/wbi/article'), isEmpty);
    expect(bili.to('/x/polymer/web-space/seasons_series_list'), isEmpty);
    // Every request but the device-id lookup itself carries the device id.
    for (final r in bili.requests) {
      if (r.uri.path == '/x/frontend/finger/spi') continue;
      final cookie = '${r.headers['Cookie'] ?? r.headers['cookie'] ?? ''}';
      expect(cookie, contains('buvid3=ANON-B3'), reason: r.uri.path);
      expect(cookie, contains('_uuid='), reason: r.uri.path);
    }
  });

  testWidgets('sort and keyword restart the list with their parameters', (
    tester,
  ) async {
    final env = await _pumpUploader(tester);
    final bili = env.bili;

    await tester.tap(
      find.byKey(const ValueKey('bilibili-uploader-order-mostPlayed')),
    );
    await tester.pumpAndSettle();
    var q = bili.to(_wbiSearch).last.uri.queryParameters;
    expect(q['order'], 'click');
    expect(q['pn'], '1');

    await tester.tap(
      find.byKey(const ValueKey('bilibili-uploader-order-mostFavorited')),
    );
    await tester.pumpAndSettle();
    expect(bili.to(_wbiSearch).last.uri.queryParameters['order'], 'stow');

    await tester.enterText(
      find.byKey(const ValueKey('bilibili-uploader-search')),
      ' 教程 ',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    q = bili.to(_wbiSearch).last.uri.queryParameters;
    expect(q['keyword'], '教程');
    expect(q['order'], 'stow');
    expect(q['pn'], '1');
    expect(bili.to(_wbiSearch), hasLength(4));
  });

  testWidgets(
    'Android touch outside uploader search releases focus',
    (tester) async {
      await _pumpUploader(tester);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('bilibili-uploader-search'));
      for (final keyboardHidden in [false, true]) {
        await tester.tap(input, kind: PointerDeviceKind.touch);
        await tester.pump();
        final focus = tester
            .widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            )
            .focusNode;
        expect(focus.hasFocus, isTrue);
        if (keyboardHidden) tester.testTextInput.hide();
        await tester.tapAt(
          const Offset(375, 15),
          kind: PointerDeviceKind.touch,
        );
        await tester.pumpAndSettle();
        expect(focus.hasFocus, isFalse);
        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.text('投稿 1-0'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('scrolling to the end keeps one page request in flight', (
    tester,
  ) async {
    final env = await _pumpUploader(tester);
    final bili = env.bili;
    expect(bili.to(_wbiSearch), hasLength(1));

    bili
      ..hold = Completer<void>()
      ..holdWhen = (r) => r.uri.path == _wbiSearch;
    for (var i = 0; i < 5; i++) {
      await _dragToEnd(tester);
    }
    await _frames(tester);
    expect(bili.to(_wbiSearch), hasLength(2));
    expect(bili.to(_wbiSearch).last.uri.queryParameters['pn'], '2');

    final held = bili.hold!;
    bili.hold = null;
    held.complete();
    await _frames(tester);
    await _dragToEnd(tester);
    await _frames(tester);
    expect(bili.to(_wbiSearch).map((r) => r.uri.queryParameters['pn']), [
      '1',
      '2',
      '3',
    ]);
  });

  testWidgets('risk control: one automatic retry, then a manual retry', (
    tester,
  ) async {
    final env = await _pumpUploader(
      tester,
      configure: (bili) {
        bili.routes[_wbiSearch] = (_) => _json({'code': -352});
      },
    );
    final bili = env.bili;

    expect(find.text(_videosRisk), findsOneWidget);
    expect(
      find.byKey(const ValueKey('bilibili-uploader-retry')),
      findsOneWidget,
    );
    expect(bili.to(_wbiSearch), hasLength(2));
    expect(bili.to(_oldSearch), isEmpty);

    // No more automatic retries: time passing and scrolling ask nothing.
    await tester.pump(const Duration(seconds: 10));
    await tester.drag(
      find.text(_videosRisk),
      const Offset(0, -400),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(bili.to(_wbiSearch), hasLength(2));

    await tester.tap(find.byKey(const ValueKey('bilibili-uploader-retry')));
    await tester.pumpAndSettle();
    expect(bili.to(_wbiSearch), hasLength(4));
    expect(bili.to(_oldSearch), isEmpty);
  });

  testWidgets('risk control on a later page shows a footer retry only', (
    tester,
  ) async {
    final env = await _pumpUploader(
      tester,
      configure: (bili) {
        bili.routes[_wbiSearch] = (r) => r.queryParameters['pn'] == 1
            ? _json(_videoPage(1))
            : _json({'code': -352});
      },
    );
    final bili = env.bili;
    for (var i = 0; i < 4; i++) {
      await _dragToEnd(tester);
      await _frames(tester, 2);
    }
    await tester.pumpAndSettle();
    // Page 1, then page 2 and its one automatic retry.
    expect(bili.to(_wbiSearch), hasLength(3));
    expect(find.text('$_videosRisk，点此重试'), findsOneWidget);

    for (var i = 0; i < 3; i++) {
      await _dragToEnd(tester);
    }
    await tester.pumpAndSettle();
    expect(bili.to(_wbiSearch), hasLength(3));

    await tester.tap(find.byKey(const ValueKey('bilibili-uploader-retry')));
    await tester.pumpAndSettle();
    expect(bili.to(_wbiSearch), hasLength(5));
    expect(bili.to(_oldSearch), isEmpty);
  });

  testWidgets('a failed profile shows the message and retries by hand', (
    tester,
  ) async {
    final env = await _pumpUploader(
      tester,
      configure: (bili) {
        bili.routes['/x/web-interface/card'] = (_) => _json({'code': -352});
        bili.routes['/x/space/wbi/acc/info'] = (_) => _json({'code': -412});
      },
    );
    expect(
      find.text('UP 主资料被 B 站风控拦截（错误码 -412），已自动重试一次，请稍后再试'),
      findsOneWidget,
    );
    expect(find.text('投稿 1-0'), findsOneWidget, reason: 'lists still load');
    expect(env.bili.to('/x/web-interface/card'), hasLength(1));
    await tester.tap(
      find.byKey(const ValueKey('bilibili-uploader-profile-retry')),
    );
    await tester.pumpAndSettle();
    expect(env.bili.to('/x/web-interface/card'), hasLength(2));
  });

  testWidgets('an empty video list shows the empty state', (tester) async {
    await _pumpUploader(
      tester,
      configure: (bili) =>
          bili.routes[_wbiSearch] = (_) =>
              _json(_videoPage(1, count: 0, total: 0)),
    );
    expect(find.text('还没有投稿'), findsOneWidget);
  });

  testWidgets('tapping a video plays it instead of opening the detail page', (
    tester,
  ) async {
    final env = await _pumpUploader(tester);
    await tester.tap(find.text('投稿 1-0'));
    await tester.pumpAndSettle();
    expect(env.watched, hasLength(1));
    expect(find.byType(BilibiliUploaderScreen), findsOneWidget);
  });

  testWidgets('articles open their https bilibili.com page', (tester) async {
    final env = await _pumpUploader(
      tester,
      configure: (bili) => bili.routes['/x/space/wbi/article'] = (_) => _json({
        'code': 0,
        'data': {
          'articles': [
            {'id': 77, 'title': '专栏一', 'summary': '摘要'},
          ],
          'count': 1,
        },
      }),
    );
    await tester.tap(find.widgetWithText(Tab, '专栏'));
    await tester.pumpAndSettle();
    expect(find.text('专栏一'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);
    await tester.tap(find.text('专栏一'));
    await tester.pumpAndSettle();
    expect(env.opened, [Uri.parse('https://www.bilibili.com/read/cv77')]);

    expect(isOpenableBilibiliWebUri(bilibiliArticleUri(1)), isTrue);
    for (final bad in [
      'http://www.bilibili.com/read/cv1',
      'https://bilibili.com.evil.com/read/cv1',
      'https://evil.com/read/cv1',
      'https://u@www.bilibili.com/read/cv1',
    ]) {
      expect(isOpenableBilibiliWebUri(Uri.parse(bad)), isFalse, reason: bad);
    }
  });

  testWidgets('collections open a paged video list; a video plays directly', (
    tester,
  ) async {
    final env = await _pumpUploader(
      tester,
      configure: (bili) {
        bili.routes['/x/polymer/web-space/seasons_series_list'] = (_) => _json({
          'code': 0,
          'data': {
            'items_lists': {
              'page': {'total': 1},
              'seasons_list': [
                {
                  'meta': {'season_id': 5, 'name': '合集A', 'total': 2},
                },
              ],
            },
          },
        });
        bili.routes['/x/polymer/web-space/seasons_archives_list'] = (_) =>
            _json({
              'code': 0,
              'data': {
                'archives': [
                  {
                    'bvid': _detailBvid,
                    'title': '合集视频一',
                    'duration': 61,
                    'stat': {'view': 5},
                  },
                ],
                'page': {'page_num': 1, 'page_size': 20, 'total': 1},
              },
            });
      },
    );
    await tester.tap(find.widgetWithText(Tab, '合集'));
    await tester.pumpAndSettle();
    expect(find.text('合集A'), findsOneWidget);
    await tester.tap(find.text('合集A'));
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliUploaderCollectionScreen), findsOneWidget);
    expect(find.text('合集视频一'), findsOneWidget);
    final q = env.bili
        .to('/x/polymer/web-space/seasons_archives_list')
        .single
        .uri
        .queryParameters;
    expect(q['season_id'], '5');
    expect(q['page_num'], '1');
    expect(q['page_size'], '20');

    await tester.tap(find.text('合集视频一'));
    await tester.pumpAndSettle();
    expect(env.watched, <String>[_detailBvid]);
    expect(find.byType(BilibiliUploaderCollectionScreen), findsOneWidget);
  });

  testWidgets('the UP block in the player\'s Bilibili panel opens the '
      'uploader page', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bili = _FakeBili();
    final api = BilibiliPublicApiService(httpClientAdapter: bili);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BilibiliPlayerPanel(
            bvid: _detailBvid,
            api: api,
            cache: BilibiliVideoDetailCache(
              fetch: (bvid) => api.fetchVideoDetail(bvid: bvid),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bilibili-panel-owner')));
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliUploaderScreen), findsOneWidget);
    expect(
      bili.to('/x/web-interface/card').single.uri.queryParameters['mid'],
      '$_mid',
    );
  });

  testWidgets('UP names in search results open the uploader page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bili = _FakeBili();
    bili.routes['/x/web-interface/wbi/search/type'] = (r) =>
        r.queryParameters['search_type'] == 'bili_user'
        ? _json({
            'code': 0,
            'data': {
              'numPages': 1,
              'result': [
                {'mid': _mid, 'uname': '用户UP', 'fans': 10, 'videos': 2},
              ],
            },
          })
        : _json({
            'code': 0,
            'data': {
              'numPages': 1,
              'result': [
                {
                  'bvid': _detailBvid,
                  'title': '搜索视频',
                  'author': '作者UP',
                  'mid': _mid,
                },
              ],
            },
          });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BilibiliHomePage(
            isActive: true,
            api: BilibiliPublicApiService(httpClientAdapter: bili),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    await tester.tap(find.text('作者UP'));
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliUploaderScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户UP'));
    await tester.pumpAndSettle();
    expect(find.byType(BilibiliUploaderScreen), findsOneWidget);
    expect(bili.to('/x/web-interface/card'), hasLength(2));
  });
}
