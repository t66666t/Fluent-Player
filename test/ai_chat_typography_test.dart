import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/features/ai_chat/ai_chat_typography.dart';
import 'package:video_player_app/features/ai_chat/ai_markdown.dart';
import 'package:video_player_app/features/ai_chat/ai_math.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('adapts to actual panel width and phone landscape orientation', () {
    AiChatTextMetrics metrics(
      double width,
      Size screen, {
      bool fullscreen = false,
    }) => AiChatTextMetrics.resolve(
      panelWidth: width,
      screen: screen,
      fullscreen: fullscreen,
    );
    expect(metrics(340, const Size(844, 390)).fontSize, 12);
    expect(metrics(340, const Size(844, 390)).dense, isTrue);
    expect(metrics(390, const Size(390, 844)).fontSize, 14);
    expect(metrics(480, const Size(1440, 900)).fontSize, 14);
    expect(metrics(840, const Size(1440, 900)).fontSize, 15);
    expect(metrics(1280, const Size(1440, 900), fullscreen: true).fontSize, 16);
    expect(metrics(844, const Size(844, 390), fullscreen: true).fontSize, 15);
    expect(metrics(240, const Size(1440, 900)).fontSize, 12);
    final smallest = AiChatTextMetrics.resolve(
      panelWidth: 240,
      screen: const Size(844, 390),
      fullscreen: false,
      scale: .8,
    );
    expect(smallest.fontSize, 11);
  });

  test(
    'persists relative size, orders quick changes and restores defaults',
    () async {
      final settings = AiChatReadingSettings();
      await settings.load();
      expect(settings.value, 1);
      await Future.wait([settings.setScale(.85), settings.setScale(1.45)]);
      final restored = AiChatReadingSettings();
      await restored.load();
      expect(restored.value, 1.45);
      await restored.setScale(1);
      final defaults = AiChatReadingSettings();
      await defaults.load();
      expect(defaults.value, 1);
      settings.dispose();
      restored.dispose();
      defaults.dispose();
    },
  );

  test(
    'late loading cannot override a new choice and corrupt values are safe',
    () async {
      SharedPreferences.setMockInitialValues({
        AiChatReadingSettings.preferenceKey: 1.5,
      });
      final ready = Completer<SharedPreferences>();
      final settings = AiChatReadingSettings(preferences: () => ready.future);
      final loading = settings.load();
      final saving = settings.setScale(.9);
      ready.complete(await SharedPreferences.getInstance());
      await Future.wait([loading, saving]);
      expect(settings.value, .9);
      settings.dispose();
      for (final value in <Object>['broken', double.nan, -40.0, 100.0]) {
        SharedPreferences.setMockInitialValues({
          AiChatReadingSettings.preferenceKey: value,
        });
        final setting = AiChatReadingSettings();
        await setting.load();
        expect(setting.value, inInclusiveRange(.8, 1.6));
        setting.dispose();
      }
    },
  );

  testWidgets(
    'Markdown prose, headings, tables, code and formulas share reading size',
    (tester) async {
      Future<void> mount(double size) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AiChatTypography(
                metrics: AiChatTextMetrics(fontSize: size, dense: true),
                child: const AiMarkdown(
                  data:
                      '# 标题\n\n正文 **重点** [链接](https://example.com)\n\n'
                      '| 项目 | 数值 |\n| --- | --- |\n| 示例 | 123 |\n\n'
                      '```dart\nfinal value = 1;\n```\n\n```math\nx^2 + y^2\n```\n\n'
                      r'行内 $x^2$'
                      '\n\n'
                      r'\[x + y = z\]',
                ),
              ),
            ),
          ),
        ),
      );
      for (final size in [12.0, 18.0]) {
        await mount(size);
        await tester.pumpAndSettle();
        final sheet = tester
            .widget<MarkdownBody>(find.byType(MarkdownBody))
            .styleSheet!;
        expect(sheet.p!.fontSize, size);
        expect(sheet.p!.fontWeight, FontWeight.w400);
        expect(sheet.p!.fontFamily, 'App Reading');
        expect(sheet.p!.height, closeTo(1.55, .001));
        expect(sheet.blockSpacing, closeTo(size * .6, .001));
        expect(sheet.tableBody!.fontWeight, FontWeight.w400);
        expect(sheet.h1!.fontWeight, FontWeight.w600);
        expect(sheet.h1!.height, closeTo(1.3, .001));
        expect(sheet.strong!.fontWeight, FontWeight.w600);
        expect(sheet.h1!.fontSize, closeTo(size * 1.4, .001));
        expect(sheet.tableBody!.fontSize, size);
        expect(sheet.code!.fontSize, size - 1);
        expect(
          tester.widget<Text>(find.text('final value = 1;')).style!.fontSize,
          size - 1,
        );
        for (final formula in tester.widgetList<AiMathFormula>(
          find.byType(AiMathFormula),
        )) {
          expect(formula.textStyle!.fontSize, size);
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'reading controls and preview fit short landscape and large system text',
    (tester) async {
      final settings = AiChatReadingSettings();
      addTearDown(settings.dispose);
      for (final (size, textScale) in [
        (const Size(844, 260), 1.0),
        (const Size(320, 640), 1.8),
        (const Size(1280, 800), 1.0),
      ]) {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAiChatReadingSettings(
                    context,
                    settings: settings,
                    metrics: const AiChatTextMetrics(fontSize: 12, dense: true),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('放大字体'));
        await tester.pumpAndSettle();
        expect(settings.value, closeTo(1.05, .001));
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('恢复默认'));
        await tester.pumpAndSettle();
        expect(settings.value, 1);
        await tester.tap(find.text('完成'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );
}
