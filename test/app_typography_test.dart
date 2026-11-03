import 'dart:io';
import 'package:video_player_app/features/ai_chat/ai_chat_typography.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_app/theme/app_typography.dart';
import 'package:video_player_app/theme/app_tokens.dart';
import 'package:video_player_app/widgets/bilibili_restricted_dialog.dart';

ThemeData previewTheme() => ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  fontFamily: 'MiSans',
  textTheme: appTextTheme(),
  scaffoldBackgroundColor: const Color(0xFF121212),
  colorScheme: const ColorScheme.dark(
    primary: Colors.blue,
    surface: Color(0xFF121212),
  ),
  textButtonTheme: TextButtonThemeData(style: appActionTextStyle()),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: appActionTextStyle(emphasized: true),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: appActionTextStyle(emphasized: true),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(style: appActionTextStyle()),
);

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
}

void main() {
  test('muted metadata and pink action retain readable contrast', () {
    expect(
      contrast(AppTokens.text3, AppTokens.bgCard),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      contrast(const Color(0xFF28131A), AppTokens.brandBilibili),
      greaterThanOrEqualTo(4.5),
    );
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testWidgets('restricted dialog actions and layout at 320px / $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var deferred = 0;
      var login = 0;
      var suppressed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: previewTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: BilibiliRestrictedDialog(
              dontShowAgain: false,
              onDontShowAgainChanged: (value) => suppressed = value,
              onDefer: () => deferred++,
              onLogin: () => login++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('之后不显示'));
      await tester.tap(find.text('暂不登录'));
      await tester.tap(find.text('去登录'));
      expect(suppressed, isTrue);
      expect(deferred, 1);
      expect(login, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('render real dialog and shared typography preview', (
    tester,
  ) async {
    final output = Platform.environment['TYPOGRAPHY_PREVIEW_DIR'];
    if (output == null) return;
    await tester.runAsync(() async {
      final fonts = FontLoader('MiSans');
      for (final weight in ['Regular']) {
        fonts.addFont(rootBundle.load('assets/fonts/MiSans-$weight.otf'));
      }
      await fonts.load();
      await (FontLoader(
        'App Reading',
      )..addFont(rootBundle.load('assets/fonts/MiSans-Normal.otf'))).load();
    });
    tester.view.physicalSize = const Size(1080, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: previewTheme(),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: BilibiliRestrictedDialog(
                    dontShowAgain: false,
                    onDontShowAgainChanged: (_) {},
                    onDefer: () {},
                    onLogin: () {},
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Builder(
                      builder: (context) {
                        final text = Theme.of(context).textTheme;
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('全局文字层级 · 组件预览', style: text.titleLarge),
                            const SizedBox(height: 28),
                            Text('AI 对话 · 长文阅读', style: text.titleMedium),
                            const SizedBox(height: 12),
                            const AiChatTypography(
                              metrics: AiChatTextMetrics(fontSize: 15),
                              child: AiMarkdown(
                                data:
                                    '长段落使用更柔和的常规字重，阅读时不用一直面对加粗文字。\n\n只有 **关键结论** 保留强调，列表和说明回到自然的阅读节奏。',
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '次要信息 · 播放记录 · 文件说明',
                              style: text.bodySmall?.copyWith(
                                color: AppTokens.text3,
                              ),
                            ),
                            const SizedBox(height: 28),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                FilledButton(
                                  onPressed: () {},
                                  child: const Text('开始播放'),
                                ),
                                OutlinedButton(
                                  onPressed: () {},
                                  child: const Text('导入媒体'),
                                ),
                                TextButton(
                                  onPressed: () {},
                                  child: const Text('取消'),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(output).create(recursive: true);
      await File(
        '$output/typography-reading-preview.png',
      ).writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  });
}
