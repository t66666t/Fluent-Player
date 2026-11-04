import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/settings_service.dart';

const _bvid = 'BV1GJ411x7h7';

class _FakeAdapter implements HttpClientAdapter {
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.path;
    Object body;
    if (path.endsWith('/wbi/search/type')) {
      body = {
        'code': 0,
        'data': {
          'numPages': 1,
          'result': [
            {
              'bvid': _bvid,
              'title': '<em class="keyword">测试</em>视频',
              'author': 'UP甲',
              'duration': '3:05',
              'play': 23456,
            },
          ],
        },
      };
    } else if (path.endsWith('/x/web-interface/view')) {
      body = {
        'code': 0,
        'data': {
          'bvid': _bvid,
          'title': '详情标题',
          'desc': '上一集 BV1xx411c7mD',
          'owner': {'mid': 1, 'name': 'UP甲'},
          'stat': {'view': 100, 'like': 20},
          'pages': [
            {'cid': 1, 'page': 1, 'part': '第一部分'},
            {'cid': 2, 'page': 2, 'part': '第二部分'},
          ],
        },
      };
    } else if (path.endsWith('/x/tag/archive/tags')) {
      body = {
        'code': 0,
        'data': [
          {'tag_name': '标签一'},
        ],
      };
    } else if (path.endsWith('/main/suggest')) {
      body = {
        'code': 0,
        'result': {
          'tag': [
            {'value': '测试建议'},
          ],
        },
      };
    } else {
      body = {'code': 0, 'result': {}};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
  });

  for (final keyboardHidden in [false, true]) {
    testWidgets('Android touch outside search releases focus with keyboard '
        '${keyboardHidden ? 'hidden' : 'visible'}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final adapter = _FakeAdapter();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BilibiliHomePage(
              isActive: true,
              api: BilibiliPublicApiService(httpClientAdapter: adapter),
            ),
          ),
        ),
      );
      final input = find.byType(TextField);
      await tester.enterText(input, '测试');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('测试视频'), findsOneWidget);

      await tester.tap(input, kind: PointerDeviceKind.touch);
      await tester.pump();
      final field = tester.widget<TextField>(input);
      expect(field.focusNode!.hasFocus, isTrue);
      if (keyboardHidden) tester.testTextInput.hide();
      expect(field.focusNode!.hasFocus, isTrue);

      final outside =
          tester.getBottomRight(find.byType(BilibiliHomePage)) -
          const Offset(20, 20);
      final gesture = await tester.startGesture(
        outside,
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      expect(field.focusNode!.hasFocus, isFalse);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isFalse);
      expect(field.controller!.text, '测试');
      expect(find.text('测试视频'), findsOneWidget);
      expect(
        adapter.requests.where((r) => r.path.endsWith('/wbi/search/type')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }

  testWidgets('search history: record, tap to search, remove and clear', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final history = BilibiliHistoryService.instance;
    await history.addSearch('旧词');
    final adapter = _FakeAdapter();
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BilibiliHomePage(isActive: true, api: api)),
      ),
    );
    await tester.pumpAndSettle();

    // Before any search the history sits in the empty page.
    expect(find.text('搜索历史'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('bilibili-search-history-旧词')),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试视频'), findsOneWidget);
    expect(
      adapter.requests
          .where((r) => r.path.endsWith('/wbi/search/type'))
          .single
          .queryParameters['keyword'],
      '旧词',
    );

    await tester.enterText(find.byType(TextField), ' 测试 ');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(history.searchHistory, ['测试', '旧词']);

    // Empty focused box over the results shows the overlay.
    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('搜索历史'), findsOneWidget);
    final removeHistory = find.byKey(
      const ValueKey<String>('bilibili-search-history-remove-测试'),
    );
    final removeGesture = await tester.startGesture(
      tester.getCenter(removeHistory),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(removeHistory, findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await removeGesture.up();
    await tester.pumpAndSettle();
    expect(history.searchHistory, ['旧词']);
    expect(find.text('搜索历史'), findsOneWidget, reason: 'focus is kept');

    await tester.tap(
      find.byKey(const ValueKey<String>('bilibili-search-history-clear')),
    );
    await tester.pumpAndSettle();
    expect(history.searchHistory, isEmpty);
    expect(find.text('搜索历史'), findsNothing);

    SettingsService().bilibiliRecordSearchHistory = false;
    await tester.enterText(find.byType(TextField), '不记录');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(history.searchHistory, isEmpty);
  });

  testWidgets('search shows videos and a tap plays without the detail page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter();
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    final watched = <(String, int?)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BilibiliHomePage(
            isActive: true,
            api: api,
            onWatch: (context, {required bvid, page, startAt, preview}) async {
              watched.add((bvid, page));
            },
          ),
        ),
      ),
    );
    expect(find.text('输入关键词搜索 B 站内容'), findsOneWidget);
    expect(adapter.requests, isEmpty);

    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('测试视频'), findsOneWidget);
    expect(find.text('03:05'), findsOneWidget);
    expect(find.text('没有更多了'), findsOneWidget);

    await tester.tap(find.byType(TextField), kind: PointerDeviceKind.touch);
    await tester.pump();
    final focus = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(focus.hasFocus, isTrue);
    tester.testTextInput.hide();
    await tester.tap(find.text('测试视频'), kind: PointerDeviceKind.touch);
    await tester.pumpAndSettle();

    expect(focus.hasFocus, isFalse);
    expect(watched, <(String, int?)>[(_bvid, null)]);
    expect(
      adapter.requests.where((r) => r.path.endsWith('/x/web-interface/view')),
      isEmpty,
    );
    // Search carries the device id like the browser's search page.
    final search = adapter.requests.firstWhere(
      (r) => r.path.endsWith('/wbi/search/type'),
    );
    expect('${search.headers['Cookie']}', contains('buvid3='));
  });

  testWidgets('tapping a suggestion searches that keyword', (tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final adapter = _FakeAdapter();
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BilibiliHomePage(isActive: true, api: api)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '测');
    // Debounce, then the suggestion response.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final suggestion = find.byKey(
      const ValueKey<String>('bilibili-search-suggestion-测试建议'),
    );
    expect(suggestion, findsOneWidget);

    // Pointer-down used to unfocus the field and drop this row before the
    // click could search. Hold across a frame, the way a real tap does.
    final gesture = await tester.startGesture(tester.getCenter(suggestion));
    await tester.pump();
    expect(suggestion, findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('测试视频'), findsOneWidget);
    expect(
      adapter.requests
          .where((r) => r.path.endsWith('/wbi/search/type'))
          .single
          .queryParameters['keyword'],
      '测试建议',
    );
  });

  testWidgets('a pasted BV link plays directly without searching', (
    tester,
  ) async {
    final adapter = _FakeAdapter();
    final api = BilibiliPublicApiService(httpClientAdapter: adapter);
    final watched = <(String, int?, Duration?)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BilibiliHomePage(
            isActive: true,
            api: api,
            onWatch: (context, {required bvid, page, startAt, preview}) async {
              watched.add((bvid, page, startAt));
            },
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      'https://www.bilibili.com/video/$_bvid?p=2&t=75',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(watched, <(String, int?, Duration?)>[
      (_bvid, 2, const Duration(seconds: 75)),
    ]);
    expect(
      adapter.requests.where((r) => r.path.endsWith('/wbi/search/type')),
      isEmpty,
    );
  });
}
