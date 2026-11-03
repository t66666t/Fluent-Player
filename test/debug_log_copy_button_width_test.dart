import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/debug/debug_log_buffer.dart';
import 'package:video_player_app/debug/debug_log_overlay.dart';
import 'package:video_player_app/services/settings_service.dart';

Finder _copyButton() => find.ancestor(
  of: find.byWidgetPredicate(
    (w) => w is Text && (w.data == '复制全部' || w.data == '已复制'),
  ),
  matching: find.byType(TextButton),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (size, scale) in [
    (const Size(1280, 800), 1.0),
    (const Size(390, 760), 1.0),
    (const Size(360, 700), 1.5),
    (const Size(360, 700), 2.0),
  ]) {
    testWidgets('复制全部 → 已复制 → 复制全部：宽度和位置不变（$size × $scale）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = SettingsService()..resetForTest();
      await settings.init();
      settings.developerMode = true;
      DebugLogBuffer.instance.add('宽度测试日志');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsService>.value(
          value: settings,
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: DebugLogOverlay(child: child!),
            ),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      // 悬浮球贴边时先拖到屏幕中间，再轻点（小于点击阈值的拖动）打开面板。
      final ball = find.byIcon(Icons.terminal);
      // 贴边的球有一半在屏幕外，从可见的那一侧按下。
      final docked = tester.getRect(ball);
      final grab = Offset(
        docked.left.clamp(0, size.width - 6) + 4,
        docked.center.dy,
      );
      await tester.dragFrom(
        grab,
        Offset(size.width / 2, size.height / 2) - grab,
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(
        tester.getCenter(ball),
        const Offset(4, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(find.text('复制全部'), findsOneWidget);

      final idle = tester.getRect(_copyButton());
      final title = tester.getTopLeft(find.text('运行记录'));
      final close = tester.getRect(find.byIcon(Icons.close));

      await tester.tap(find.text('复制全部'));
      await tester.pump();
      expect(find.text('已复制'), findsOneWidget);
      expect(tester.getRect(_copyButton()), idle);
      expect(tester.getTopLeft(find.text('运行记录')), title);
      expect(tester.getRect(find.byIcon(Icons.close)), close);

      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.text('复制全部'), findsOneWidget);
      expect(tester.getRect(_copyButton()), idle);
      expect(tester.takeException(), isNull);

      DebugLogOverlay.closePanel();
      await tester.pumpAndSettle();
    });
  }
}
