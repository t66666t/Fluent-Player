import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/screens/bilibili/bilibili_import_buttons.dart';
import 'package:video_player_app/services/bilibili/bilibili_history_service.dart';

/// B站按钮「状态切换时宽度不变」的验收用例。
///
/// 修复已落地，用例全部启用；需要临时跳过时把 [_pending] 改成 true。
const bool _pending = false;

const _bvid = 'BV1xx411c7mD';

Widget _row(Widget button, {double scale = 1.0, double width = 800}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 600),
        textScaler: TextScaler.linear(scale),
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Row(
              children: [
                Flexible(child: button),
                const Text('邻居', key: ValueKey('neighbor')),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('导入按钮', () {
    late BilibiliHistoryService history;
    late List<(bool, Completer<void>)> calls;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      history = BilibiliHistoryService.instance..resetForTest();
      calls = [];
    });

    Widget buttons({double scale = 1.0, double width = 800}) => _row(
      BilibiliImportButtons(
        bvid: _bvid,
        history: history,
        onImport: (context, {required bvid, page, required pickPlace}) {
          final c = Completer<void>();
          calls.add((pickPlace, c));
          return c.future;
        },
      ),
      scale: scale,
      width: width,
    );

    Finder outer() => find
        .ancestor(
          of: find.byKey(const ValueKey('bilibili-import-$_bvid')),
          matching: find.byType(Material),
        )
        .first;

    testWidgets('点左边导入：显示正在导入，宽度和邻居位置不变，不能重复触发', (tester) async {
      await tester.pumpWidget(buttons());
      final size = tester.getSize(outer());
      final neighbor = tester.getTopLeft(
        find.byKey(const ValueKey('neighbor')),
      );
      await tester.tap(find.byKey(const ValueKey('bilibili-import-$_bvid')));
      await tester.pump();
      expect(find.text('导入中'), findsOneWidget);
      expect(tester.getSize(outer()), size);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('neighbor'))),
        neighbor,
      );
      await tester.tap(find.byKey(const ValueKey('bilibili-import-$_bvid')));
      await tester.pump();
      expect(calls, hasLength(1));
      calls.single.$2.completeError(StateError('假失败'));
      await tester.pump();
      expect(tester.getSize(outer()), size);
    }, skip: _pending);

    testWidgets('点右边选文件夹：左边文字不变、不出现正在导入', (tester) async {
      await tester.pumpWidget(buttons());
      final size = tester.getSize(outer());
      await tester.tap(
        find.byKey(const ValueKey('bilibili-import-pick-$_bvid')),
      );
      await tester.pump();
      expect(calls.single.$1, isTrue);
      expect(find.text('导入中'), findsNothing);
      expect(find.text('导入'), findsOneWidget);
      expect(tester.getSize(outer()), size);
      calls.single.$2.complete();
      await tester.pump();
    }, skip: _pending);

    testWidgets('选文件夹期间：左右两边都不能重复触发，结束后文字仍是导入', (tester) async {
      await tester.pumpWidget(buttons());
      await tester.tap(
        find.byKey(const ValueKey('bilibili-import-pick-$_bvid')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bilibili-import-$_bvid')));
      await tester.tap(
        find.byKey(const ValueKey('bilibili-import-pick-$_bvid')),
      );
      await tester.pump();
      expect(calls, hasLength(1));
      expect(find.text('导入中'), findsNothing);
      calls.single.$2.complete();
      await tester.pump();
      expect(find.text('导入'), findsOneWidget);
      expect(find.text('导入中'), findsNothing);
    }, skip: _pending);

    testWidgets('导入失败：显示失败提示，但按钮尺寸和这一行高度都不变', (tester) async {
      await tester.pumpWidget(buttons());
      final key = find.byKey(const ValueKey('bilibili-import-$_bvid'));
      final size = tester.getSize(outer());
      final rowSize = tester.getSize(find.byType(Row).first);
      await tester.tap(key);
      await tester.pump();
      calls.single.$2.completeError(StateError('假失败'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('bilibili-import-error-$_bvid')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(outer()), size);
      expect(tester.getSize(find.byType(Row).first), rowSize);
    }, skip: _pending);

    for (final scale in [1.5, 2.0]) {
      testWidgets('窄屏 360、字体缩放 $scale：导入中不溢出', (tester) async {
        await tester.pumpWidget(buttons(scale: scale, width: 360));
        final size = tester.getSize(outer());
        await tester.tap(find.byKey(const ValueKey('bilibili-import-$_bvid')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(tester.getSize(outer()), size);
        calls.single.$2.complete();
        await tester.pump();
      }, skip: _pending);
    }
  });
}
