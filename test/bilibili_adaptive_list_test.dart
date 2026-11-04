import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_home_page.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_history_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/services/bilibili/bilibili_public_api_service.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/bilibili_adaptive_list.dart';
import 'package:video_player_app/widgets/bilibili_video_list_tile.dart';
import 'package:video_player_app/widgets/media_library_layout_profile.dart';

/// Search answers: [perPage] videos per page, three pages.
class _SearchAdapter implements HttpClientAdapter {
  static const int perPage = 20;

  final List<RequestOptions> searches = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object body = {'code': 0, 'result': {}};
    if (options.path.endsWith('/wbi/search/type')) {
      searches.add(options);
      final page = int.tryParse('${options.queryParameters['page']}') ?? 1;
      body = {
        'code': 0,
        'data': {
          'numPages': 3,
          'result': [
            for (var i = 0; i < perPage; i++)
              {
                'bvid': 'BV1xx411c$page${i.toString().padLeft(2, '0')}',
                'title': '视频 $page-$i',
                'author': 'UP',
                'duration': '3:05',
                'play': 100,
              },
          ],
        },
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

Widget _tiles(int count, {bool footer = true}) => MaterialApp(
  home: Scaffold(
    body: BilibiliAdaptiveList(
      itemCount: count,
      itemBuilder: (context, index) => SizedBox(
        key: ValueKey('tile-$index'),
        height: 80,
        child: Text('tile $index'),
      ),
      footer: footer ? (context) => const Text('footer') : null,
    ),
  ),
);

void window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Offset _at(WidgetTester tester, int index) =>
    tester.getTopLeft(find.byKey(ValueKey('tile-$index')));

void main() {
  group('column count follows the width', () {
    test('one column up to two min-width tiles, then more, at most four', () {
      final two = MediaLibraryLayoutDefaults.distributeWidth(
        availableWidth: 1000,
        columns: 2,
        spacingScale: kBilibiliListSpacingScale,
        paddingScale: 0,
      );
      final edge =
          2 * kBilibiliListMinTileWidth +
          two.crossSpacing / two.cellWidth * kBilibiliListMinTileWidth;
      expect(bilibiliListColumns(0), 1);
      expect(bilibiliListColumns(double.infinity), 1);
      expect(bilibiliListColumns(390), 1); // phone portrait
      expect(bilibiliListColumns(915), 1); // phone landscape
      expect(bilibiliListColumns(edge - 0.5), 1);
      expect(bilibiliListColumns(edge + 0.5), 2);
      expect(bilibiliListColumns(1280), 2);
      expect(bilibiliListColumns(1440), 3);
      expect(bilibiliListColumns(1920), 4);
      expect(bilibiliListColumns(3840), kBilibiliListMaxColumns);
      for (var w = 300.0; w < 3000; w += 7) {
        final columns = bilibiliListColumns(w);
        expect(columns, greaterThanOrEqualTo(bilibiliListColumns(w - 7)));
        if (columns > 1) {
          final cells = MediaLibraryLayoutDefaults.distributeWidth(
            availableWidth: w,
            columns: columns,
            spacingScale: kBilibiliListSpacingScale,
            paddingScale: 0,
          );
          expect(cells.cellWidth, greaterThanOrEqualTo(460));
        }
      }
    });

    test('spacing is the media library list default', () {
      expect(
        kBilibiliListSpacingScale,
        MediaLibraryLayoutDefaults.defaultListSpacingScale,
      );
      expect(kBilibiliListMaxColumns, 4);
    });
  });

  testWidgets('narrow: the plain list, every row full width', (tester) async {
    window(tester, const Size(900, 1200));
    await tester.pumpWidget(_tiles(5));
    for (var i = 0; i < 5; i++) {
      expect(_at(tester, i).dx, 0);
      expect(tester.getSize(find.byKey(ValueKey('tile-$i'))).width, 900);
    }
    expect(_at(tester, 1).dy - _at(tester, 0).dy, 80);
    expect(find.text('footer'), findsOneWidget);
  });

  for (final (width, columns) in const <(double, int)>[
    (1280, 2),
    (1440, 3),
    (1920, 4),
  ]) {
    testWidgets('${width.toInt()} wide: $columns columns, the footer across', (
      tester,
    ) async {
      window(tester, Size(width, 900));
      await tester.pumpWidget(_tiles(7));
      final cells = MediaLibraryLayoutDefaults.distributeWidth(
        availableWidth: width,
        columns: columns,
        spacingScale: kBilibiliListSpacingScale,
        paddingScale: 0,
      );
      for (var i = 0; i < 7; i++) {
        final row = i ~/ columns;
        final column = i % columns;
        expect(_at(tester, i).dy, row * 80.0, reason: 'tile $i');
        expect(
          _at(tester, i).dx,
          closeTo(column * (cells.cellWidth + cells.crossSpacing), 0.01),
          reason: 'tile $i',
        );
        expect(
          tester.getSize(find.byKey(ValueKey('tile-$i'))).width,
          closeTo(cells.cellWidth, 0.01),
        );
      }
      final footer = tester.getRect(find.text('footer'));
      expect(footer.top, ((7 + columns - 1) ~/ columns) * 80.0);
    });
  }

  testWidgets('dragging the window wider and back keeps the rows in view', (
    tester,
  ) async {
    window(tester, const Size(900, 600));
    await tester.pumpWidget(_tiles(60, footer: false));
    await tester.drag(find.bySubtype<ListView>(), const Offset(0, -1600));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tile-22')), findsOneWidget);

    tester.view.physicalSize = const Size(1920, 600);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('tile-22')), findsOneWidget);

    tester.view.physicalSize = const Size(900, 600);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('tile-22')), findsOneWidget);
  });

  group('the Bilibili pages', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      SettingsService().resetForTest();
      BilibiliHistoryService.instance.resetForTest();
    });

    test('search, the UP page lists and the watch history use it', () {
      for (final path in <String>[
        'lib/screens/bilibili/bilibili_home_page.dart',
        'lib/screens/bilibili/bilibili_uploader_screen.dart',
        'lib/screens/bilibili/bilibili_watch_history_screen.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(source, contains('BilibiliAdaptiveList('), reason: path);
        expect(source, isNot(contains('ListView.builder(')), reason: path);
      }
    });

    Future<_SearchAdapter> search(WidgetTester tester, Size size) async {
      window(tester, size);
      final adapter = _SearchAdapter();
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
      return adapter;
    }

    testWidgets('search results: one column on a narrow window', (
      tester,
    ) async {
      final adapter = await search(tester, const Size(900, 1000));
      expect(adapter.searches, hasLength(1));
      final first = tester.getTopLeft(find.text('视频 1-0'));
      final second = tester.getTopLeft(find.text('视频 1-1'));
      expect(second.dx, first.dx);
      expect(second.dy, greaterThan(first.dy));
    });

    for (final width in [320.0, 390.0, 768.0, 1440.0]) {
      testWidgets('search at $width leaves room for the title', (tester) async {
        await search(tester, Size(width, 1000));
        final tile = find.ancestor(
          of: find.text('视频 1-0'),
          matching: find.byType(BilibiliVideoListTile),
        );
        final cover = tester.getRect(
          find.descendant(
            of: tile,
            matching: find.byKey(const ValueKey('bilibili-tile-cover')),
          ),
        );
        final info = tester.getRect(
          find.descendant(
            of: tile,
            matching: find.byKey(const ValueKey('bilibili-tile-info')),
          ),
        );
        expect(cover.top, closeTo(info.top, .01));
        expect(cover.bottom, closeTo(info.bottom, .01));
        final title = tester.getRect(find.text('视频 1-0'));
        final action = tester.getRect(
          find.byKey(const ValueKey('bilibili-import-BV1xx411c100')),
        );
        expect(
          tester
              .renderObject<RenderBox>(find.text('视频 1-0'))
              .constraints
              .maxWidth,
          greaterThan(165),
        );
        if (width < 600) expect(action.top, greaterThan(title.bottom));
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('search results: columns on a wide window, and a page that '
        'no longer fills the list loads the next one', (tester) async {
      final adapter = await search(tester, const Size(1920, 1000));
      final first = tester.getTopLeft(find.text('视频 1-0'));
      for (var i = 1; i < 4; i++) {
        final next = tester.getTopLeft(find.text('视频 1-$i'));
        expect(next.dy, first.dy);
        expect(next.dx, greaterThan(first.dx + 400 * i));
      }
      expect(tester.getTopLeft(find.text('视频 1-4')).dy, greaterThan(first.dy));
      // Five rows of four do not fill 1000 px: the next page comes without
      // scrolling.
      expect(adapter.searches.length, greaterThanOrEqualTo(2));
      expect(
        adapter.searches.map((r) => '${r.queryParameters['page']}').toSet(),
        containsAll(<String>['1', '2']),
      );
    });

    testWidgets('search results: widening the window until a page no '
        'longer fills the list loads the next one', (tester) async {
      final adapter = await search(tester, const Size(900, 1000));
      expect(adapter.searches, hasLength(1));
      tester.view.physicalSize = const Size(1920, 1000);
      await tester.pumpAndSettle();
      expect(adapter.searches.length, greaterThanOrEqualTo(2));
      expect(find.text('视频 2-0'), findsOneWidget);
    });

    testWidgets('watch history: entries side by side at 1280', (tester) async {
      window(tester, const Size(1280, 900));
      final history = BilibiliHistoryService.instance;
      final now = DateTime.now();
      await history.recordWatch(
        BilibiliWatchHistoryEntry(
          bvid: 'BV1aa411c7mD',
          title: 'Title A',
          ownerName: 'UP',
          watchedAt: now,
        ),
      );
      await history.recordWatch(
        BilibiliWatchHistoryEntry(
          bvid: 'BV1bb411c7mD',
          title: 'Title B',
          ownerName: 'UP',
          watchedAt: now.add(const Duration(seconds: 1)),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: BilibiliWatchHistoryScreen(fetchCover: (_) async => null),
        ),
      );
      await tester.pumpAndSettle();
      final a = tester.getTopLeft(find.text('Title A'));
      final b = tester.getTopLeft(find.text('Title B'));
      expect(a.dy, b.dy);
      expect((a.dx - b.dx).abs(), greaterThan(400));
    });
  });
}
