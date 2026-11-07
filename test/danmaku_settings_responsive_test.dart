import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/settings_service.dart';
import 'package:video_player_app/widgets/danmaku_settings_dialog.dart';

void main() {
  testWidgets('render final dialog sizes', (tester) async {
    await tester.runAsync(() async {
      await (FontLoader(
        'Noto Sans SC',
      )..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf'))).load();
      await (FontLoader('Noto Sans CJK Fallback')
            ..addFont(rootBundle.load('assets/fonts/NotoSansCJKsc-Regular.otf'))
            ..addFont(rootBundle.load('assets/fonts/NotoSansSC-Variable.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    SharedPreferences.setMockInitialValues({});
    final settings = SettingsService()..resetForTest();
    await settings.init();
    addTearDown(tester.view.reset);
    for (final item in {
      'small-phone-portrait': const Size(320, 568),
      'small-phone-landscape': const Size(568, 320),
      'phone-portrait': const Size(390, 844),
      'phone-landscape': const Size(844, 390),
      'tablet-portrait': const Size(834, 1194),
      'tablet-landscape': const Size(1194, 834),
      'desktop-landscape': const Size(1440, 900),
      'desktop-portrait': const Size(900, 1440),
    }.entries) {
      tester.view.physicalSize = item.value;
      tester.view.devicePixelRatio = 1;
      final capture = GlobalKey();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Noto Sans SC'),
            ),
            builder: (_, child) => RepaintBoundary(key: capture, child: child!),
            home: Scaffold(
              backgroundColor: const Color(0xFF10151D),
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showDanmakuSettingsDialog(context),
                    child: const Text('设置'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text('适中 · 1.0×'),
      );
      expect(paragraph.didExceedMaxLines, isFalse);
      if (item.key == 'phone-landscape') {
        final surface = tester.getRect(
          find.byKey(const ValueKey('danmaku-dialog-surface')),
        );
        final close = tester.getRect(
          find.widgetWithIcon(IconButton, Icons.close),
        );
        final update = tester.getRect(
          find.widgetWithText(FilledButton, '立即更新'),
        );
        expect(surface.width, lessThanOrEqualTo(560));
        expect(surface.height, lessThan(370));
        expect(surface.bottom - update.bottom, lessThanOrEqualTo(20));
        expect(surface.right - close.right, lessThanOrEqualTo(20));
        expect(tester.widget<Text>(find.text('弹幕速度')).style!.fontSize, 15);
        expect(
          tester.getRect(find.text('弹幕速度')).height,
          greaterThanOrEqualTo(14),
        );
      }
      if (const bool.fromEnvironment('DANMAKU_PREVIEWS')) {
        await tester.runAsync(() async {
          await Directory('build/danmaku_previews').create(recursive: true);
          final image =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/danmaku_previews/${item.key}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      void checkVisible() {
        expect(find.byType(Scrollable), findsNothing);
        for (final finder in [
          find.byType(Slider),
          find.byType(Checkbox),
          find.text('立即更新'),
          find.text('恢复弹幕默认设置'),
        ]) {
          for (final element in finder.evaluate()) {
            final rect = tester.getRect(
              find.byElementPredicate((candidate) => candidate == element),
            );
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(item.value.height));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(item.value.width));
          }
        }
      }

      checkVisible();
      await tester.tap(find.text('高级设置'));
      await tester.pumpAndSettle();
      checkVisible();
      for (final tab in ['字体', '样式', '微调']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        checkVisible();
        expect(tester.takeException(), isNull);
        if (const bool.fromEnvironment('DANMAKU_PREVIEWS')) {
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              'build/danmaku_previews/${item.key}-advanced-$tab.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
      await tester.tap(find.text('恢复弹幕默认设置'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
