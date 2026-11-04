import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/settings_service.dart';

class _DurationAdapter implements HttpClientAdapter {
  _DurationAdapter(this.pages);
  final List<List<Map<String, Object>>> pages;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object body = {'code': 0, 'data': {}};
    if (options.path.endsWith('/wbi/search/type')) {
      requests.add(options);
      final page = options.queryParameters['page'] as int;
      body = {
        'code': 0,
        'data': {'numPages': pages.length, 'result': pages[page - 1]},
      };
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

Map<String, Object> _video(int index, String duration) => {
  'bvid': 'BV1GJ411x7h$index',
  'title': '视频$index',
  'author': 'UP',
  'duration': duration,
};

Future<void> _applyRange(WidgetTester tester) async {
  await tester.tap(find.byTooltip('时长'));
  await tester.pumpAndSettle();
  for (final entry in {
    'duration-minimum-minutes': '12',
    'duration-minimum-seconds': '30',
    'duration-maximum-minutes': '38',
    'duration-maximum-seconds': '0',
  }.entries) {
    final field = find.byKey(ValueKey(entry.key));
    await tester.ensureVisible(field);
    await tester.enterText(field, entry.value);
    await tester.pump();
  }
  await tester.tap(find.byKey(const ValueKey('duration-apply')));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SettingsService().resetForTest();
    BilibiliHistoryService.instance.resetForTest();
  });

  Future<void> open(WidgetTester tester, _DurationAdapter adapter) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
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
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    adapter.requests.clear();
  }

  testWidgets(
    'filter keeps exact endpoints and scans past a fully rejected page',
    (tester) async {
      final adapter = _DurationAdapter([
        [_video(1, '12:29'), _video(2, '38:01')],
        [_video(3, '12:30'), _video(4, '38:00')],
      ]);
      await open(tester, adapter);
      await _applyRange(tester);
      expect(find.text('视频1'), findsNothing);
      expect(find.text('视频2'), findsNothing);
      expect(find.text('视频3'), findsOneWidget);
      expect(find.text('视频4'), findsOneWidget);
      expect(adapter.requests.map((r) => r.queryParameters['page']), [1, 2]);
      expect(
        adapter.requests.every((r) => r.queryParameters['duration'] == 0),
        isTrue,
      );
      expect(find.text('没有更多了'), findsOneWidget);
    },
  );

  testWidgets('sparse search pauses after five pages and continues on demand', (
    tester,
  ) async {
    final adapter = _DurationAdapter(
      List.generate(
        7,
        (index) => [_video(index + 1, index == 5 ? '20:00' : '1:00')],
      ),
    );
    await open(tester, adapter);
    await _applyRange(tester);
    expect(adapter.requests.map((r) => r.queryParameters['page']), [
      1,
      2,
      3,
      4,
      5,
    ]);
    expect(find.text('暂未找到符合时长的视频'), findsOneWidget);
    await tester.tap(find.text('继续查找'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pumpAndSettle();
    expect(find.text('视频6'), findsOneWidget);
    expect(adapter.requests.map((r) => r.queryParameters['page']), [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sorting and published-time capsules send the chosen conditions',
    (tester) async {
      final adapter = _DurationAdapter([
        [_video(1, '20:00')],
      ]);
      await open(tester, adapter);
      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最新发布'));
      await tester.pumpAndSettle();
      expect(adapter.requests.last.queryParameters['order'], 'pubdate');
      await tester.tap(find.byTooltip('发布时间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最近一周'));
      await tester.pumpAndSettle();
      expect(
        adapter.requests.last.queryParameters['pubtime_begin_s'],
        isA<int>(),
      );
      expect(
        adapter.requests.last.queryParameters['pubtime_end_s'],
        isA<int>(),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
