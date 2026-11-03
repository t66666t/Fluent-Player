import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_interaction_theme.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/operation_status.dart';

void main() {
  testWidgets(
    'render actual operation feedback at phone and short landscape sizes',
    (tester) async {
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final cjk = FontLoader('Noto Sans SC');
        for (final weight in ['Regular', 'Medium', 'Bold']) {
          cjk.addFont(
            rootBundle.load('assets/fonts/NotoSansCJKsc-$weight.otf'),
          );
        }
        await cjk.load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });

      for (final viewport in <String, Size>{
        'phone-320': const Size(320, 700),
        'phone-390': const Size(390, 844),
        'landscape': const Size(844, 390),
      }.entries) {
        for (final scale in [1.0, 2.0]) {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = viewport.value;
          final capture = GlobalKey();
          final status = GlobalKey();
          var retries = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appInteractionTheme(
                  ThemeData(
                    brightness: Brightness.dark,
                    useMaterial3: true,
                    fontFamily: 'Noto Sans SC',
                    scaffoldBackgroundColor: AppTokens.bgBase,
                    colorScheme: ColorScheme.fromSeed(
                      seedColor: AppTokens.accent,
                      brightness: Brightness.dark,
                    ),
                  ),
                ),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  appBar: AppBar(title: const Text('在线缓存')),
                  body: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: OperationStatus(
                        key: status,
                        title: '部分缓存未能清理',
                        message: '已清理 8 项，2 项未能清理。失败项仍在列表中，请检查文件是否正在使用后重试。',
                        kind: OperationStatusKind.error,
                        details:
                            'FileSystemException: deletion denied\n'
                            '系统返回：文件正在使用（32）\n'
                            r'路径：D:\Media\在线视频\示例视频.mp4'
                            '\n请关闭正在使用该文件的程序后重试。\n'
                            '请求：https://example.invalid/cache?token=preview-secret',
                        actions: [
                          TextButton.icon(
                            key: const ValueKey('preview-retry'),
                            onPressed: () => retries++,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('重试失败项'),
                          ),
                          TextButton.icon(
                            onPressed: () {},
                            icon: const Icon(Icons.folder_open, size: 18),
                            label: const Text('更换缓存目录'),
                          ),
                          TextButton(
                            onPressed: () {},
                            child: const Text('稍后处理'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final prefix = 'operation-${viewport.key}-${(scale * 100).round()}';
          expect(tester.takeException(), isNull);
          final statusRect = tester.getRect(find.byKey(status));
          for (final label in ['重试失败项', '更换缓存目录', '稍后处理']) {
            final rect = tester.getRect(find.text(label));
            expect(rect.left, greaterThanOrEqualTo(statusRect.left));
            expect(rect.right, lessThanOrEqualTo(statusRect.right));
          }
          await _savePreview(tester, capture, '$prefix-summary');

          await tester.ensureVisible(find.text('诊断详情'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('诊断详情'));
          await tester.pumpAndSettle();
          expect(find.textContaining('preview-secret'), findsNothing);
          await tester.ensureVisible(find.text('复制详情'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await _savePreview(tester, capture, '$prefix-details');

          await tester.ensureVisible(
            find.byKey(const ValueKey('preview-retry')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('preview-retry')));
          await tester.pumpAndSettle();
          expect(retries, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    },
    skip: !const bool.fromEnvironment('DESIGN_FEEDBACK_PREVIEWS'),
  );
}

Future<void> _savePreview(
  WidgetTester tester,
  GlobalKey capture,
  String name,
) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(capture),
  );
  await tester.runAsync(() async {
    final pixels = await boundary.toImage(pixelRatio: 1);
    try {
      final png = await pixels.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/design-feedback-previews/$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(png!.buffer.asUint8List());
    } finally {
      pixels.dispose();
    }
  });
}
