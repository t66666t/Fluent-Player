import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_import_buttons.dart';
import 'package:video_player_app/screens/bilibili/bilibili_watch_history_screen.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/bilibili_video_list_tile.dart';

const _bvid = 'BV1xx411c7mD';
const _title = '永不放弃 Rick Astley — Never Gonna Give You Up 现场演出';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    BilibiliHistoryService.instance.resetForTest();
  });

  for (final width in [320.0, 360.0, 390.0, 600.0, 768.0, 1280.0, 1920.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets(
        'history at $width / text $scale keeps title and actions usable',
        (tester) async {
          tester.view.physicalSize = Size(width, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final history = BilibiliHistoryService.instance;
          await history.recordWatch(
            BilibiliWatchHistoryEntry(
              bvid: _bvid,
              title: _title,
              ownerName: 'Rick Astley 官方频道',
              partTitle: '现场演出完整版',
              page: 2,
              watchedAt: DateTime(2026, 10, 15, 17, 5),
              positionMs: 187000,
            ),
          );
          final calls = <bool>[];
          var opens = 0;
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: BilibiliWatchHistoryScreen(
                history: history,
                fetchCover: (_) async => null,
                onOpen: (_, _) async => opens++,
                onImport:
                    (context, {required bvid, page, required pickPlace}) async {
                      expect(bvid, _bvid);
                      expect(page, 2);
                      calls.add(pickPlace);
                    },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final tile = tester.getRect(find.byType(BilibiliVideoListTile));
          final cover = tester.getRect(
            find.byKey(const ValueKey('bilibili-tile-cover')),
          );
          final info = tester.getRect(
            find.byKey(const ValueKey('bilibili-tile-info')),
          );
          expect(cover.top, closeTo(info.top, .01));
          expect(cover.bottom, closeTo(info.bottom, .01));
          expect(cover.height, closeTo(info.height, .01));
          final title = tester.getRect(find.text(_title));
          final main = find.byKey(const ValueKey('bilibili-import-$_bvid'));
          final folder = find.byKey(
            const ValueKey('bilibili-import-pick-$_bvid'),
          );
          final mainRect = tester.getRect(main);
          final folderRect = tester.getRect(folder);
          // The title must never collapse to the single-character column in
          // the reported phone screenshot, including cells in desktop grids.
          expect(title.width, greaterThan(165));
          expect(mainRect.width, greaterThanOrEqualTo(44 - .01));
          expect(mainRect.height, greaterThanOrEqualTo(44 - .01));
          expect(folderRect.width, greaterThanOrEqualTo(44 - .01));
          expect(folderRect.height, greaterThanOrEqualTo(44 - .01));
          expect(folderRect.right, lessThanOrEqualTo(tile.right));
          expect(folderRect.bottom, lessThanOrEqualTo(tile.bottom));
          if (width < 600) expect(mainRect.top, greaterThan(title.bottom));
          if (width < 600 && scale == 1) {
            expect(tile.height, lessThan(110));
            expect(cover.width / cover.height, greaterThanOrEqualTo(1.25));
          }

          await tester.tap(main);
          await tester.pumpAndSettle();
          await tester.tap(folder);
          await tester.pumpAndSettle();
          await tester.tap(find.text('选择导入位置'));
          await tester.pumpAndSettle();
          expect(calls, [false, true]);
          expect(opens, 0);
          await tester.tap(find.text(_title));
          await tester.pumpAndSettle();
          expect(opens, 1);
          await tester.tap(folder);
          await tester.pumpAndSettle();
          await tester.tap(find.text('删除记录'));
          await tester.pumpAndSettle();
          expect(history.watchHistory, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('detail action wrap respects narrow panes and large text', (
    tester,
  ) async {
    for (final width in [240.0, 320.0, 600.0]) {
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        const BilibiliImportButtons(
                          bvid: _bvid,
                          emphasized: true,
                        ),
                        OutlinedButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('下载'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(find.byType(BilibiliImportButtons));
        expect(bounds.width, lessThanOrEqualTo(width));
        expect(bounds.width, lessThanOrEqualTo(scale == 1 ? 110 : 150));
      }
    }
  });

  // Optional local visual QA: renders the real widgets with the bundled CJK
  // font. No platform font or golden image dependency in normal test runs.
  if (Platform.environment['BILIBILI_LAYOUT_PREVIEW'] == '1') {
    testWidgets('render responsive previews', (tester) async {
      final loader = FontLoader('BilibiliPreview')
        ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final history = BilibiliHistoryService.instance;
      for (var i = 0; i < 5; i++) {
        await history.recordWatch(
          BilibiliWatchHistoryEntry(
            bvid: 'BV1xx411c7m$i',
            title: i == 0
                ? _title
                : i == 4
                ? '一首老歌'
                : '视频 ${i + 1}：值得重温的精彩时刻与现场演出',
            ownerName: 'Rick Astley',
            watchedAt: DateTime(2026, 10, 15, 17, i),
            positionMs: 187000,
          ),
        );
      }
      for (final width in [320.0, 360.0, 390.0, 768.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(
                fontFamily: 'BilibiliPreview',
              ),
            ),
            home: RepaintBoundary(
              key: boundaryKey,
              child: DefaultTextStyle(
                style: const TextStyle(
                  fontFamily: 'BilibiliPreview',
                  color: AppTokens.text1,
                ),
                child: BilibiliWatchHistoryScreen(
                  history: history,
                  fetchCover: (_) async => null,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tiles = find.byType(BilibiliVideoListTile);
        final heights = <double>[];
        for (final tile in tiles.evaluate()) {
          final inTile = find.byWidget(tile.widget);
          final cover = tester.getRect(
            find.descendant(
              of: inTile,
              matching: find.byKey(const ValueKey('bilibili-tile-cover')),
            ),
          );
          final info = tester.getRect(
            find.descendant(
              of: inTile,
              matching: find.byKey(const ValueKey('bilibili-tile-info')),
            ),
          );
          expect(cover.top, closeTo(info.top, .01));
          expect(cover.bottom, closeTo(info.bottom, .01));
          heights.add(cover.height);
        }
        expect(
          heights.every((height) => (height - heights.first).abs() < .01),
          isTrue,
          reason: 'Short and long titles must keep the same row alignment',
        );
        if (width == 768) {
          final title = tester.getRect(find.text(_title));
          final importAction = tester.getRect(
            find.byKey(const ValueKey('bilibili-import-BV1xx411c7m0')),
          );
          expect(title.right, lessThanOrEqualTo(importAction.left - 16));
        }
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final screenshot = await boundary.toImage(pixelRatio: 1.5);
          final data = await screenshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(
            '.artifacts/bilibili-import/history-${width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          screenshot.dispose();
        });
        expect(tester.takeException(), isNull);
      }
    });
  }
}
