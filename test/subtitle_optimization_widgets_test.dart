import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_app/services/ai_subtitle_api_settings.dart';
import 'package:video_player_app/services/subtitle_optimization.dart';
import 'package:video_player_app/widgets/subtitle_optimization_control.dart';
import 'package:video_player_app/widgets/ai_subtitle_api_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const legacy = AiSubtitleApiSettings(
    baseUrl: 'http://localhost:11434/v1',
    model: 'subtitle-model',
  );
  setUp(() {
    SharedPreferences.setMockInitialValues({
      AiSubtitleApiSettings.preferencesKey: jsonEncode(legacy.toJson()),
      SubtitleAiConnectionStore.preferencesKey: '[]',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        ),
  );

  for (final width in [320.0, 390.0, 800.0]) {
    testWidgets('optimization prompt and background are editable at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SubtitleOptimizationControl(
                backgroundPreview: () async => '标题：本集讲述人工智能',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('subtitle-optimization-toggle'));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(
        find.byKey(const ValueKey('subtitle-optimization-prompt-button')),
      );
      await tester.pumpAndSettle();
      final prompt = find.byKey(const ValueKey('subtitle-optimization-prompt'));
      expect(
        tester.widget<TextField>(prompt).controller!.text,
        defaultSubtitleOptimizationPrompt,
      );
      await tester.enterText(prompt, '只修正专有名词，保留口语。');
      await tester.ensureVisible(find.text('自动背景'));
      expect(find.text('标题：本集讲述人工智能'), findsOneWidget);
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        (await SubtitleOptimizationSettings.load()).prompt,
        '只修正专有名词，保留口语。',
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect((await SubtitleOptimizationSettings.load()).enabled, isTrue);
      expect(
        (await AiSubtitleApiSettingsStore().loadMetadata()).model,
        legacy.model,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  testWidgets(
    'model dropdown switches optimization independently of translation',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        SubtitleAiConnectionStore.preferencesKey,
        jsonEncode([
          SubtitleAiConnection(
            'proofreader',
            '校对 · correction-model',
            legacy.copyWith(model: 'correction-model'),
          ).toJson(),
          SubtitleAiConnection(
            'translator',
            '翻译 · translation-model',
            legacy.copyWith(model: 'translation-model'),
          ).toJson(),
        ]),
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SubtitleOptimizationControl())),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('subtitle-optimization-settings')),
      );
      await tester.pumpAndSettle();
      final prompt = find.byKey(const ValueKey('subtitle-optimization-prompt'));
      expect(
        prompt,
        findsNothing,
        reason: 'The model page is separate from the prompt editor.',
      );
      expect(find.byType(AiSubtitleApiEditor), findsOneWidget);
      expect(find.byKey(const ValueKey('subtitle-api-key')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('optimization-model-')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('校对 · correction-model').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('保存并使用'));
      await tester.tap(find.text('保存并使用'));
      await tester.pumpAndSettle();
      final saved = await SubtitleOptimizationSettings.load();
      expect(saved.connectionId, 'proofreader');
      expect(saved.prompt, defaultSubtitleOptimizationPrompt);
      expect(
        (await AiSubtitleApiSettingsStore().loadMetadata()).model,
        'subtitle-model',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'model page saves an inline endpoint without replacing the translation connection or prompt',
    (tester) async {
      await const SubtitleOptimizationSettings(prompt: '保留原意').save();
      final prefs = await SharedPreferences.getInstance();
      final previousTranslation = prefs.getString(
        AiSubtitleApiSettings.preferencesKey,
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: SubtitleOptimizationControl())),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('subtitle-optimization-settings')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AiSubtitleApiEditor), findsOneWidget);
      expect(
        find.byKey(const ValueKey('subtitle-optimization-prompt')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('subtitle-api-model')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('subtitle-api-model')),
        'new-proofreader',
      );
      await tester.ensureVisible(find.text('保存并使用'));
      await tester.tap(find.text('保存并使用'));
      await tester.pumpAndSettle();
      final saved = await SubtitleOptimizationSettings.load();
      expect(saved.connectionId, isNotEmpty);
      expect(saved.prompt, '保留原意');
      expect(
        (await SubtitleAiConnectionStore().endpoint(saved.connectionId)).model,
        'new-proofreader',
      );
      expect(
        prefs.getString(AiSubtitleApiSettings.preferencesKey),
        previousTranslation,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
